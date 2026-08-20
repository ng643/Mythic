--!strict

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local ShorelineController = {}
ShorelineController.__index = ShorelineController

function ShorelineController.new(waveField, runtime)
  return setmetatable({waveField = waveField, runtime = runtime, emitters = {}, connection = nil}, ShorelineController)
end

function ShorelineController:_Clear()
  for _, entry in ipairs(self.emitters) do entry.anchor:Destroy() end
  table.clear(self.emitters)
end

function ShorelineController:_Build()
  self:_Clear()
  for _, shoreline in ipairs(CollectionService:GetTagged("OceanShoreline")) do
    if shoreline:IsA("Model") or shoreline:IsA("Folder") then
      for _, point in ipairs(shoreline:GetDescendants()) do
        if point:IsA("Attachment") and point:GetAttribute("OceanShorelinePoint") == true then
          local anchor = Instance.new("Part")
          anchor.Name = "ShoreFoamEmitter_" .. point.Name
          anchor.Anchored = true
          anchor.CanCollide = false
          anchor.CanTouch = false
          anchor.CanQuery = false
          anchor.CastShadow = false
          anchor.Transparency = 1
          anchor.Size = Vector3.new(0.1, 0.1, 0.1)
          anchor.Parent = self.runtime
          local attachment = Instance.new("Attachment")
          attachment.Parent = anchor
          local emitter = Instance.new("ParticleEmitter")
          emitter.Name = "ShoreFoam"
          emitter.Enabled = false
          emitter.Rate = 0
          emitter.Lifetime = NumberRange.new(1.2, 2.4)
          emitter.Speed = NumberRange.new(0.1, 0.7)
          emitter.SpreadAngle = Vector2.new(30, 30)
          emitter.Size = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(0.35, 1.1), NumberSequenceKeypoint.new(1, 0.1)})
          emitter.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(0.75, 0.5), NumberSequenceKeypoint.new(1, 1)})
          emitter.Color = ColorSequence.new(Color3.fromRGB(220, 245, 242))
          pcall(function() emitter.Texture = "rbxasset://textures/particles/sparkles_main.dds" end)
          emitter.Parent = attachment
          table.insert(self.emitters, {anchor = anchor, point = point, emitter = emitter, lastEmit = -math.huge})
        end
      end
    end
  end
end

function ShorelineController:Start()
  if self.connection then return end
  self:_Build()
  self.connection = RunService.RenderStepped:Connect(function()
    if #self.emitters == 0 then return end
    local now = self.waveField:GetSynchronizedTime()
    for _, entry in ipairs(self.emitters) do
      if not entry.point.Parent then
        entry.emitter.Enabled = false
      else
        local position = entry.point.WorldPosition
        local sample = self.waveField:SampleForGameplayWorldXZ(Vector2.new(position.X, position.Z), now)
        entry.anchor.CFrame = CFrame.new(sample.position + sample.normal * 0.06)
        entry.emitter.Enabled = true
        if now - entry.lastEmit > 0.45 and sample.foam > 0.08 then
          entry.emitter:Emit(math.clamp(math.floor(sample.foam * 3) + 1, 1, 5))
          entry.lastEmit = now
        end
      end
    end
  end)
end

function ShorelineController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  self:_Clear()
end

return ShorelineController
