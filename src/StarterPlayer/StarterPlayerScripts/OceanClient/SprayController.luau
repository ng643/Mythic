--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SprayController = {}
SprayController.__index = SprayController

local function hash(x: number, z: number): number
  local value = math.sin(x * 27.11 + z * 91.73) * 15731.743
  return value - math.floor(value)
end

local function sprayTexture(emitter: ParticleEmitter)
  emitter.Texture = "rbxassetid://138338217463878"
end

function SprayController.new(waveField, runtime)
  return setmetatable({waveField = waveField, runtime = runtime, pool = {}, cap = 16, connection = nil, clock = 0}, SprayController)
end

function SprayController:_BuildPool()
  for _, entry in ipairs(self.pool) do entry.anchor:Destroy() end
  table.clear(self.pool)
  for index = 1, self.cap do
    local anchor = Instance.new("Part")
    anchor.Name = string.format("StormSprayEmitter_%02d", index)
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
    emitter.Name = "StormSpray"
    emitter.Enabled = false
    emitter.Rate = 0
    emitter.Lifetime = NumberRange.new(0.25, 0.8)
    emitter.Speed = NumberRange.new(2.5, 8)
    emitter.Drag = 1.2
    emitter.SpreadAngle = Vector2.new(28, 28)
    emitter.Acceleration = Vector3.new(0, -10, 0)
    emitter.Rotation = NumberRange.new(0, 360)
    emitter.RotSpeed = NumberRange.new(-90, 90)
    emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.08), NumberSequenceKeypoint.new(0.2, 0.38), NumberSequenceKeypoint.new(1, 0.02)})
    emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.12), NumberSequenceKeypoint.new(0.6, 0.42), NumberSequenceKeypoint.new(1, 1)})
    emitter.Color = ColorSequence.new(Color3.fromRGB(218, 246, 246))
    emitter.LightEmission = 0.08
    sprayTexture(emitter)
    emitter.Parent = attachment
    table.insert(self.pool, {anchor = anchor, emitter = emitter, lastEmit = -math.huge})
  end
end

function SprayController:SetCap(cap: number)
  self.cap = math.clamp(math.floor(cap), 0, 64)
  self:_BuildPool()
end

function SprayController:Start()
  if self.connection then return end
  self:_BuildPool()
  self.connection = RunService.RenderStepped:Connect(function(dt)
    self.clock += dt
    if self.runtime:GetAttribute("OceanSprayEnabled") ~= true then
      for _, entry in ipairs(self.pool) do entry.emitter.Enabled = false end
      return
    end
    if self.clock < 0.1 then return end
    self.clock = 0
    local camera = Workspace.CurrentCamera
    if not camera then return end
    debug.profilebegin("Ocean/Spray")
    local now = self.waveField:GetSynchronizedTime()
    local center = camera.CFrame.Position
    local used = 0
    for gz = -2, 2 do
      for gx = -2, 2 do
        if used >= #self.pool then break end
        local worldX = math.floor(center.X / 24 + 0.5) * 24 + gx * 24
        local worldZ = math.floor(center.Z / 24 + 0.5) * 24 + gz * 24
        if hash(worldX, worldZ) > 0.12 then
          local sample = self.waveField:SampleWorldXZ(Vector2.new(worldX, worldZ), now, {inverseIterations = 2, componentCap = self.waveField:GetGameplayComponentCap(), foamMultiplier = 1.8})
          if sample.foam > 0.24 and (sample.position - center).Magnitude < 260 then
            used += 1
            local entry = self.pool[used]
            local tangent = Vector3.new(sample.velocity.X, 0, sample.velocity.Z)
            if tangent.Magnitude < 0.01 then tangent = Vector3.xAxis end
            entry.anchor.CFrame = CFrame.lookAt(sample.position + sample.normal * (0.2 + sample.foam), sample.position + tangent.Unit, sample.normal)
            entry.emitter.Enabled = true
            if now - entry.lastEmit > 0.18 then
              entry.emitter:Emit(math.clamp(math.floor(sample.foam * 4) + 1, 1, 8))
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

function SprayController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  for _, entry in ipairs(self.pool) do entry.anchor:Destroy() end
  table.clear(self.pool)
end

return SprayController
