--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SprayController = {}
SprayController.__index = SprayController

local function hash(x: number, z: number, bucket: number): number
  local value = math.sin(x * 27.11 + z * 91.73 + bucket * 13.37) * 15731.743
  return value - math.floor(value)
end

function SprayController.new(waveField, runtime)
  return setmetatable({waveField = waveField, runtime = runtime, pool = {}, cap = 16, connection = nil, clock = 0}, SprayController)
end

function SprayController:_BuildPool()
  for _, part in ipairs(self.pool) do part:Destroy() end
  table.clear(self.pool)
  for index = 1, self.cap do
    local part = Instance.new("Part")
    part.Name = string.format("OceanSpray_%02d", index)
    part.Shape = Enum.PartType.Ball
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.CastShadow = false
    part.Material = Enum.Material.Neon
    part.Color = Color3.fromRGB(224, 250, 250)
    part.Size = Vector3.new(0.18, 0.18, 0.18)
    part.Transparency = 1
    part.Parent = self.runtime
    table.insert(self.pool, part)
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
    if self.clock < 0.08 then return end
    self.clock = 0
    local camera = Workspace.CurrentCamera
    if not camera then return end
    local now = self.waveField:GetSynchronizedTime()
    local center = camera.CFrame.Position
    local bucket = math.floor(now * 2)
    local used = 0
    for gz = -2, 2 do
      for gx = -2, 2 do
        if used >= #self.pool then break end
        local worldX = math.floor(center.X / 24 + 0.5) * 24 + gx * 24
        local worldZ = math.floor(center.Z / 24 + 0.5) * 24 + gz * 24
        local gate = hash(worldX, worldZ, bucket)
        if gate > 0.62 then
          local sample = self.waveField:SampleWorldXZ(Vector2.new(worldX, worldZ), now, {inverseIterations = 1, componentCap = 10, foamMultiplier = 1.8})
          if sample.foam > 0.08 and (sample.position - center).Magnitude < 220 then
            used += 1
            local spray = self.pool[used]
            local lift = 0.35 + sample.foam * 1.6
            local jitter = Vector3.new((hash(worldZ, worldX, bucket + 3) - 0.5) * 1.8, hash(worldX + 7, worldZ - 3, bucket + 5) * lift, (hash(worldX - 5, worldZ + 11, bucket + 7) - 0.5) * 1.8)
            spray.Position = sample.position + sample.normal * lift + jitter
            local size = 0.12 + sample.foam * 0.3
            spray.Size = Vector3.new(size, size, size)
            spray.Transparency = math.clamp(0.65 - sample.foam * 0.45, 0.12, 0.7)
          end
        end
      end
    end
    for index = used + 1, #self.pool do
      self.pool[index].Transparency = 1
    end
  end)
end

function SprayController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  for _, part in ipairs(self.pool) do part:Destroy() end
  table.clear(self.pool)
end

return SprayController
