--!strict

local RunService = game:GetService("RunService")

local ShipValidationService = {}
ShipValidationService.__index = ShipValidationService

local function finiteVector(value: Vector3): boolean
  return value.X == value.X and value.Y == value.Y and value.Z == value.Z
    and value.X > -math.huge and value.X < math.huge
    and value.Y > -math.huge and value.Y < math.huge
    and value.Z > -math.huge and value.Z < math.huge
end

function ShipValidationService.new(registry)
  return setmetatable({registry = registry, connection = nil, violations = {}, lastSafe = {}, warnCooldown = {}}, ShipValidationService)
end

function ShipValidationService:_Step(dt: number)
  for _, entry in ipairs(self.registry:GetEntries()) do
    local root = entry.root
    local model = entry.model
    if root.Parent then
      local score = self.violations[model] or 0
      local velocity = root.AssemblyLinearVelocity
      local angularVelocity = root.AssemblyAngularVelocity
      local position = root.Position
      local finite = finiteVector(position) and finiteVector(velocity) and finiteVector(angularVelocity)
      if not finite then
        local safeCFrame = self.lastSafe[model]
        if safeCFrame then root:PivotTo(safeCFrame) end
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        self.violations[model] = 0
        warn("OceanShip validation recovered invalid assembly state: " .. model:GetFullName())
      else
        local speed = velocity.Magnitude
        local angular = angularVelocity.Magnitude
        local maxSpeed = math.max(model:GetAttribute("MaxValidatedSpeed") or 180, 20)
        local maxAngular = math.max(model:GetAttribute("MaxValidatedAngularSpeed") or 8, 1)
        if speed <= maxSpeed and angular <= maxAngular then
          self.lastSafe[model] = root.CFrame
          score = math.max(0, score - dt * 0.5)
        else
          score += dt * 2
        end
        self.violations[model] = score
        local cooldown = self.warnCooldown[model] or 0
        if score > 3 then
          root.AssemblyLinearVelocity = velocity * 0.6
          root.AssemblyAngularVelocity = angularVelocity * 0.6
          self.violations[model] = 1
          if cooldown <= 0 then
            warn("OceanShip validation softened an out-of-envelope assembly: " .. model:GetFullName())
            self.warnCooldown[model] = 2
          end
        end
        self.warnCooldown[model] = math.max(0, cooldown - dt)
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
