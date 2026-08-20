--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ContextActionService = game:GetService("ContextActionService")
local Workspace = game:GetService("Workspace")

local SwimmingController = {}
SwimmingController.__index = SwimmingController
local STATE_DRY = "Dry"
local STATE_ENTERING = "Entering"
local STATE_EXITING = "Exiting"
local SAMPLE_INTERVAL = 1 / 20
local ENTER_DWELL = 0.16
local EXIT_DWELL = 0.16

local function finite(value: number): boolean
  return value == value and value > -math.huge and value < math.huge
end

local function finiteVector(value: Vector3): boolean
  return finite(value.X) and finite(value.Y) and finite(value.Z)
end

local function clampVector(value: Vector3, maximum: number): Vector3
  if not finiteVector(value) then return Vector3.zero end
  local magnitude = value.Magnitude
  if magnitude > maximum and magnitude > 1e-5 then
    return value * (maximum / magnitude)
  end
  return value
end

function SwimmingController.new(waveField, runtime, scheduler)
  return setmetatable({
    waveField = waveField,
    runtime = runtime,
    scheduler = scheduler,
    connection = nil,
    force = nil,
    attachment = nil,
    characterAddedConnection = nil,
    characterRemovingConnection = nil,
    humanoidDiedConnection = nil,
    state = STATE_DRY,
    swimming = false,
    engineSwimming = false,
    enterTimer = 0,
    exitTimer = 0,
    sampleAccumulator = SAMPLE_INTERVAL,
    sample = nil,
    sampleAge = math.huge,
    transitionCount = 0,
    deactivationCount = 0,
    lastReason = "startup",
    ascendHeld = false,
    diveHeld = false,
  }, SwimmingController)
end

function SwimmingController:_EnsureForce(root: BasePart): VectorForce
  if self.force and self.force.Parent == root then return self.force end
  local attachment = root:FindFirstChild("OceanSwimAttachment")
  if not attachment then
    attachment = Instance.new("Attachment")
    attachment.Name = "OceanSwimAttachment"
    attachment.Parent = root
  end
  local force = root:FindFirstChild("OceanSwimForce")
  if not force or not force:IsA("VectorForce") then
    force = Instance.new("VectorForce")
    force.Name = "OceanSwimForce"
    force.Attachment0 = attachment
    force.RelativeTo = Enum.ActuatorRelativeTo.World
    force.ApplyAtCenterOfMass = true
    force.Parent = root
  end
  self.attachment = attachment
  self.force = force
  return force
end

function SwimmingController:_PublishDebug(humanoid: Humanoid?, root: BasePart?)
  if not self.runtime or self.runtime:GetAttribute("OceanDebugMetrics") ~= true then return end
  self.runtime:SetAttribute("OceanSwimState", self.state)
  self.runtime:SetAttribute("OceanSwimTransitionCount", self.transitionCount)
  self.runtime:SetAttribute("OceanSwimDeactivateCount", self.deactivationCount)
  self.runtime:SetAttribute("OceanSwimLastReason", self.lastReason)
  self.runtime:SetAttribute("OceanSwimSampleAge", self.sampleAge)
  self.runtime:SetAttribute("OceanSwimForceEnabled", self.force ~= nil and self.force.Enabled or false)
  self.runtime:SetAttribute("OceanSwimForceMagnitude", self.force and self.force.Force.Magnitude or 0)
  self.runtime:SetAttribute("OceanSwimHumanoidState", humanoid and humanoid:GetState().Name or "None")
  self.runtime:SetAttribute("OceanSwimSeated", humanoid and (humanoid.SeatPart ~= nil or humanoid.Sit) or false)
  self.runtime:SetAttribute("OceanSwimAssemblyMass", root and root.AssemblyMass or 0)
  self.runtime:SetAttribute("OceanSwimAssemblyRoot", root and root.AssemblyRootPart and root.AssemblyRootPart.Name or "None")
end

