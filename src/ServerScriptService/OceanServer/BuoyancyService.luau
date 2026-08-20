--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local BuoyancyService = {}
BuoyancyService.__index = BuoyancyService

local UP = Vector3.yAxis
local MAX_DT = 0.05

local function finite(value: number): boolean
  return value == value and value > -math.huge and value < math.huge
end

local function finiteVector(value: Vector3): boolean
  return finite(value.X) and finite(value.Y) and finite(value.Z)
end

local function clampMagnitude(value: Vector3, maximum: number): Vector3
  if not finiteVector(value) then return Vector3.zero end
  local magnitude = value.Magnitude
  if magnitude > maximum and magnitude > 1e-5 then
    return value * (maximum / magnitude)
  end
  return value
end

local function smoothstep(value: number): number
  local t = math.clamp(value, 0, 1)
  return t * t * (3 - 2 * t)
end

local function validSample(sample): boolean
  return sample
    and finite(sample.height)
    and finiteVector(sample.position)
    and finiteVector(sample.normal)
    and finiteVector(sample.velocity)
    and finite(sample.inverseResidual)
    and sample.inverseResidual < 0.25
end

function BuoyancyService.new(waveField, registry)
  return setmetatable({
    waveField = waveField,
    registry = registry,
    connection = nil,
    enabled = true,
    lastSamples = 0,
    lastStepMs = 0,
    lastTotalForce = Vector3.zero,
    lastTotalTorque = Vector3.zero,
  }, BuoyancyService)
end

function BuoyancyService:_EnsureForce(entry, point): VectorForce
  local folder = entry.forces
  if not folder then
    folder = Instance.new("Folder")
    folder.Name = "OceanForces"
    folder.Parent = entry.root
    entry.forces = folder
  end
  local name = point.attachment.Name
  local force = folder:FindFirstChild(name)
  if force and force:IsA("VectorForce") then
    force.Enabled = true
    return force
  end
  local created = Instance.new("VectorForce")
  created.Name = name
  created.Attachment0 = point.attachment
  created.ApplyAtCenterOfMass = false
  created.RelativeTo = Enum.ActuatorRelativeTo.World
  created.Force = Vector3.zero
  created.Enabled = true
  created.Parent = folder
  return created
end

function BuoyancyService:_EnsureDrag(entry): VectorForce
  if entry.dragForce and entry.dragForce.Parent then
    return entry.dragForce
  end
  local attachment = entry.comAttachment
  if not attachment or not attachment.Parent then
    attachment = Instance.new("Attachment")
    attachment.Name = "OceanBuoyancyCOM"
    attachment.Position = entry.dryComLocal
    attachment.Parent = entry.root
    entry.comAttachment = attachment
  end
  local force = entry.root:FindFirstChild("OceanHydrodynamicDrag", true)
  if not force or not force:IsA("VectorForce") then
    force = Instance.new("VectorForce")
    force.Name = "OceanHydrodynamicDrag"
    force.Attachment0 = attachment
    force.ApplyAtCenterOfMass = true
    force.RelativeTo = Enum.ActuatorRelativeTo.World
    force.Parent = entry.root
  end
  force.Force = Vector3.zero
  force.Enabled = true
  entry.dragForce = force
  return force
end

function BuoyancyService:_EnsureStabilityTorque(entry)
  if entry.stabilityTorque and entry.stabilityTorque.Parent then
    return entry.stabilityTorque
  end
  local attachment = entry.comAttachment
  if not attachment or not attachment.Parent then
    attachment = Instance.new("Attachment")
    attachment.Name = "OceanBuoyancyCOM"
    attachment.Position = entry.dryComLocal
    attachment.Parent = entry.root
    entry.comAttachment = attachment
  end
  local torque = entry.root:FindFirstChild("OceanStabilityTorque", true)
  if not torque or not torque:IsA("Torque") then
    local created = Instance.new("Torque")
    created.Name = "OceanStabilityTorque"
    created.Attachment0 = attachment
    created.RelativeTo = Enum.ActuatorRelativeTo.World
    created.Parent = entry.root
    torque = created
  end
  torque.Torque = Vector3.zero
  torque.Enabled = true
  entry.stabilityTorque = torque
  return torque
