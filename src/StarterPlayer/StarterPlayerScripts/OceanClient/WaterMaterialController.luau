--!strict

local Lighting = game:GetService("Lighting")
local Workspace = game:GetService("Workspace")

local WaterMaterialController = {}
WaterMaterialController.__index = WaterMaterialController

function WaterMaterialController.new(runtime)
  return setmetatable({runtime = runtime, lastState = nil}, WaterMaterialController)
end

function WaterMaterialController:Apply(state)
  self.lastState = state
  Workspace.GlobalWind = state.windWorld
  for _, child in ipairs(self.runtime:GetChildren()) do
    if child:IsA("MeshPart") then
      child.Color = state.waterColor
      child.Reflectance = math.clamp(0.2 - state.roughness * 0.55, 0.02, 0.18)
    elseif child:IsA("BasePart") and (child.Name == "OceanFallbackSurface" or child.Name == "OceanFarPlane") then
      child.Color = state.waterColor
      child.Reflectance = math.clamp(0.15 - state.roughness * 0.45, 0.01, 0.12)
    end
  end
  local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
  if atmosphere then
    local intensity = state.stormIntensity
    atmosphere.Color = state.horizonColor:Lerp(Color3.fromRGB(52, 66, 78), intensity * 0.45)
    atmosphere.Decay = state.horizonColor:Lerp(Color3.fromRGB(31, 42, 55), intensity * 0.35)
    atmosphere.Haze = math.clamp(0.3 + intensity * 1.5, 0.3, 2)
  end
end

return WaterMaterialController
