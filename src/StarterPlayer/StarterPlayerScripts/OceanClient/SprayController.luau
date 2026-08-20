--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SprayController = {}
SprayController.__index = SprayController

local SPRAY_TEXTURE = "rbxassetid://138338217463878"
local CELL_SIZE = 28
local TICK_RATE = 1 / 7
local MAX_DISTANCE = 240

local function hash(x: number, z: number): number
  local value = math.sin(x * 17.123 + z * 41.731) * 15731.743
  return value - math.floor(value)
end

function SprayController.new(waveField, runtime, scheduler)
  return setmetatable({
    waveField = waveField,
    runtime = runtime,
    scheduler = scheduler,
    pool = {},
    tracks = {},
    cap = 12,
    connection = nil,
    clock = 0,
    lastSampleCount = 0,
  }, SprayController)
end

function SprayController:_CreateEntry(index: number)
  local anchor = Instance.new("Part")
  anchor.Name = string.format("CrestSpray_%02d", index)
  anchor.Anchored = true
  anchor.CanCollide = false
  anchor.CanTouch = false
  anchor.CanQuery = false
  anchor.CastShadow = false
  anchor.Transparency = 1
  anchor.Size = Vector3.new(0.1, 0.1, 0.1)
  anchor.Parent = self.runtime
  local attachment = Instance.new("Attachment")
  attachment.Name = "SprayAttachment"
  attachment.Parent = anchor
  local emitter = Instance.new("ParticleEmitter")
  emitter.Name = "CrestSprayMist"
  emitter.Texture = SPRAY_TEXTURE
  emitter.Enabled = false
  emitter.Rate = 0
  emitter.Lifetime = NumberRange.new(0.35, 0.9)
  emitter.Speed = NumberRange.new(1.5, 5.5)
  emitter.Drag = 3.5
  emitter.SpreadAngle = Vector2.new(24, 24)
  emitter.Acceleration = Vector3.new(0, -Workspace.Gravity * 0.08, 0)
  emitter.Rotation = NumberRange.new(0, 360)
  emitter.RotSpeed = NumberRange.new(-80, 80)
  emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.08), NumberSequenceKeypoint.new(0.16, 0.3), NumberSequenceKeypoint.new(1, 0.02)})
  emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.15), NumberSequenceKeypoint.new(0.65, 0.5), NumberSequenceKeypoint.new(1, 1)})
  emitter.Color = ColorSequence.new(Color3.fromRGB(228, 246, 245))
  emitter.LightEmission = 0.1
  emitter.Parent = attachment
  local entry = {
    anchor = anchor,
    emitter = emitter,
    key = nil,
    active = false,
    position = Vector3.zero,
    normal = Vector3.yAxis,
    tangent = Vector3.xAxis,
    lastSeen = -math.huge,
    age = 0,
    intensity = 0,
  }
  table.insert(self.pool, entry)
  return entry
end

function SprayController:_ResizePool()
  while #self.pool < self.cap do self:_CreateEntry(#self.pool + 1) end
  while #self.pool > self.cap do
    local entry = table.remove(self.pool)
    if entry.key then self.tracks[entry.key] = nil end
    entry.anchor:Destroy()
  end
end

