--!strict

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WakeController = {}
WakeController.__index = WakeController

local WAKE_TEXTURE = "rbxassetid://140229416139720"
local UPDATE_INTERVAL = 1 / 18
local TELEPORT_DISTANCE = 100

local function findHullRoot(model: Model): BasePart?
  local root = model:FindFirstChild("HullRoot", true)
  if root and root:IsA("BasePart") then return root end
  if model.PrimaryPart then return model.PrimaryPart end
  return nil
end

local function clearTrail(trail: Trail)
  trail.Enabled = false
  pcall(function() trail:Clear() end)
end

local function createTrail(name: string, attachment0: Attachment, attachment1: Attachment): Trail
  local trail = Instance.new("Trail")
  trail.Name = name
  trail.Attachment0 = attachment0
  trail.Attachment1 = attachment1
  trail.FaceCamera = false
  trail.Texture = WAKE_TEXTURE
  trail.TextureMode = Enum.TextureMode.Wrap
  trail.Lifetime = 1.1
  trail.MinLength = 0.35
  trail.MaxLength = 100
  trail.Color = ColorSequence.new(Color3.fromRGB(214, 240, 239))
  trail.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.15),
    NumberSequenceKeypoint.new(0.7, 0.55),
    NumberSequenceKeypoint.new(1, 1),
  })
  trail.WidthScale = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.08),
    NumberSequenceKeypoint.new(0.18, 1),
    NumberSequenceKeypoint.new(1, 0.04),
  })
  trail.Enabled = false
  return trail
end

function WakeController.new(runtime, waveField, scheduler)
  return setmetatable({
    runtime = runtime,
    waveField = waveField,
    scheduler = scheduler,
    ships = {},
    addedConnection = nil,
    removedConnection = nil,
    connection = nil,
    accumulator = 0,
    lastSampleCount = 0,
  }, WakeController)
end

function WakeController:_Track(model: Model)
  if self.ships[model] then return end
  local root = findHullRoot(model)
  if not root then return end
  local holder = Instance.new("Part")
  holder.Name = "OceanWake_" .. model.Name
  holder.Anchored = true
  holder.CanCollide = false
  holder.CanTouch = false
  holder.CanQuery = false
  holder.CastShadow = false
  holder.Transparency = 1
  holder.Size = Vector3.new(0.1, 0.1, 0.1)
  holder.Parent = self.runtime

  local portBow = Instance.new("Attachment")
  portBow.Name = "PortBow"
  portBow.Parent = holder
  local portStern = Instance.new("Attachment")
  portStern.Name = "PortStern"
  portStern.Parent = holder
  local starboardBow = Instance.new("Attachment")
  starboardBow.Name = "StarboardBow"
  starboardBow.Parent = holder
  local starboardStern = Instance.new("Attachment")
  starboardStern.Name = "StarboardStern"
  starboardStern.Parent = holder
  local portTrail = createTrail("PortWake", portBow, portStern)
  portTrail.Parent = holder
  local starboardTrail = createTrail("StarboardWake", starboardBow, starboardStern)
  starboardTrail.Parent = holder

  self.ships[model] = {
    model = model,
    root = root,
    holder = holder,
    portBow = portBow,
    portStern = portStern,
    starboardBow = starboardBow,
    starboardStern = starboardStern,
    portTrail = portTrail,
    starboardTrail = starboardTrail,
    lastRootPosition = root.Position,
    lastSampleTime = -math.huge,
    active = false,
  }
end

function WakeController:_Untrack(model: Model)
  local entry = self.ships[model]
  if not entry then return end
  clearTrail(entry.portTrail)
  clearTrail(entry.starboardTrail)
  entry.holder:Destroy()
  self.ships[model] = nil
end

function WakeController:_Rescan()
  for _, instance in ipairs(CollectionService:GetTagged("OceanShip")) do
    if instance:IsA("Model") then self:_Track(instance) end
  end
end

function WakeController:_Clear(entry)
  clearTrail(entry.portTrail)
  clearTrail(entry.starboardTrail)
  entry.active = false
end

