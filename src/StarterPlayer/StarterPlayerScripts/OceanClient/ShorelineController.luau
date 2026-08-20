--!strict

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local ShorelineController = {}
ShorelineController.__index = ShorelineController

function ShorelineController.new(waveField, runtime, scheduler)
  return setmetatable({waveField = waveField, runtime = runtime, scheduler = scheduler, emitters = {}, connection = nil, accumulator = 0}, ShorelineController)
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
          emitter.Texture = "rbxassetid://140229416139720"
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
  self.connection = RunService.RenderStepped:Connect(function(dt)
    if self.runtime:GetAttribute("OceanShorelineEnabled") ~= true then
      for _, entry in ipairs(self.emitters) do entry.emitter.Enabled = false end
      return
    end
    if #self.emitters == 0 then return end
    self.accumulator += dt
    if self.accumulator < 0.125 then return end
    self.accumulator = 0
    local camera = Workspace.CurrentCamera
    if not camera then return end
    debug.profilebegin("Ocean/Shoreline")
    local now = self.waveField:GetSynchronizedTime()
    for _, entry in ipairs(self.emitters) do
      if not entry.point.Parent then
        entry.emitter.Enabled = false
      else
        local position = entry.point.WorldPosition
        if (position - camera.CFrame.Position).Magnitude > 320 then
          entry.emitter.Enabled = false
        else
          local sample = self.scheduler
            and self.scheduler:Sample(Vector2.new(position.X, position.Z), now, {inverseIterations = 3, includeEvents = false})
            or self.waveField:SampleForGameplayWorldXZ(Vector2.new(position.X, position.Z), now, {inverseIterations = 3, includeEvents = false})
          entry.anchor.CFrame = CFrame.lookAt(sample.position + sample.normal * 0.06, sample.position + sample.normal * 0.06 + sample.normal, sample.normal)
          entry.emitter.Enabled = true
          if now - entry.lastEmit > 0.45 and sample.foam > 0.08 then
            entry.emitter:Emit(math.clamp(math.floor(sample.foam * 3) + 1, 1, 5))
            entry.lastEmit = now
          end
        end
      end
    end
    debug.profileend()
  end)
end

function ShorelineController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  self:_Clear()
end

return ShorelineController