function SprayController:SetCap(cap: number)
  local nextCap = math.clamp(math.floor(cap), 0, 64)
  if nextCap == self.cap and (#self.pool == 0 or #self.pool == nextCap) then return end
  self.cap = nextCap
  self:_ResizePool()
end

function SprayController:_HideAll()
  for _, entry in ipairs(self.pool) do entry.emitter.Enabled = false end
end

function SprayController:_FindEntry(key: string)
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
  entry.key = key
  entry.active = true
  entry.age = 0
  self.tracks[key] = entry
  return entry
end

function SprayController:_Tick(dt: number)
  if self.runtime:GetAttribute("OceanSprayEnabled") ~= true then
    self:_HideAll()
    return
  end
  local camera = Workspace.CurrentCamera
  if not camera then return end
  debug.profilebegin("Ocean/Spray")
  local now = self.waveField:GetSynchronizedTime()
  local state = self.waveField:GetState()
  local center = camera.CFrame.Position
  local centerCellX = math.floor(center.X / CELL_SIZE + 0.5)
  local centerCellZ = math.floor(center.Z / CELL_SIZE + 0.5)
  local seen = {}
  local sampleCount = 0
  for gz = -2, 2 do
    for gx = -2, 2 do
      local cellX = centerCellX + gx
      local cellZ = centerCellZ + gz
      if hash(cellX, cellZ) > 0.2 then
        local worldX = cellX * CELL_SIZE + (hash(cellX + 3, cellZ + 19) - 0.5) * CELL_SIZE * 0.6
        local worldZ = cellZ * CELL_SIZE + (hash(cellX - 13, cellZ - 5) - 0.5) * CELL_SIZE * 0.6
        local sample = self.scheduler
          and self.scheduler:Sample(Vector2.new(worldX, worldZ), now, {
            inverseIterations = 2,
            componentCap = self.waveField:GetGameplayComponentCap(),
            foamMultiplier = 1.6,
          })
          or self.waveField:SampleWorldXZ(Vector2.new(worldX, worldZ), now, {
            inverseIterations = 2,
            componentCap = self.waveField:GetGameplayComponentCap(),
            foamMultiplier = 1.6,
          })
        sampleCount += 1
        local distance = (sample.position - center).Magnitude
        local signal = sample.foam * 0.55 + sample.crestMotion * 0.25 + sample.compression * 0.15 + sample.slope * 0.05
        local threshold = state.stormIntensity > 0.7 and 0.24 or state.stormIntensity > 0.35 and 0.34 or 0.48
        if signal > threshold and distance < MAX_DISTANCE then
          local key = tostring(cellX) .. ":" .. tostring(cellZ)
          local entry = self:_FindEntry(key)
          if entry then
            local position = sample.position + sample.normal * 0.08
            local tangent = Vector3.new(sample.velocity.X, 0, sample.velocity.Z)
            if tangent.Magnitude < 0.05 then tangent = Vector3.xAxis end
            if entry.active and entry.key == key then
              entry.position = entry.position:Lerp(position, 0.7)
              entry.normal = entry.normal:Lerp(sample.normal, 0.5).Unit
            else
              entry.position = position
              entry.normal = sample.normal
            end
            entry.tangent = tangent.Unit
            entry.lastSeen = now
            entry.age = math.min(entry.age + dt, 2)
            entry.intensity = math.max(entry.intensity * 0.75, signal)
            entry.anchor.CFrame = CFrame.lookAt(entry.position, entry.position + entry.tangent, entry.normal)
            entry.emitter.Enabled = true
            entry.emitter:Emit(math.clamp(math.floor(entry.intensity * 5), 1, 4))
            seen[key] = true
          end
        end
      end
    end
  end
  for _, entry in ipairs(self.pool) do
    if entry.active and not seen[entry.key] then
      entry.age += dt
      entry.intensity *= 0.82
      entry.position += entry.tangent * math.clamp(entry.intensity * 0.3, 0, 0.4)
      entry.anchor.CFrame = CFrame.lookAt(entry.position, entry.position + entry.tangent, entry.normal)
      if now - entry.lastSeen > 0.55 or entry.age > 2 then
        if entry.key then self.tracks[entry.key] = nil end
        entry.key = nil
        entry.active = false
        entry.emitter.Enabled = false
        entry.intensity = 0
      end
    end
  end
  self.lastSampleCount = sampleCount
  debug.profileend()
end

function SprayController:Start()
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

function SprayController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  for _, entry in ipairs(self.pool) do entry.anchor:Destroy() end
  table.clear(self.pool)
  table.clear(self.tracks)
end

return SprayController
