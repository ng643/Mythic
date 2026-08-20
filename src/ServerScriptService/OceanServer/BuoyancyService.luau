--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BuoyancyService = {}
BuoyancyService.__index = BuoyancyService

local UP = Vector3.yAxis

local function clampMagnitude(value: Vector3, maximum: number): Vector3
  local magnitude = value.Magnitude
  if magnitude > maximum and magnitude > 1e-5 then
    return value * (maximum / magnitude)
  end
  return value
end

function BuoyancyService.new(waveField, registry)
  return setmetatable({waveField = waveField, registry = registry, connection = nil, enabled = true, lastSamples = 0}, BuoyancyService)
end

function BuoyancyService:_EnsureForce(entry, attachment: Attachment): VectorForce
  local folder = entry.forces
  if not folder then
    folder = Instance.new("Folder")
    folder.Name = "OceanForces"
    folder.Parent = entry.root
    entry.forces = folder
  end
  local force = folder:FindFirstChild(attachment.Name)
  if force and force:IsA("VectorForce") then
    return force
  end
  local created = Instance.new("VectorForce")
  created.Name = attachment.Name
  created.Attachment0 = attachment
  created.ApplyAtCenterOfMass = false
  created.RelativeTo = Enum.ActuatorRelativeTo.World
  created.Force = Vector3.zero
  created.Parent = folder
  return created
end

function BuoyancyService:_Step(dt: number)
  if not self.enabled then return end
  local serverTime = self.waveField:GetSynchronizedTime()
  local sampleCount = 0
  for _, entry in ipairs(self.registry:GetEntries()) do
    local root = entry.root
    if root.Parent and root.AssemblyMass > 0 then
      local mass = root.AssemblyMass
      local gain = math.clamp(entry.model:GetAttribute("BuoyancyGain") or 1.12, 1.0, 1.4)
      local dampingRatio = math.clamp(entry.model:GetAttribute("DampingRatio") or 0.85, 0.55, 1.25)
      local draft = math.max(entry.model:GetAttribute("EffectiveDraft") or 5, 0.5)
      for _, point in ipairs(entry.points) do
        local worldPosition = point.WorldPosition
        local sample = self.waveField:SampleWorldXZ(Vector2.new(worldPosition.X, worldPosition.Z), serverTime, {inverseIterations = 2, componentCap = 10})
        local weight = math.max(point:GetAttribute("Weight") or (1 / #entry.points), 0.001)
        local targetDepth = math.max(point:GetAttribute("TargetSubmersion") or draft * 0.55, 0.25)
        local depth = math.clamp(sample.height - worldPosition.Y, 0, draft)
        local pointMass = mass * weight
        local spring = (mass * Workspace.Gravity * weight * gain) / targetDepth
        local damping = 2 * dampingRatio * math.sqrt(math.max(spring * pointMass, 0))
        local radius = worldPosition - root.AssemblyCenterOfMass
        local pointVelocity = root.AssemblyLinearVelocity + root.AssemblyAngularVelocity:Cross(radius)
        local relativeVelocity = pointVelocity - sample.velocity
        local force = UP * (spring * depth) - sample.normal * (damping * relativeVelocity:Dot(sample.normal))
        local maxForce = math.max(point:GetAttribute("MaxForce") or mass * Workspace.Gravity * weight * 3, 1)
        local vectorForce = self:_EnsureForce(entry, point)
        vectorForce.Force = clampMagnitude(force, maxForce)
        sampleCount += 1
      end
      local velocity = root.AssemblyLinearVelocity
      local localVelocity = root.CFrame:VectorToObjectSpace(velocity - self.waveField:SampleWorldXZ(Vector2.new(root.Position.X, root.Position.Z), serverTime, {componentCap = 8}).velocity)
      local drag = Vector3.new(-localVelocity.X * math.abs(localVelocity.X) * 0.08, -localVelocity.Y * math.abs(localVelocity.Y) * 0.18, -localVelocity.Z * math.abs(localVelocity.Z) * 0.9)
      root:ApplyImpulse(root.CFrame:VectorToWorldSpace(drag) * mass * math.clamp(dt, 0, 0.05))
    end
  end
  self.lastSamples = sampleCount
end

function BuoyancyService:Start()
  if self.connection then return end
  local signal = RunService.PreSimulation or RunService.Heartbeat
  self.connection = signal:Connect(function(dt) self:_Step(math.clamp(dt, 0, 0.05)) end)
end

function BuoyancyService:Stop()
  if self.connection then
    self.connection:Disconnect()
    self.connection = nil
  end
end

return BuoyancyService