function WakeController:_UpdateEntry(entry, now: number)
  local root = entry.root
  if not root.Parent then
    self:_Untrack(entry.model)
    return 0
  end
  local displacement = root.Position - entry.lastRootPosition
  if displacement.Magnitude > TELEPORT_DISTANCE then
    self:_Clear(entry)
  end
  entry.lastRootPosition = root.Position
  local velocity = root.AssemblyLinearVelocity
  local speed = velocity.Magnitude
  if speed < 1.5 then
    self:_Clear(entry)
    return 0
  end
  local beam = math.max(root.Size.X, 4)
  local length = math.max(root.Size.Z, 8)
  local forward = root.CFrame.LookVector
  local right = root.CFrame.RightVector
  local bowCenter = root.Position + forward * (length * 0.42)
  local sternCenter = root.Position - forward * (length * 0.42)
  local samplePositions = {
    bowCenter - right * beam * 0.45,
    sternCenter - right * beam * 0.55,
    bowCenter + right * beam * 0.45,
    sternCenter + right * beam * 0.55,
  }
  local samples = table.create(4)
  for index, position in ipairs(samplePositions) do
    local sample = self.scheduler
      and self.scheduler:Sample(Vector2.new(position.X, position.Z), now, {inverseIterations = 3, includeEvents = false})
      or self.waveField:SampleForGameplayWorldXZ(Vector2.new(position.X, position.Z), now, {inverseIterations = 3, includeEvents = false})
    samples[index] = sample
  end
  entry.holder.CFrame = root.CFrame
  entry.portBow.Position = entry.holder.CFrame:PointToObjectSpace(samples[1].position + samples[1].normal * 0.05)
  entry.portStern.Position = entry.holder.CFrame:PointToObjectSpace(samples[2].position + samples[2].normal * 0.05)
  entry.starboardBow.Position = entry.holder.CFrame:PointToObjectSpace(samples[3].position + samples[3].normal * 0.05)
  entry.starboardStern.Position = entry.holder.CFrame:PointToObjectSpace(samples[4].position + samples[4].normal * 0.05)
  local intensity = math.clamp((speed - 1.5) / 24, 0, 1)
  entry.portTrail.WidthScale = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.08 + intensity * 0.12),
    NumberSequenceKeypoint.new(0.18, 0.55 + intensity * 0.65),
    NumberSequenceKeypoint.new(1, 0.04),
  })
  entry.starboardTrail.WidthScale = entry.portTrail.WidthScale
  entry.portTrail.MaxLength = math.clamp(length * (2.5 + intensity * 2), 24, 120)
  entry.starboardTrail.MaxLength = entry.portTrail.MaxLength
  entry.portTrail.Enabled = true
  entry.starboardTrail.Enabled = true
  entry.active = true
  entry.lastSampleTime = now
  return 4
end

function WakeController:_Tick(dt: number)
  if self.runtime:GetAttribute("OceanWakesEnabled") ~= true then
    for _, entry in pairs(self.ships) do self:_Clear(entry) end
    return
  end
  debug.profilebegin("Ocean/Wakes")
  local now = self.waveField:GetSynchronizedTime()
  local count = 0
  for _, entry in pairs(self.ships) do count += self:_UpdateEntry(entry, now) end
  self.lastSampleCount = count
  debug.profileend()
end

function WakeController:Start()
  if self.connection then return end
  self:_Rescan()
  self.addedConnection = CollectionService:GetInstanceAddedSignal("OceanShip"):Connect(function(instance)
    if instance:IsA("Model") then self:_Track(instance) end
  end)
  self.removedConnection = CollectionService:GetInstanceRemovedSignal("OceanShip"):Connect(function(instance)
    if instance:IsA("Model") then self:_Untrack(instance) end
  end)
  self.connection = RunService.RenderStepped:Connect(function(dt)
    self.accumulator += dt
    if self.accumulator < UPDATE_INTERVAL then return end
    local tickDt = self.accumulator
    self.accumulator = 0
    self:_Tick(tickDt)
  end)
end

function WakeController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  if self.addedConnection then self.addedConnection:Disconnect() self.addedConnection = nil end
  if self.removedConnection then self.removedConnection:Disconnect() self.removedConnection = nil end
  for model in pairs(self.ships) do self:_Untrack(model) end
  table.clear(self.ships)
end

return WakeController