end

function BuoyancyService:_DisableEntryForces(entry)
  if entry.forces then
    for _, child in ipairs(entry.forces:GetChildren()) do
      if child:IsA("VectorForce") then
        child.Force = Vector3.zero
        child.Enabled = false
      elseif child:IsA("Torque") then
        child.Torque = Vector3.zero
        child.Enabled = false
      end
    end
  end
  if entry.dragForce then
    entry.dragForce.Force = Vector3.zero
    entry.dragForce.Enabled = false
  end
  if entry.stabilityTorque then
    entry.stabilityTorque.Torque = Vector3.zero
    entry.stabilityTorque.Enabled = false
  end
end

function BuoyancyService:_Step(dt: number)
  if not self.enabled then return end
  local started = os.clock()
  debug.profilebegin("Ocean/Buoyancy")
  dt = math.clamp(dt, 0, MAX_DT)
  local serverTime = self.waveField:GetSynchronizedTime()
  local sampleCount = 0
  local totalForce = Vector3.zero
  local totalTorque = Vector3.zero

  for _, entry in ipairs(self.registry:GetEntries()) do
    local root = entry.root
    if root.Parent and finite(entry.dryMass) and entry.dryMass > 0 then
      local assemblyMass = root.AssemblyMass
      local payloadTarget = math.clamp(assemblyMass - entry.dryMass, 0, entry.dryMass * 0.75)
      local blend = math.clamp(dt / 1.5, 0, 1)
      entry.payloadMass += (payloadTarget - entry.payloadMass) * blend
      local controlMass = entry.dryMass + entry.payloadMass
      entry.effectiveMass = controlMass

      local gain = math.clamp(entry.model:GetAttribute("BuoyancyGain") or 1.16, 1.0, 1.3)
      local dampingRatio = math.clamp(entry.model:GetAttribute("DampingRatio") or 0.88, 0.65, 1.15)
      local aggregateForce = Vector3.zero
      local aggregateTorque = Vector3.zero
      local wetPoints = 0
      local invalidSamples = 0

      local rootPosition = root.AssemblyCenterOfMass
      local rootSample = self.waveField:SampleForGameplayWorldXZ(
        Vector2.new(rootPosition.X, rootPosition.Z),
        serverTime,
        {inverseIterations = 3}
      )
      local rootSampleValid = validSample(rootSample)
      if rootSampleValid then sampleCount += 1 end

      for _, point in ipairs(entry.points) do
        local attachment = point.attachment
        local worldPosition = attachment.WorldPosition
        local sample = self.waveField:SampleForGameplayWorldXZ(
          Vector2.new(worldPosition.X, worldPosition.Z),
          serverTime,
          {inverseIterations = 3}
        )
        sampleCount += 1
        local pendingForce = Vector3.zero
        local depth = 0
        if validSample(sample) then
          depth = sample.height - worldPosition.Y
          point.lastDepth = depth
          if depth > 0 then
            local targetDepth = math.max(point.targetDepth or entry.targetDraft * 0.9, 0.25)
            local wetness = smoothstep(depth / targetDepth)
            local spring = controlMass * Workspace.Gravity * point.weight * gain / targetDepth
            local pointMass = controlMass * point.weight
            local damping = 2 * dampingRatio * math.sqrt(math.max(spring * pointMass, 0))
            local velocityOk, pointVelocity = pcall(function()
              return root:GetVelocityAtPosition(worldPosition)
            end)
            if not velocityOk or not finiteVector(pointVelocity) then
              pointVelocity = root.AssemblyLinearVelocity
            end
            local verticalRelativeVelocity = pointVelocity.Y - sample.velocity.Y
            local lift = spring * math.min(depth, targetDepth)
            local dampingForce = damping * verticalRelativeVelocity * wetness
            local maximum = math.max(point.maxForce or controlMass * Workspace.Gravity * point.weight * 2.25, 1)
            local verticalForce = math.clamp(lift - dampingForce, -maximum * 0.25, maximum)
            pendingForce = UP * verticalForce
            wetPoints += 1
          end
          point.lastSample = sample
        else
          invalidSamples += 1
          point.lastDepth = 0
          point.lastSample = nil
        end
        point.pendingForce = pendingForce
        aggregateForce += pendingForce
        aggregateTorque += (worldPosition - root.AssemblyCenterOfMass):Cross(pendingForce)
      end

      local aggregateLimit = controlMass * Workspace.Gravity * 3.0
      local aggregateScale = aggregateForce.Magnitude > aggregateLimit and aggregateLimit / aggregateForce.Magnitude or 1
      local torqueLimit = controlMass * Workspace.Gravity * 4
      local torqueScale = aggregateTorque.Magnitude > torqueLimit and torqueLimit / aggregateTorque.Magnitude or 1
      for _, point in ipairs(entry.points) do
        local force = self:_EnsureForce(entry, point)
        local scaled = point.pendingForce * aggregateScale * torqueScale
        point.lastForce = scaled
        force.Force = scaled
        force.Enabled = true
      end

      local drag = self:_EnsureDrag(entry)
      if rootSampleValid then
        local comVelocity = root:GetVelocityAtPosition(root.AssemblyCenterOfMass)
        local relative = comVelocity - rootSample.velocity
        local localVelocity = root.CFrame:VectorToObjectSpace(relative)
        local localDrag = Vector3.new(
          -localVelocity.X * math.abs(localVelocity.X) * 0.72,
          -localVelocity.Y * math.abs(localVelocity.Y) * 0.28,
          -localVelocity.Z * math.abs(localVelocity.Z) * 0.14
        ) * controlMass
        drag.Force = clampMagnitude(root.CFrame:VectorToWorldSpace(localDrag), controlMass * Workspace.Gravity * 1.4)
        drag.Enabled = true
      else
        drag.Force = Vector3.zero
        drag.Enabled = false
      end

      local stabilizer = self:_EnsureStabilityTorque(entry)
      local bodyUp = root.CFrame.UpVector
      local tiltError = UP:Cross(bodyUp)
      local angularVelocity = root.AssemblyAngularVelocity
      local horizontalAngular = angularVelocity - UP * angularVelocity:Dot(UP)
      local stabilizingTorque = tiltError * (controlMass * Workspace.Gravity * 0.55)
        - horizontalAngular * (controlMass * 1.15)
      stabilizer.Torque = clampMagnitude(stabilizingTorque, controlMass * Workspace.Gravity * 2.2)
      stabilizer.Enabled = true

      local committedForce = aggregateForce * aggregateScale * torqueScale + (drag.Force or Vector3.zero)
      local committedTorque = aggregateTorque * aggregateScale * torqueScale + stabilizer.Torque
      entry.lastTotalForce = committedForce
      entry.lastTotalTorque = committedTorque
      entry.lastWetPoints = wetPoints
      entry.lastInvalidSamples = invalidSamples
      totalForce += committedForce
      totalTorque += committedTorque
    else
      self:_DisableEntryForces(entry)
    end
  end

  self.lastSamples = sampleCount
  self.lastTotalForce = totalForce
  self.lastTotalTorque = totalTorque
  self.lastStepMs = (os.clock() - started) * 1000
  debug.profileend()
end

function BuoyancyService:Start()
  if self.connection then return end
  local signal = RunService.PreSimulation or RunService.Heartbeat
  self.connection = signal:Connect(function(dt)
    self:_Step(math.clamp(dt, 0, MAX_DT))
  end)
end

function BuoyancyService:Stop()
  if self.connection then
    self.connection:Disconnect()
    self.connection = nil
  end
  for _, entry in ipairs(self.registry:GetEntries()) do
    self:_DisableEntryForces(entry)
  end
end

function BuoyancyService:GetDiagnostics()
  return {
    lastSamples = self.lastSamples,
    lastStepMs = self.lastStepMs,
    totalForce = self.lastTotalForce,
    totalTorque = self.lastTotalTorque,
  }
end

return BuoyancyService
