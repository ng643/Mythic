--!strict

local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local FoamController = {}
FoamController.__index = FoamController

local function hash(x: number, z: number, bucket: number): number
  local value = math.sin(x * 12.9898 + z * 78.233 + bucket * 37.719) * 43758.5453
  return value - math.floor(value)
end

function FoamController.new(waveField, runtime)
  return setmetatable({waveField = waveField, runtime = runtime, pool = {}, cap = 24, connection = nil, clock = 0}, FoamController)
end

function FoamController:_BuildPool()
  for _, part in ipairs(self.pool) do part:Destroy() end
  table.clear(self.pool)
  for index = 1, self.cap do
    local part = Instance.new("Part")
    part.Name = string.format("CrestCard_%02d", index)
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.CastShadow = false
    part.Material = Enum.Material.Neon
    part.Color = Color3.fromRGB(220, 244, 244)
    part.Size = Vector3.new(5, 0.035, 1.4)
    part.Transparency = 1
    part.Parent = self.runtime
    table.insert(self.pool, part)
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
    if self.clock < 0.12 then return end
    self.clock = 0
    local camera = Workspace.CurrentCamera
    if not camera then return end
    local now = self.waveField:GetSynchronizedTime()
    local used = 0
    local bucket = math.floor(now * 1.5)
    local center = camera.CFrame.Position
    for gz = -3, 3 do
      for gx = -3, 3 do
        if used >= #self.pool then break end
        local worldX = math.floor(center.X / 18 + 0.5) * 18 + gx * 18
        local worldZ = math.floor(center.Z / 18 + 0.5) * 18 + gz * 18
        if hash(worldX, worldZ, bucket) > 0.34 then
          local sample = self.waveField:SampleWorldXZ(Vector2.new(worldX, worldZ), now, {inverseIterations = 1, componentCap = 10, foamMultiplier = 1.8})
          if sample.foam > 0.14 and (Vector3.new(worldX, sample.height, worldZ) - center).Magnitude < 240 then
            used += 1
            local card = self.pool[used]
            local angle = hash(worldZ, worldX, bucket + 3) * math.pi
            card.CFrame = CFrame.new(sample.position + sample.normal * 0.06) * CFrame.Angles(0, angle, 0)
            card.Size = Vector3.new(3 + sample.foam * 6, 0.035, 0.8 + sample.foam * 1.8)
            card.Transparency = math.clamp(0.58 - sample.foam * 0.45, 0.08, 0.65)
          end
        end
      end
    end
    for index = used + 1, #self.pool do
      self.pool[index].Transparency = 1
    end
  end)
end

function FoamController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  for _, part in ipairs(self.pool) do part:Destroy() end
  table.clear(self.pool)
end

return FoamController