function SwimmingController:_SetEngineSwimming(humanoid: Humanoid, enabled: boolean)
  if enabled == self.engineSwimming then return end
  self.engineSwimming = enabled
  if enabled then
    if humanoid:GetState() ~= Enum.HumanoidStateType.Swimming then
      humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
    end
  elseif humanoid:GetState() == Enum.HumanoidStateType.Swimming then
    humanoid:ChangeState(Enum.HumanoidStateType.GettingUp)
  end
end

function SwimmingController:Deactivate(reason: string)
  local changed = self.state ~= STATE_DRY or self.swimming or self.engineSwimming
  self.state = STATE_DRY
  self.swimming = false
  self.enterTimer = 0
  self.exitTimer = 0
  self.sampleAccumulator = SAMPLE_INTERVAL
  self.sample = nil
  self.sampleAge = math.huge
  self.lastReason = reason
  if changed then
    self.deactivationCount += 1
  end
  if self.force then
    self.force.Force = Vector3.zero
    self.force.Enabled = false
  end
  local player = Players.LocalPlayer
  local character = player and player.Character
  local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  if humanoid and self.engineSwimming and humanoid.SeatPart == nil and humanoid.Health > 0 then
    self:_SetEngineSwimming(humanoid, false)
  else
    self.engineSwimming = false
  end
  self:_PublishDebug(humanoid, character and character:FindFirstChild("HumanoidRootPart") :: BasePart?)
end

function SwimmingController:_Transition(nextState: string, humanoid: Humanoid)
  if self.state == nextState then return end
  self.state = nextState
  self.transitionCount += 1
  if nextState == STATE_SWIMMING then
    self.swimming = true
    self:_SetEngineSwimming(humanoid, true)
  elseif nextState == STATE_DRY then
    self:Deactivate("dry-transition")
    return
  elseif nextState == STATE_ENTERING then
    self.swimming = false
  elseif nextState == STATE_EXITING then
    self.swimming = true
  end
  self:_PublishDebug(humanoid, humanoid.Parent and humanoid.Parent:FindFirstChild("HumanoidRootPart") :: BasePart?)
end

function SwimmingController:_ReadBodySample(root: BasePart, serverTime: number): boolean
  local positions = {
    root.CFrame:PointToWorldSpace(Vector3.new(0, 0, 0)),
    root.CFrame:PointToWorldSpace(Vector3.new(0, 1.25, 0)),
    root.CFrame:PointToWorldSpace(Vector3.new(0, 2.35, 0)),
  }
  local samples = table.create(3)
  for index, position in ipairs(positions) do
    local sample = self.scheduler
      and self.scheduler:Sample(Vector2.new(position.X, position.Z), serverTime, {inverseIterations = 3})
      or self.waveField:SampleForGameplayWorldXZ(Vector2.new(position.X, position.Z), serverTime, {inverseIterations = 3})
    if not sample or not finite(sample.height) or not finiteVector(sample.velocity) or sample.inverseResidual >= 0.25 then
      return false
    end
    samples[index] = sample
  end
  local pelvis = samples[1]
  local chest = samples[2]
  local head = samples[3]
  self.sample = {
    surfaceHeight = chest.height,
    surfaceVelocity = chest.velocity,
    pelvisImmersion = pelvis.height - positions[1].Y,
    chestImmersion = chest.height - positions[2].Y,
    headImmersion = head.height - positions[3].Y,
  }
  self.sampleAge = 0
  return true
end

function SwimmingController:_UpdateState(dt: number, humanoid: Humanoid)
  local sample = self.sample
  if not sample then
    self:Deactivate("sample-unavailable")
    return
  end
  local wantsEnter = sample.chestImmersion >= 0.7
    or (sample.pelvisImmersion >= 1.0 and sample.headImmersion >= 0.1)
  local wantsExit = sample.chestImmersion <= 0.3 and sample.headImmersion <= -0.2

  if self.state == STATE_DRY then
    if wantsEnter then
      self.enterTimer += dt
      if self.enterTimer >= ENTER_DWELL then
        self.enterTimer = 0
        self:_Transition(STATE_ENTERING, humanoid)
      end
    else
      self.enterTimer = 0
    end
  elseif self.state == STATE_ENTERING then
    if not wantsEnter then
      self:Deactivate("enter-cancelled")
    else
      self.enterTimer += dt
      if self.enterTimer >= ENTER_DWELL then
        self.enterTimer = 0
        self:_Transition(STATE_SWIMMING, humanoid)
      end
    end
  elseif self.state == STATE_SWIMMING then
    if wantsExit then
      self.exitTimer += dt
      if self.exitTimer >= EXIT_DWELL then
        self.exitTimer = 0
        self:_Transition(STATE_EXITING, humanoid)
      end
    else
      self.exitTimer = 0
    end
  elseif self.state == STATE_EXITING then
    if not wantsExit then
      self.exitTimer = 0
      self:_Transition(STATE_SWIMMING, humanoid)
    else
      self.exitTimer += dt
      if self.exitTimer >= EXIT_DWELL then
        self:Deactivate("surface-exit")
      end
    end
  end
