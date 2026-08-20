--!strict

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local WakeController = {}
WakeController.__index = WakeController

local SURFACE_OFFSET = 0.08
local MIN_SPEED = 1.5
local MAX_FORWARD_SPEED = 42
local MAX_TURN_RATE = 1.1
local MAX_ACCELERATION = 18

type SurfacePoint = {
  position: Vector3,
  normal: Vector3,
  velocity: Vector3,
  foam: number,
}

type TrailPair = {
  first: Attachment,
  second: Attachment,
  trail: Trail,
  widthBin: number,
  opacityBin: number,
}

local widthSequences: {[number]: NumberSequence} = {}
local opacitySequences: {[number]: NumberSequence} = {}

local function getWidthSequence(bin: number): NumberSequence
  local sequence = widthSequences[bin]
  if sequence then return sequence end
  local scale = bin / 20
  sequence = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.08 * scale),
    NumberSequenceKeypoint.new(0.2, scale),
    NumberSequenceKeypoint.new(0.72, 0.82 * scale),
    NumberSequenceKeypoint.new(1, 0.03 * scale),
  })
  widthSequences[bin] = sequence
  return sequence
end

local function getOpacitySequence(bin: number): NumberSequence
  local sequence = opacitySequences[bin]
  if sequence then return sequence end
  local opacity = bin / 20
  sequence = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 1 - opacity * 0.78),
    NumberSequenceKeypoint.new(0.22, 1 - opacity * 0.58),
    NumberSequenceKeypoint.new(0.72, 1 - opacity * 0.35),
    NumberSequenceKeypoint.new(1, 1),
  })
  opacitySequences[bin] = sequence
  return sequence
end

local function makeTrail(holder: Part, name: string): TrailPair
  local first = Instance.new("Attachment")
  first.Name = name .. "_A"
  first.Parent = holder
  local second = Instance.new("Attachment")
  second.Name = name .. "_B"
  second.Parent = holder

  local trail = Instance.new("Trail")
  trail.Name = name
  trail.Attachment0 = first
  trail.Attachment1 = second
  trail.Enabled = false
  trail.Lifetime = 0.8
  trail.MinLength = 0.2
  trail.MaxLength = 60
  trail.FaceCamera = false
  trail.Texture = "rbxassetid://140229416139720"
  trail.Color = ColorSequence.new(Color3.fromRGB(194, 231, 229))
  trail.Transparency = getOpacitySequence(8)
  trail.WidthScale = getWidthSequence(12)
  trail.LightEmission = 0.05
  trail.Parent = holder

  return {
    first = first,
    second = second,
    trail = trail,
    widthBin = 12,
    opacityBin = 8,
  }
end

local function finiteNumber(value: any): boolean
  return type(value) == "number" and value == value and value ~= math.huge and value ~= -math.huge
end

local function numberAttribute(model: Model, name: string, fallback: number, minimum: number): number
  local value = model:GetAttribute(name)
  if finiteNumber(value) then
    return math.max(value, minimum)
  end
  return fallback
end

local function horizontalUnit(vector: Vector3, fallback: Vector3): Vector3
  local horizontal = Vector3.new(vector.X, 0, vector.Z)
  if horizontal.Magnitude < 1e-4 then return fallback end
  return horizontal.Unit
end

local function tangentUnit(vector: Vector3, normal: Vector3, fallback: Vector3): Vector3
  local tangent = vector - normal * vector:Dot(normal)
  if tangent.Magnitude < 1e-4 then
    tangent = fallback - normal * fallback:Dot(normal)
  end
  if tangent.Magnitude < 1e-4 then
    tangent = Vector3.xAxis - normal * normal.X
  end
  if tangent.Magnitude < 1e-4 then
    tangent = Vector3.zAxis - normal * normal.Z
  end
  return tangent.Unit
end

local function surfaceFrame(point: SurfacePoint, preferredTangent: Vector3): CFrame
  local normal = point.normal
  local tangent = tangentUnit(preferredTangent, normal, Vector3.zAxis)
  return CFrame.lookAt(point.position, point.position + tangent, normal)
end

local function setAttachmentWorldFrame(holder: Part, attachment: Attachment, frame: CFrame)
  attachment.CFrame = holder.CFrame:ToObjectSpace(frame)
end

