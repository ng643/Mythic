--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FoamController = {}
FoamController.__index = FoamController

local FOAM_TEXTURE = "rbxassetid://140229416139720"
local CELL_SIZE = 24
local TICK_RATE = 1 / 8
local MAX_DISTANCE = 280

local function hash(x: number, z: number): number
  local value = math.sin(x * 12.9898 + z * 78.233) * 43758.5453
  return value - math.floor(value)
end
local function disableEntry(entry)
  entry.active = false
  entry.key = nil
  entry.lastSeen = -math.huge
  entry.age = 0
  entry.emitter.Enabled = false
  entry.ribbon.Enabled = false
  pcall(function() entry.ribbon:Clear() end)
end

function FoamController.new(waveField, runtime, scheduler)
  return setmetatable({
    waveField = waveField,
    runtime = runtime,
    scheduler = scheduler,
    pool = {},
    tracks = {},
    cap = 24,
    connection = nil,
    clock = 0,
    lastSampleCount = 0,
  }, FoamController)
end

function FoamController:_CreateEntry(index: number)
  local anchor = Instance.new("Part")
  anchor.Name = string.format("CrestFoam_%02d", index)
  anchor.Anchored = true
  anchor.CanCollide = false
  anchor.CanTouch = false
  anchor.CanQuery = false
  anchor.CastShadow = false
  anchor.Transparency = 1
  anchor.Size = Vector3.new(0.1, 0.1, 0.1)
  anchor.Parent = self.runtime

  local attachment = Instance.new("Attachment")
  attachment.Name = "FoamAttachment"
  attachment.Parent = anchor
  local emitter = Instance.new("ParticleEmitter")
  emitter.Name = "CrestFoamMist"
  emitter.Enabled = false
  emitter.Rate = 0
  emitter.Lifetime = NumberRange.new(0.7, 1.5)
  emitter.Speed = NumberRange.new(0.15, 1.2)
  emitter.Drag = 2.5
  emitter.SpreadAngle = Vector2.new(18, 18)
  emitter.Acceleration = Vector3.new(0, 1.2, 0)
  emitter.Rotation = NumberRange.new(0, 360)
  emitter.RotSpeed = NumberRange.new(-25, 25)
  emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(0.2, 0.8), NumberSequenceKeypoint.new(1, 0.04)})
  emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(0.72, 0.5), NumberSequenceKeypoint.new(1, 1)})
  emitter.Color = ColorSequence.new(Color3.fromRGB(238, 250, 248))
  emitter.LightEmission = 0.05
  emitter.Texture = FOAM_TEXTURE
  emitter.Parent = attachment

  local ribbonA = Instance.new("Attachment")
  ribbonA.Name = "CrestRibbonA"
  ribbonA.Parent = anchor
  local ribbonB = Instance.new("Attachment")
  ribbonB.Name = "CrestRibbonB"
  ribbonB.Parent = anchor
  local ribbon = Instance.new("Trail")
  ribbon.Name = "CrestFoamRibbon"
  ribbon.Attachment0 = ribbonA
  ribbon.Attachment1 = ribbonB
  ribbon.FaceCamera = false
  ribbon.Texture = FOAM_TEXTURE
  ribbon.TextureMode = Enum.TextureMode.Wrap
  ribbon.Lifetime = 1.8
  ribbon.MinLength = 0.2
  ribbon.MaxLength = 28
  ribbon.Color = ColorSequence.new(Color3.fromRGB(236, 249, 247))
  ribbon.Transparency = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.16),
    NumberSequenceKeypoint.new(0.72, 0.55),
    NumberSequenceKeypoint.new(1, 1),
  })
  ribbon.WidthScale = NumberSequence.new({
    NumberSequenceKeypoint.new(0, 0.08),
    NumberSequenceKeypoint.new(0.35, 1),
    NumberSequenceKeypoint.new(1, 0.04),
  })
  ribbon.Enabled = false
  ribbon.Parent = anchor

  local entry = {
    anchor = anchor,
    emitter = emitter,
    ribbon = ribbon,
    ribbonA = ribbonA,
    ribbonB = ribbonB,
    key = nil,
    active = false,
    position = Vector3.zero,
    normal = Vector3.yAxis,
    tangent = Vector3.xAxis,
    lastSeen = -math.huge,
    age = 0,
    foam = 0,
    lastEmit = -math.huge,
  }
  table.insert(self.pool, entry)
  return entry
end

function FoamController:_ResizePool()
  while #self.pool < self.cap do self:_CreateEntry(#self.pool + 1) end
  while #self.pool > self.cap do
    local entry = table.remove(self.pool)
    if entry.key then self.tracks[entry.key] = nil end
    entry.anchor:Destroy()
  end
end