end

function SwimmingController:_ApplyForce(dt: number, humanoid: Humanoid, root: BasePart)
  if self.state ~= STATE_SWIMMING and self.state ~= STATE_EXITING then
    if self.force then
      self.force.Force = Vector3.zero
      self.force.Enabled = false
    end
    return
  end
  local sample = self.sample
  if not sample then
    self:Deactivate("force-sample-missing")
    return
  end

  local mass = math.clamp(root.AssemblyMass, 1, 300)
  local targetRootY = sample.surfaceHeight - 1.25
  local errorY = math.clamp(targetRootY - root.Position.Y, -5, 5)
  local relativeY = root.AssemblyLinearVelocity.Y - sample.surfaceVelocity.Y
  local verticalAcceleration = math.clamp(errorY * 10 - relativeY * 4, -48, 48)
  if self.ascendHeld then verticalAcceleration += 18 end
  if self.diveHeld then verticalAcceleration -= 18 end

  local currentHorizontal = Vector3.new(root.AssemblyLinearVelocity.X, 0, root.AssemblyLinearVelocity.Z)
  local waterHorizontal = Vector3.new(sample.surfaceVelocity.X, 0, sample.surfaceVelocity.Z)
  local desiredHorizontal = waterHorizontal + humanoid.MoveDirection * 10
  local horizontalAcceleration = clampVector((desiredHorizontal - currentHorizontal) * 6, 32)
  local force = Vector3.new(
    horizontalAcceleration.X,
    Workspace.Gravity + verticalAcceleration,
    horizontalAcceleration.Z
  ) * mass
  local maximum = mass * Workspace.Gravity * 1.8
  local swimForce = self:_EnsureForce(root)
  swimForce.Force = clampVector(force, maximum)
  swimForce.Enabled = true
end

function SwimmingController:_Step(dt: number)
  debug.profilebegin("Ocean/Swimming")
  local runtime = self.runtime
  if not runtime or runtime:GetAttribute("OceanSwimmingEnabled") ~= true then
    self:Deactivate("feature-disabled")
    debug.profileend()
    return
  end

  local player = Players.LocalPlayer
  local character = player and player.Character
  local humanoid = character and character:FindFirstChildOfClass("Humanoid")
  local root = character and character:FindFirstChild("HumanoidRootPart")
  if not humanoid or not root or not root:IsA("BasePart") then
    self:Deactivate("character-unavailable")
    debug.profileend()
    return
  end
  if humanoid.Health <= 0 then
    self:Deactivate("humanoid-dead")
    debug.profileend()
    return
  end
  local humanoidState = humanoid:GetState()
  if humanoid.SeatPart ~= nil or humanoid.Sit or humanoidState == Enum.HumanoidStateType.Seated then
    self:Deactivate("seated")
    debug.profileend()
    return
  end
  local assemblyRoot = root.AssemblyRootPart
  if assemblyRoot and not assemblyRoot:IsDescendantOf(character) then
    self:Deactivate("connected-to-external-assembly")
    debug.profileend()
    return
  end

  self.sampleAccumulator += math.clamp(dt, 0, 0.05)
  self.sampleAge += math.clamp(dt, 0, 0.05)
  if self.sampleAccumulator >= SAMPLE_INTERVAL or not self.sample then
    self.sampleAccumulator %= SAMPLE_INTERVAL
    local readOk = self:_ReadBodySample(root, self.waveField:GetSynchronizedTime())
    if not readOk then
      self:Deactivate("sample-invalid")
      debug.profileend()
      return
    end
  end

  self:_UpdateState(math.clamp(dt, 0, 0.05), humanoid)
  self:_ApplyForce(math.clamp(dt, 0, 0.05), humanoid, root)
  if self.runtime:GetAttribute("OceanDebugMetrics") == true then
    self:_PublishDebug(humanoid, root)
  end
  debug.profileend()
