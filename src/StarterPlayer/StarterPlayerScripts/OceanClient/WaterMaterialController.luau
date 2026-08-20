--!strict

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WaterMaterialController = {}
WaterMaterialController.__index = WaterMaterialController

local function waterMaterialVariant(): string
  local slot = game.ReplicatedStorage.Ocean.Assets.WaterAppearances:FindFirstChild("OceanWaterPBR")
  local value = slot and slot:GetAttribute("MaterialVariant")
  return type(value) == "string" and value or "OceanWater"
end

local function snapshot(state)
  return {
    waterColor = state.waterColor,
    horizonColor = state.horizonColor,
    roughness = state.roughness,
    windWorld = state.windWorld,
    stormIntensity = state.stormIntensity,
  }
end

local function blend(a, b, alpha: number)
  return {
    waterColor = a.waterColor:Lerp(b.waterColor, alpha),
    horizonColor = a.horizonColor:Lerp(b.horizonColor, alpha),
    roughness = a.roughness + (b.roughness - a.roughness) * alpha,
    windWorld = a.windWorld:Lerp(b.windWorld, alpha),
    stormIntensity = a.stormIntensity + (b.stormIntensity - a.stormIntensity) * alpha,
  }
end

function WaterMaterialController.new(runtime)
  return setmetatable({runtime = runtime, current = nil, from = nil, target = nil, transitionStart = 0, transitionDuration = 0, connection = nil}, WaterMaterialController)
end

function WaterMaterialController:_ApplyVisual(values)
  Workspace.GlobalWind = values.windWorld
  for _, child in ipairs(self.runtime:GetChildren()) do
    if child:IsA("MeshPart") then
      child.Material = Enum.Material.SmoothPlastic
      child.MaterialVariant = "OceanWater"
      child.Color = values.waterColor
      child.Reflectance = 0
    elseif child:IsA("BasePart") and (child.Name == "OceanFallbackSurface" or child.Name == "OceanFarPlane") then
      child.Material = Enum.Material.SmoothPlastic
      child.MaterialVariant = "OceanWater"
      child.Color = values.waterColor
      child.Reflectance = 0
    end
  end
  local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
  if atmosphere then
    local intensity = values.stormIntensity
    atmosphere.Color = values.horizonColor:Lerp(Color3.fromRGB(52, 66, 78), intensity * 0.45)
    atmosphere.Decay = values.horizonColor:Lerp(Color3.fromRGB(31, 42, 55), intensity * 0.35)
    atmosphere.Haze = math.clamp(0.3 + intensity * 1.5, 0.3, 2)
  end
end

function WaterMaterialController:Apply(state)
  local nextVisual = snapshot(state)
  if not self.current or state.bankBlendDuration <= 0 then
    self.current = nextVisual
    self.from = nil
    self.target = nil
    self:_ApplyVisual(self.current)
    return
  end
  self.from = self.current
  self.target = nextVisual
  self.transitionStart = Workspace:GetServerTimeNow()
  self.transitionDuration = math.max(state.bankBlendDuration, 0.1)
end

function WaterMaterialController:Start()
  if self.connection then return end
  self.connection = RunService.RenderStepped:Connect(function()
    if not self.target or not self.from then return end
    local alpha = math.clamp((Workspace:GetServerTimeNow() - self.transitionStart) / self.transitionDuration, 0, 1)
    self.current = blend(self.from, self.target, alpha)
    self:_ApplyVisual(self.current)
    if alpha >= 1 then
      self.from = nil
      self.target = nil
    end
  end)
end

function WaterMaterialController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  self.from = nil
  self.target = nil
end

return WaterMaterialController