local function setTrailStyle(
  pair: TrailPair,
  intensity: number,
  width: number,
  lifetime: number,
  maxLength: number,
  enabled: boolean
)
  local widthBin = math.clamp(math.floor(width * 20 + 0.5), 1, 40)
  if pair.widthBin ~= widthBin then
    pair.widthBin = widthBin
    pair.trail.WidthScale = getWidthSequence(widthBin)
  end
  local opacityBin = math.clamp(math.floor(math.clamp(intensity, 0, 1) * 20 + 0.5), 1, 20)
  if pair.opacityBin ~= opacityBin then
    pair.opacityBin = opacityBin
    pair.trail.Transparency = getOpacitySequence(opacityBin)
  end
  pair.trail.Lifetime = lifetime
  pair.trail.MaxLength = maxLength
  pair.trail.Enabled = enabled
end

local function configuredOffset(model: Model, root: BasePart, key: string, fallback: Vector3): Vector3
  local attribute = model:GetAttribute("OceanWake" .. key .. "Offset")
  if typeof(attribute) == "Vector3" then
    return Vector3.new(attribute.X, 0, attribute.Z)
  end

  local names = {
    "Wake" .. key,
    key .. "Wake",
    "OceanWake" .. key,
    "Wake" .. key .. "Point",
  }
  for _, name in ipairs(names) do
    local instance = model:FindFirstChild(name, true)
    if instance and instance:IsA("Attachment") then
      local localPosition = root.CFrame:PointToObjectSpace(instance.WorldPosition)
      return Vector3.new(localPosition.X, 0, localPosition.Z)
    end
  end
  return fallback
end

function WakeController.new(runtime, waveField)
  return setmetatable({
    runtime = runtime,
    waveField = waveField,
    tracks = {},
    connection = nil,
    added = nil,
    removed = nil,
  }, WakeController)
end

function WakeController:_Track(model: Instance)
  if not model:IsA("Model") or self.tracks[model] then return end
  local root = model.PrimaryPart or model:FindFirstChild("HullRoot", true)
  if not root or not root:IsA("BasePart") then return end

  local length = numberAttribute(model, "OceanWakeLength", math.max(root.Size.Z, 4), 2)
  local beam = numberAttribute(model, "OceanWakeBeam", math.max(root.Size.X, 2), 1)
  local offsets = {
    bow = configuredOffset(model, root, "Bow", Vector3.new(0, 0, -length * 0.55)),
    stern = configuredOffset(model, root, "Stern", Vector3.new(0, 0, length * 0.48)),
    port = configuredOffset(model, root, "Port", Vector3.new(-beam * 0.52, 0, length * 0.22)),
    starboard = configuredOffset(model, root, "Starboard", Vector3.new(beam * 0.52, 0, length * 0.22)),
  }

  local holder = Instance.new("Part")
  holder.Name = "WakeSurfaceEmitter_" .. model.Name
  holder.Anchored = true
  holder.CanCollide = false
  holder.CanTouch = false
  holder.CanQuery = false
  holder.CastShadow = false
  holder.Transparency = 1
  holder.Size = Vector3.new(0.1, 0.1, 0.1)
  holder.CFrame = CFrame.new(root.Position)
  holder.Parent = self.runtime

  local bowPort = makeTrail(holder, "BowPortWake")
  local bowStarboard = makeTrail(holder, "BowStarboardWake")
  local sternPort = makeTrail(holder, "SternPortWake")
  local sternStarboard = makeTrail(holder, "SternStarboardWake")

  self.tracks[model] = {
    root = root,
    holder = holder,
    offsets = offsets,
    beam = beam,
    trails = {
      bowPort = bowPort,
      bowStarboard = bowStarboard,
      sternPort = sternPort,
      sternStarboard = sternStarboard,
    },
    samplePoints = {},
    previousVelocity = root.AssemblyLinearVelocity,
    filteredSpeed = 0,
    filteredTurn = 0,
    filteredAcceleration = 0,
  }
end

function WakeController:_Untrack(model: Instance)
  local track = self.tracks[model]
  if not track then return end
  track.holder:Destroy()
  self.tracks[model] = nil
end

