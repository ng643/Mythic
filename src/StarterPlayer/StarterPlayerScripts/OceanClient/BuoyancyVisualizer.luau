--!strict

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local BuoyancyVisualizer = {}
BuoyancyVisualizer.__index = BuoyancyVisualizer

function BuoyancyVisualizer.new(waveField, runtime)
  return setmetatable({waveField = waveField, runtime = runtime, markers = {}, connection = nil}, BuoyancyVisualizer)
end

function BuoyancyVisualizer:_Clear()
  for _, marker in ipairs(self.markers) do marker:Destroy() end
  table.clear(self.markers)
end

function BuoyancyVisualizer:_Build()
  self:_Clear()
  for _, model in ipairs(CollectionService:GetTagged("OceanShip")) do
    if model:IsA("Model") then
      for _, descendant in ipairs(model:GetDescendants()) do
        if descendant:IsA("Attachment") and descendant:GetAttribute("OceanBuoyancyPoint") == true then
          local marker = Instance.new("Part")
          marker.Name = "BuoyancyDebug_" .. descendant.Name
          marker.Shape = Enum.PartType.Ball
          marker.Size = Vector3.new(0.45, 0.45, 0.45)
          marker.Anchored = true
          marker.CanCollide = false
          marker.CanTouch = false
          marker.CanQuery = false
          marker.CastShadow = false
          marker.Material = Enum.Material.Neon
          marker.Parent = self.runtime
          table.insert(self.markers, {marker = marker, point = descendant})
        end
      end
    end
  end
end

function BuoyancyVisualizer:Start()
  if not RunService:IsStudio() or self.connection then return end
  self:_Build()
  self.connection = RunService.RenderStepped:Connect(function()
    local enabled = self.runtime:GetAttribute("OceanDebugBuoyancy") == true
    local now = self.waveField:GetSynchronizedTime()
    for _, entry in ipairs(self.markers) do
      local point = entry.point
      local marker = entry.marker
      if not point.Parent or not enabled then
        marker.Transparency = 1
      else
        local sample = self.waveField:SampleForGameplayWorldXZ(Vector2.new(point.WorldPosition.X, point.WorldPosition.Z), now)
        local depth = sample.height - point.WorldPosition.Y
        marker.Transparency = 0.15
        marker.Color = depth > 0 and Color3.fromRGB(80, 255, 140) or Color3.fromRGB(255, 90, 70)
        marker.CFrame = CFrame.new(point.WorldPosition)
      end
    end
  end)
end

function BuoyancyVisualizer:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  self:_Clear()
end

return BuoyancyVisualizer