end

function SwimmingController:_BindInput()
  local function actionHandler(actionName, inputState)
    local active = inputState == Enum.UserInputState.Begin or inputState == Enum.UserInputState.Change
    if actionName == "OceanSwimAscend" then
      self.ascendHeld = active
    elseif actionName == "OceanSwimDive" then
      self.diveHeld = active
    end
    return Enum.ContextActionResult.Sink
  end
  ContextActionService:BindAction("OceanSwimAscend", actionHandler, true, Enum.KeyCode.Space, Enum.KeyCode.ButtonA)
  ContextActionService:BindAction("OceanSwimDive", actionHandler, true, Enum.KeyCode.LeftControl, Enum.KeyCode.ButtonB)
  ContextActionService:SetTitle("OceanSwimAscend", "Ascend")
  ContextActionService:SetTitle("OceanSwimDive", "Dive")
end

function SwimmingController:_UnbindInput()
  ContextActionService:UnbindAction("OceanSwimAscend")
  ContextActionService:UnbindAction("OceanSwimDive")
  self.ascendHeld = false
  self.diveHeld = false
end

function SwimmingController:_ConnectCharacterSignals()
  local player = Players.LocalPlayer
  if not player then return end
  self.characterAddedConnection = player.CharacterAdded:Connect(function()
    self:Deactivate("character-respawned")
    if self.humanoidDiedConnection then
      self.humanoidDiedConnection:Disconnect()
      self.humanoidDiedConnection = nil
    end
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    if humanoid then
      self.humanoidDiedConnection = humanoid.Died:Connect(function()
        self:Deactivate("humanoid-died")
      end)
    end
  end)
  self.characterRemovingConnection = player.CharacterRemoving:Connect(function()
    self:Deactivate("character-removing")
  end)
  if player.Character then
    local humanoid = player.Character:FindFirstChildOfClass("Humanoid")
    if humanoid then
      self.humanoidDiedConnection = humanoid.Died:Connect(function()
        self:Deactivate("humanoid-died")
      end)
    end
  end
end

function SwimmingController:Start()
  if self.connection then return end
  self:_BindInput()
  self:_ConnectCharacterSignals()
  self.connection = RunService.PreSimulation:Connect(function(dt)
    self:_Step(dt)
  end)
end

function SwimmingController:Stop()
  if self.connection then
    self.connection:Disconnect()
    self.connection = nil
  end
  if self.characterAddedConnection then self.characterAddedConnection:Disconnect() self.characterAddedConnection = nil end
  if self.characterRemovingConnection then self.characterRemovingConnection:Disconnect() self.characterRemovingConnection = nil end
  if self.humanoidDiedConnection then self.humanoidDiedConnection:Disconnect() self.humanoidDiedConnection = nil end
  self:_UnbindInput()
  self:Deactivate("stopped")
end

function SwimmingController:Invalidate()
  self.sample = nil
  self.sampleAge = math.huge
  self.sampleAccumulator = SAMPLE_INTERVAL
end

function SwimmingController:IsSwimming(): boolean
  return self.state == STATE_SWIMMING or self.state == STATE_EXITING
end

function SwimmingController:GetDiagnostics()
  return {
    state = self.state,
    swimming = self.swimming,
    transitionCount = self.transitionCount,
    deactivationCount = self.deactivationCount,
    lastReason = self.lastReason,
    sampleAge = self.sampleAge,
    forceEnabled = self.force ~= nil and self.force.Enabled or false,
    force = self.force and self.force.Force or Vector3.zero,
  }
end

return SwimmingController
