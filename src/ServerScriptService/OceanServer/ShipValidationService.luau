--!strict

local RunService = game:GetService("RunService")

local ShipValidationService = {}
ShipValidationService.__index = ShipValidationService

function ShipValidationService.new(registry)
  return setmetatable({registry = registry, connection = nil, violations = {}}, ShipValidationService)
end

function ShipValidationService:_Step(dt: number)
  for _, entry in ipairs(self.registry:GetEntries()) do
    local root = entry.root
    local model = entry.model
    if root.Parent then
      local score = self.violations[model] or 0
      local speed = root.AssemblyLinearVelocity.Magnitude
      local angular = root.AssemblyAngularVelocity.Magnitude
      local maxSpeed = math.max(model:GetAttribute("MaxValidatedSpeed") or 180, 20)
      local maxAngular = math.max(model:GetAttribute("MaxValidatedAngularSpeed") or 8, 1)
      if speed > maxSpeed or angular > maxAngular or root.Position.Y ~= root.Position.Y then
        score += dt * 2
      else
        score = math.max(0, score - dt * 0.5)
      end
      self.violations[model] = score
      if score > 3 then
        root.AssemblyLinearVelocity = root.AssemblyLinearVelocity * 0.6
        root.AssemblyAngularVelocity = root.AssemblyAngularVelocity * 0.6
        self.violations[model] = 1
        warn("OceanShip validation softened an out-of-envelope assembly: " .. model:GetFullName())
      end
    end
  end
end

function ShipValidationService:Start()
  if self.connection then return end
  self.connection = RunService.Heartbeat:Connect(function(dt) self:_Step(math.clamp(dt, 0, 0.1)) end)
end

function ShipValidationService:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
end

return ShipValidationService