function FoamController:SetCap(cap: number)
  local nextCap = math.clamp(math.floor(cap), 0, 96)
  if nextCap == self.cap and (#self.pool == 0 or #self.pool == nextCap) then return end
  self.cap = nextCap
  self:_ResizePool()
end

function FoamController:_HideAll()
  for _, entry in ipairs(self.pool) do
    entry.emitter.Enabled = false
    entry.ribbon.Enabled = false
  end
end

function FoamController:_FindEntry(key: string)
  local existing = self.tracks[key]
  if existing then return existing end
  local free = nil
  local oldest = nil
  for _, entry in ipairs(self.pool) do
    if not entry.active then free = entry break end
    if not oldest or entry.lastSeen < oldest.lastSeen then oldest = entry end
  end
  local entry = free or oldest
  if not entry then return nil end
  if entry.key then self.tracks[entry.key] = nil end
  pcall(function() entry.ribbon:Clear() end)
  entry.key = key
  entry.active = true
  entry.age = 0
  self.tracks[key] = entry
  return entry
end

function FoamController:_UpdateTrack(entry, sample, key: string, now: number, dt: number)
  local position = sample.position + sample.normal * 0.06
  local velocity = Vector3.new(sample.velocity.X, 0, sample.velocity.Z)
  if velocity.Magnitude < 0.05 then velocity = Vector3.xAxis end
  local tangent = velocity.Unit
  if entry.active and entry.key == key then
    entry.position = entry.position:Lerp(position, 0.65)
    entry.normal = entry.normal:Lerp(sample.normal, 0.5).Unit
  else
    entry.position = position
    entry.normal = sample.normal
  end
  entry.tangent = tangent
  entry.lastSeen = now
  entry.age = math.min(entry.age + dt, 3)
  entry.foam = math.max(entry.foam * 0.82, sample.foam)
  entry.anchor.CFrame = CFrame.lookAt(entry.position, entry.position + tangent, entry.normal)
  local width = math.clamp(0.28 + entry.foam * 2.2, 0.28, 3.2)
  entry.ribbonA.Position = Vector3.new(-width, 0, 0)
  entry.ribbonB.Position = Vector3.new(width, 0, 0)
  entry.ribbon.Enabled = true
  entry.emitter.Enabled = true
  if now - entry.lastEmit > 0.35 and entry.foam > 0.38 then
    entry.emitter:Emit(math.clamp(math.floor(entry.foam * 4), 1, 5))
    entry.lastEmit = now
  end
end

function FoamController:_Tick(dt: number)
  if self.runtime:GetAttribute("OceanFoamEnabled") ~= true then
    self:_HideAll()
    return
  end
  local camera = Workspace.CurrentCamera
  if not camera then return end
  debug.profilebegin("Ocean/Foam")
  local now = self.waveField:GetSynchronizedTime()
  local center = camera.CFrame.Position
  local centerCellX = math.floor(center.X / CELL_SIZE + 0.5)
  local centerCellZ = math.floor(center.Z / CELL_SIZE + 0.5)
  local seen = {}
  local sampleCount = 0
  for gz = -3, 3 do
    for gx = -3, 3 do
      local cellX = centerCellX + gx
      local cellZ = centerCellZ + gz
      if hash(cellX, cellZ) > 0.23 then
        local worldX = cellX * CELL_SIZE + (hash(cellX + 17, cellZ - 11) - 0.5) * CELL_SIZE * 0.55
        local worldZ = cellZ * CELL_SIZE + (hash(cellX - 7, cellZ + 23) - 0.5) * CELL_SIZE * 0.55
        local sample = self.scheduler
          and self.scheduler:Sample(Vector2.new(worldX, worldZ), now, {
            inverseIterations = 2,
            componentCap = self.waveField:GetGameplayComponentCap(),
            foamMultiplier = 1.5,
          })
          or self.waveField:SampleWorldXZ(Vector2.new(worldX, worldZ), now, {
            inverseIterations = 2,
            componentCap = self.waveField:GetGameplayComponentCap(),
            foamMultiplier = 1.5,
          })
        sampleCount += 1
        local distance = (sample.position - center).Magnitude
        local signal = sample.foam * 0.72 + sample.crestMotion * 0.12 + sample.slope * 0.08 + sample.foamPersistence * 0.08
        if signal > 0.16 and distance < MAX_DISTANCE then
          local key = tostring(cellX) .. ":" .. tostring(cellZ)
          local entry = self:_FindEntry(key)
          if entry then
            seen[key] = true
            self:_UpdateTrack(entry, sample, key, now, TICK_RATE)
          end
        end
      end
    end
  end
  for _, entry in ipairs(self.pool) do
    if entry.active and not seen[entry.key] then
      entry.age += TICK_RATE
      entry.foam *= 0.88
      entry.position += entry.tangent * math.clamp(entry.foam * 0.4, 0, 0.6)
      entry.anchor.CFrame = CFrame.lookAt(entry.position, entry.position + entry.tangent, entry.normal)
      if now - entry.lastSeen > 0.55 or entry.age > 2.8 then
        if entry.key then self.tracks[entry.key] = nil end
        disableEntry(entry)
      end
    end
  end
  self.lastSampleCount = sampleCount
  debug.profileend()
end

function FoamController:Start()
  if self.connection then return end
  self:_ResizePool()
  self.connection = RunService.RenderStepped:Connect(function(dt)
    self.clock += dt
    if self.clock < TICK_RATE then return end
    local tickDt = self.clock
    self.clock = 0
    self:_Tick(tickDt)
  end)
end

function FoamController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  for _, entry in ipairs(self.pool) do entry.anchor:Destroy() end
  table.clear(self.pool)
  table.clear(self.tracks)
end

return FoamController