function WakeController:_SampleWorldXZ(worldXZ: Vector2, now: number): SurfacePoint
  local sample = self.waveField:SampleForGameplayWorldXZ(worldXZ, now, {inverseIterations = 3})
  local normal = sample.normal
  if normal.Magnitude < 1e-4 then normal = Vector3.yAxis else normal = normal.Unit end
  return {
    position = sample.position + normal * SURFACE_OFFSET,
    normal = normal,
    velocity = sample.velocity,
    foam = sample.foam,
  }
end

function WakeController:_SampleLocal(root: BasePart, localOffset: Vector3, now: number): SurfacePoint
  local worldPosition = root.CFrame:PointToWorldSpace(localOffset)
  return self:_SampleWorldXZ(Vector2.new(worldPosition.X, worldPosition.Z), now)
end

function WakeController:_UpdateTrack(track, dt: number, now: number)
  local root = track.root
  if not root.Parent then return false end

  local velocity = root.AssemblyLinearVelocity
  local angularVelocity = root.AssemblyAngularVelocity
  local dtSafe = math.clamp(dt, 1 / 240, 0.1)
  local acceleration = (velocity - track.previousVelocity) / dtSafe
  track.previousVelocity = velocity

  local localVelocity = root.CFrame:VectorToObjectSpace(velocity)
  local forwardSpeed = math.max(0, -localVelocity.Z)
  local totalSpeed = velocity.Magnitude
  local lateralSpeed = math.abs(localVelocity.X)
  local turnRate = math.abs(angularVelocity:Dot(Vector3.yAxis))
  local speedTarget = math.clamp(math.max(forwardSpeed, totalSpeed * 0.65) / MAX_FORWARD_SPEED, 0, 1)
  local turnTarget = math.clamp(turnRate / MAX_TURN_RATE + lateralSpeed / (totalSpeed + 4) * 0.3, 0, 1)
  local accelerationTarget = math.clamp(acceleration.Magnitude / MAX_ACCELERATION, 0, 1)
  local smoothing = 1 - math.exp(-dtSafe * 8)
  track.filteredSpeed += (speedTarget - track.filteredSpeed) * smoothing
  track.filteredTurn += (turnTarget - track.filteredTurn) * smoothing
  track.filteredAcceleration += (accelerationTarget - track.filteredAcceleration) * smoothing

  local samplePoints = track.samplePoints
  samplePoints.bow = self:_SampleLocal(root, track.offsets.bow, now)
  samplePoints.stern = self:_SampleLocal(root, track.offsets.stern, now)
  samplePoints.port = self:_SampleLocal(root, track.offsets.port, now)
  samplePoints.starboard = self:_SampleLocal(root, track.offsets.starboard, now)

  local forward = horizontalUnit(root.CFrame.LookVector, Vector3.new(0, 0, -1))
  local backwards = -forward
  local lateral = Vector3.new(-forward.Z, 0, forward.X)
  local turnSign = angularVelocity:Dot(Vector3.yAxis) >= 0 and 1 or -1
  local tailLength = track.beam * (0.75 + track.filteredSpeed * 2.8 + track.filteredTurn * 0.65)
  local tailOffset = lateral * (turnSign * track.filteredTurn * track.beam * 0.42)
  local sternSurface = samplePoints.stern.position - samplePoints.stern.normal * SURFACE_OFFSET
  local sternTailPosition = sternSurface + backwards * tailLength + tailOffset
  samplePoints.sternTail = self:_SampleWorldXZ(Vector2.new(sternTailPosition.X, sternTailPosition.Z), now)

  local holderOrigin = Vector3.new(root.Position.X, root.Position.Y, root.Position.Z)
  track.holder.CFrame = CFrame.new(holderOrigin)

  local bowIntensity = math.clamp(
    track.filteredSpeed * 0.78 + track.filteredAcceleration * 0.24 + track.filteredTurn * 0.18,
    0,
    1
  )
  local sternIntensity = math.clamp(
    track.filteredSpeed * 0.96 + track.filteredAcceleration * 0.18 + track.filteredTurn * 0.34,
    0,
    1
  )
  local active = math.max(bowIntensity, sternIntensity) > 0.035 and totalSpeed > MIN_SPEED
  local bowLifetime = math.clamp(0.5 + track.filteredSpeed * 0.7 + track.filteredTurn * 0.35, 0.45, 1.8)
  local sternLifetime = math.clamp(0.75 + track.filteredSpeed * 1.05 + track.filteredTurn * 0.55, 0.65, 2.6)
  local bowWidth = math.clamp(0.42 + track.filteredSpeed * 0.9 + track.filteredTurn * 0.35, 0.35, 2.2)
  local sternWidth = math.clamp(0.58 + track.filteredSpeed * 1.25 + track.filteredTurn * 0.55, 0.45, 2.8)
  local bowMaxLength = math.clamp(track.beam * (2 + track.filteredSpeed * 3.5), 12, 80)
  local sternMaxLength = math.clamp(tailLength * (3 + track.filteredSpeed * 3), 18, 120)

  local bowPortTangent = samplePoints.port.position - samplePoints.bow.position
  local bowStarboardTangent = samplePoints.starboard.position - samplePoints.bow.position
  local sternPortTangent = samplePoints.sternTail.position - samplePoints.port.position
  local sternStarboardTangent = samplePoints.sternTail.position - samplePoints.starboard.position

  local bowPort = track.trails.bowPort
  setAttachmentWorldFrame(track.holder, bowPort.first, surfaceFrame(samplePoints.bow, bowPortTangent))
  setAttachmentWorldFrame(track.holder, bowPort.second, surfaceFrame(samplePoints.port, bowPortTangent))
  setTrailStyle(bowPort, bowIntensity, bowWidth, bowLifetime, bowMaxLength, active)

  local bowStarboard = track.trails.bowStarboard
  setAttachmentWorldFrame(track.holder, bowStarboard.first, surfaceFrame(samplePoints.bow, bowStarboardTangent))
  setAttachmentWorldFrame(track.holder, bowStarboard.second, surfaceFrame(samplePoints.starboard, bowStarboardTangent))
  setTrailStyle(bowStarboard, bowIntensity, bowWidth, bowLifetime, bowMaxLength, active)

  local sternPort = track.trails.sternPort
  setAttachmentWorldFrame(track.holder, sternPort.first, surfaceFrame(samplePoints.port, sternPortTangent))
  setAttachmentWorldFrame(track.holder, sternPort.second, surfaceFrame(samplePoints.sternTail, sternPortTangent))
  setTrailStyle(sternPort, sternIntensity, sternWidth, sternLifetime, sternMaxLength, active)

  local sternStarboard = track.trails.sternStarboard
  setAttachmentWorldFrame(track.holder, sternStarboard.first, surfaceFrame(samplePoints.starboard, sternStarboardTangent))
  setAttachmentWorldFrame(track.holder, sternStarboard.second, surfaceFrame(samplePoints.sternTail, sternStarboardTangent))
  setTrailStyle(sternStarboard, sternIntensity, sternWidth, sternLifetime, sternMaxLength, active)
  return true
