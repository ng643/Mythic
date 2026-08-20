--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FoamController = {}
FoamController.__index = FoamController

local function hash(x: number, z: number): number
  local value = math.sin(x * 12.9898 + z * 78.233) * 43758.5453
  return value - math.floor(value)
end

local function foamTexture(emitter: ParticleEmitter)
  pcall(function()
    emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds"
  end)
end

function FoamController.new(waveField, runtime)
  return setmetatable({waveField = waveField, runtime = runtime, pool = {}, cap = 24, connection = nil, clock = 0}, FoamController)
end

function FoamController:_BuildPool()
  for _, entry in ipairs(self.pool) do entry.anchor:Destroy() end
  table.clear(self.pool)
  for index = 1, self.cap do
    local anchor = Instance.new("Part")
    anchor.Name = string.format("CrestEmitter_%02d", index)
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
    emitter.Name = "CrestFoam"
    emitter.Enabled = false
    emitter.Rate = 0
    emitter.Lifetime = NumberRange.new(0.8, 1.8)
    emitter.Speed = NumberRange.new(0.15, 1.4)
    emitter.Drag = 2.5
    emitter.SpreadAngle = Vector2.new(22, 22)
    emitter.Acceleration = Vector3.new(0, 1.2, 0)
    emitter.Rotation = NumberRange.new(0, 360)
    emitter.RotSpeed = NumberRange.new(-35, 35)
    emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.25), NumberSequenceKeypoint.new(0.18, 0.9), NumberSequenceKeypoint.new(1, 0.05)})
    emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.18), NumberSequenceKeypoint.new(0.7, 0.35), NumberSequenceKeypoint.new(1, 1)})
    emitter.Color = ColorSequence.new(Color3.fromRGB(224, 246, 244))
    emitter.LightEmission = 0.05
    foamTexture(emitter)
    emitter.Parent = attachment
    table.insert(self.pool, {anchor = anchor, emitter = emitter, lastEmit = -math.huge})
  end
end

function FoamController:SetCap(cap: number)
  self.cap = math.clamp(math.floor(cap), 0, 128)
  self:_BuildPool()
end

function FoamController:Start()
  if self.connection then return end
  self:_BuildPool()
  self.connection = RunService.RenderStepped:Connect(function(dt)
    self.clock += dt
    if self.runtime:GetAttribute("OceanDebugFoam") == false then
      for _, entry in ipairs(self.pool) do entry.emitter.Enabled = false end
      return
    end
    if self.clock < 0.1 then return end
    self.clock = 0
    local camera = Workspace.CurrentCamera
    if not camera then return end
    debug.profilebegin("Ocean/Foam")
    local now = self.waveField:GetSynchronizedTime()
    local center = camera.CFrame.Position
    local used = 0
    for gz = -3, 3 do
      for gx = -3, 3 do
        if used >= #self.pool then break end
        local worldX = math.floor(center.X / 18 + 0.5) * 18 + gx * 18
        local worldZ = math.floor(center.Z / 18 + 0.5) * 18 + gz * 18
        if hash(worldX, worldZ) > 0.18 then
          local sample = self.waveField:SampleWorldXZ(Vector2.new(worldX, worldZ), now, {inverseIterations = 2, componentCap = 12, foamMultiplier = 1.8})
          if sample.foam > 0.16 and (sample.position - center).Magnitude < 260 then
            used += 1
            local entry = self.pool[used]
            local tangent = Vector3.new(sample.velocity.X, 0, sample.velocity.Z)
            if tangent.Magnitude < 0.01 then tangent = Vector3.xAxis end
            entry.anchor.CFrame = CFrame.lookAt(sample.position + sample.normal * 0.08, sample.position + sample.normal * 0.08 + tangent.Unit, sample.normal)
            entry.emitter.Enabled = true
            if now - entry.lastEmit > 0.32 then
              entry.emitter:Emit(math.clamp(math.floor(sample.foam * 3) + 1, 1, 5))
              entry.lastEmit = now
            end
          end
        end
      end
    end
    for index = used + 1, #self.pool do self.pool[index].emitter.Enabled = false end
    debug.profileend()
  end)
end

function FoamController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  for _, entry in ipairs(self.pool) do entry.anchor:Destroy() end
  table.clear(self.pool)
end

return FoamController
