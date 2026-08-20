--!strict

local RunService = game:GetService("RunService")

local ShipValidationService = {}
ShipValidationService.__index = ShipValidationService

local function finite(value: number): boolean
  return value == value and value > -math.huge and value < math.huge
end

local function finiteVector(value: Vector3): boolean
  return finite(value.X) and finite(value.Y) and finite(value.Z)
end

function ShipValidationService.new(registry)
  return setmetatable({
    registry = registry,
    connection = nil,
    violations = {},
    lastSafe = {},
    warnCooldown = {},
  }, ShipValidationService)
end

function ShipValidationService:_WarnOutlier(entry, speed: number, angular: number, reason: string)
  local model = entry.model
  local now = os.clock()
  local last = self.warnCooldown[model] or 0
  if last > now then return end
  self.warnCooldown[model] = now + 2
  warn(string.format(
    "OceanShip validation softened | model=%s reason=%s speed=%.2f angular=%.2f mass=%.2f dryMass=%.2f force=%s torque=%s wetPoints=%d invalidSamples=%d seat=%s",
    model:GetFullName(),
    reason,
    speed,
    angular,
    entry.root.AssemblyMass,
    entry.dryMass or 0,
    tostring(entry.lastTotalForce or Vector3.zero),
    tostring(entry.lastTotalTorque or Vector3.zero),
    entry.lastWetPoints or 0,
    entry.lastInvalidSamples or 0,
    tostring(entry.occupant ~= nil)
  ))
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
      local finiteState = finiteVector(position) and finiteVector(velocity) and finiteVector(angularVelocity)
      if not finiteState then
        local safeCFrame = self.lastSafe[model]
        if safeCFrame then root:PivotTo(safeCFrame) end
        root.AssemblyLinearVelocity = Vector3.zero
        root.AssemblyAngularVelocity = Vector3.zero
        self.violations[model] = 0
        self:_WarnOutlier(entry, 0, 0, "nonfinite-state-recovered")
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
        if score > 3 then
          root.AssemblyLinearVelocity = velocity * 0.6
          root.AssemblyAngularVelocity = angularVelocity * 0.6
          self.violations[model] = 1
          self:_WarnOutlier(entry, speed, angular, "velocity-envelope")
        end
      end
    end
  end
end

function ShipValidationService:Start()
  if self.connection then return end
  self.connection = RunService.Heartbeat:Connect(function(dt)
    self:_Step(math.clamp(dt, 0, 0.1))
  end)
end

function ShipValidationService:Stop()
  if self.connection then
    self.connection:Disconnect()
    self.connection = nil
  end
  table.clear(self.violations)
  table.clear(self.lastSafe)
  table.clear(self.warnCooldown)
end

return ShipValidationService