end

function WakeController:Start()
  if self.connection then return end
  if not self.waveField then
    warn("Ocean wakes did not start: missing synchronized WaveField")
    return
  end

  local function rescanTaggedShips()
    for _, model in ipairs(CollectionService:GetTagged("OceanShip")) do self:_Track(model) end
  end
  rescanTaggedShips()
  task.spawn(function()
    for _ = 1, 12 do
      task.wait(0.25)
      rescanTaggedShips()
    end
  end)
  self.added = CollectionService:GetInstanceAddedSignal("OceanShip"):Connect(function(model) self:_Track(model) end)
  self.removed = CollectionService:GetInstanceRemovedSignal("OceanShip"):Connect(function(model) self:_Untrack(model) end)
  self.connection = RunService.RenderStepped:Connect(function(dt)
    debug.profilebegin("Ocean/Wakes")
    local enabled = self.runtime:GetAttribute("OceanWakesEnabled") ~= false
    local now = self.waveField:GetSynchronizedTime()
    for model, track in pairs(self.tracks) do
      if not enabled then
        for _, pair in pairs(track.trails) do pair.trail.Enabled = false end
      elseif not self:_UpdateTrack(track, math.clamp(dt, 0, 0.1), now) then
        self:_Untrack(model)
      end
    end
    debug.profileend()
  end)
end

function WakeController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  if self.added then self.added:Disconnect() self.added = nil end
  if self.removed then self.removed:Disconnect() self.removed = nil end
  for model in pairs(self.tracks) do self:_Untrack(model) end
end

return WakeController
