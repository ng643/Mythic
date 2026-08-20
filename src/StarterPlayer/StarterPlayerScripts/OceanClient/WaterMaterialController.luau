--!strict

local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WaterMaterialController = {}
WaterMaterialController.__index = WaterMaterialController

local UV_SPACE = "MaterialVariant.StudsPerTile"

local function readManifest(): (string, string, string, number, Instance?)
  local ocean = ReplicatedStorage:FindFirstChild("Ocean")
  local assets = ocean and ocean:FindFirstChild("Assets")
  local appearances = assets and assets:FindFirstChild("WaterAppearances")
  local slot = appearances and appearances:FindFirstChild("OceanWaterPBR")
  local variantValue = slot and slot:GetAttribute("MaterialVariant")
  local versionValue = slot and (
    slot:GetAttribute("ManifestVersion")
      or slot:GetAttribute("MaterialVariantVersion")
      or slot:GetAttribute("MaterialVersion")
      or slot:GetAttribute("Version")
  )
  local sourceValue = slot and slot:GetAttribute("AuthoritativeSource")
  local tileValue = slot and slot:GetAttribute("StudsPerTile")
  local variantName = type(variantValue) == "string" and variantValue or ""
  local version = (type(versionValue) == "string" or type(versionValue) == "number") and tostring(versionValue) or ""
  local source = type(sourceValue) == "string" and sourceValue or ""
  local tileScale = type(tileValue) == "number" and tileValue > 0 and tileValue or 10
  return variantName, version, source, tileScale, slot
end

local function isWaterSurface(child: Instance): boolean
  return child:IsA("MeshPart")
    or (child:IsA("BasePart") and (
      child.Name == "OceanFallbackSurface"
        or string.sub(child.Name, 1, 13) == "OceanHorizon_"
    ))
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

local function normalizeAssetId(value: any): string
  local text = tostring(value)
  if string.match(text, "^%d+$") then return "rbxassetid://" .. text end
  return text
end

function WaterMaterialController.new(runtime)
  local self = setmetatable({
    runtime = runtime,
    current = nil,
    from = nil,
    target = nil,
    transitionStart = 0,
    transitionDuration = 0,
    connection = nil,
    childAddedConnection = nil,
    assetFetchFailedConnection = nil,
    applying = false,
    materialVariant = "",
    manifestVersion = "",
    manifestSource = "missing",
    manifestSlot = "",
    tileScale = 10,
    assetFetchStatus = "pending",
    assetFetchFailureCount = 0,
    failedAssetIds = {},
    warnedMissingVariant = false,
  }, WaterMaterialController)
  self:_RefreshManifest()
  return self
end

function WaterMaterialController:_RefreshManifest()
  local variant, version, source, tileScale, slot = readManifest()
  self.materialVariant = variant
  self.manifestVersion = version
  self.manifestSource = source ~= "" and source or (slot and slot:GetFullName() or "missing")
  self.manifestSlot = slot and slot:GetFullName() or "missing"
  self.tileScale = tileScale
end

function WaterMaterialController:_PublishManifest(values)
  local runtime = self.runtime
  runtime:SetAttribute("OceanMaterialPath", "MaterialVariant")
  runtime:SetAttribute("OceanMaterialVariant", self.materialVariant)
  runtime:SetAttribute("OceanMaterialManifestVersion", self.manifestVersion)
  runtime:SetAttribute("OceanMaterialManifestSource", self.manifestSource)
  runtime:SetAttribute("OceanMaterialManifestSlot", self.manifestSlot)
  runtime:SetAttribute("OceanMaterialUVSpace", UV_SPACE)
  runtime:SetAttribute("OceanMaterialWorldLockedUV", true)
  runtime:SetAttribute("OceanMaterialUVTileScale", self.tileScale)
  runtime:SetAttribute("OceanMaterialUVFormula", "MaterialVariant.StudsPerTile")
  runtime:SetAttribute("OceanMaterialUVConsumer", "MaterialService." .. self.materialVariant)
  runtime:SetAttribute("OceanMaterialTintProperty", "MeshPart.Color")
  runtime:SetAttribute("OceanMaterialAlphaMode", "Opaque")
  runtime:SetAttribute("OceanMaterialNearTransparency", 0)
  runtime:SetAttribute("OceanMaterialActiveRoughness", values.roughness)
  runtime:SetAttribute("OceanMaterialRoughness", values.roughness)
  runtime:SetAttribute("OceanMaterialRoughnessSource", "authoring-time MaterialVariant.RoughnessMap")
  runtime:SetAttribute("OceanMaterialAssetFetchStatus", self.assetFetchStatus)
  runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
  runtime:SetAttribute("OceanMaterialAuthoringValidation", "required; runtime cannot read PluginSecurity map properties")
  for _, role in ipairs({"ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap"}) do
    runtime:SetAttribute("OceanMaterialConfigured" .. role .. "Id", nil)
    runtime:SetAttribute("OceanMaterialActive" .. role .. "Id", nil)
  end
  local variant = self.materialVariant ~= "" and MaterialService:FindFirstChild(self.materialVariant) or nil
  local variantPresent = variant and variant:IsA("MaterialVariant")
  runtime:SetAttribute("OceanMaterialVariantPresent", variantPresent == true)
  runtime:SetAttribute("OceanMaterialMapBinding", variantPresent and "authoring-manifest-present" or "missing_variant")
  runtime:SetAttribute("OceanMaterialValidationStatus", variantPresent and (self.assetFetchStatus == "failed" and "error" or "authoring-manifest-present") or "error")
end

function WaterMaterialController:_HandleAssetFetchFailed(assetId)
  local normalized = normalizeAssetId(assetId)
  if self.failedAssetIds[normalized] then return end
  self.failedAssetIds[normalized] = true
  self.assetFetchFailureCount += 1
  self.assetFetchStatus = "failed"
  self.runtime:SetAttribute("OceanMaterialAssetFetchStatus", "failed")
  self.runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
  self.runtime:SetAttribute("OceanMaterialAssetFetchFailedId", normalized)
  self.runtime:SetAttribute("OceanMaterialValidationStatus", "error")
  warn("WaterMaterialController | MaterialVariant asset fetch failed | id=" .. normalized)
end

function WaterMaterialController:_ApplyChildVisual(child: Instance, values): (number, number)
  if not isWaterSurface(child) then return 0, 0 end
  local variant = self.materialVariant ~= "" and MaterialService:FindFirstChild(self.materialVariant) or nil
  local variantPresent = variant and variant:IsA("MaterialVariant")
  local materialVariant = variantPresent and self.materialVariant or ""
  local meshCount = child:IsA("MeshPart") and 1 or 0
  local fallbackCount = child.Name == "OceanFallbackSurface" and 1 or 0
  child.Material = Enum.Material.SmoothPlastic
  child.MaterialVariant = materialVariant
  child.Color = string.sub(child.Name, 1, 13) == "OceanHorizon_" and values.horizonColor or values.waterColor
  child.Transparency = 0
  child.Reflectance = 0
  local surfaceAppearance = child:FindFirstChild("OceanSurfaceAppearance")
  if surfaceAppearance then surfaceAppearance:Destroy() end
  child:SetAttribute("OceanMaterialPath", "MaterialVariant")
  child:SetAttribute("OceanMaterialVariant", self.materialVariant)
  child:SetAttribute("OceanMaterialUVSpace", UV_SPACE)
  child:SetAttribute("OceanMaterialWorldLockedUV", true)
  child:SetAttribute("OceanMaterialUVTileScale", self.tileScale)
  if not variantPresent and not self.warnedMissingVariant then
    self.warnedMissingVariant = true
    warn("WaterMaterialController | configured MaterialVariant is missing: " .. self.materialVariant)
  end
  return meshCount, fallbackCount
end

function WaterMaterialController:_ApplyVisual(values, reason: string?)
  if self.applying then return end
  self.applying = true
  local ok, errorMessage = xpcall(function()
    self:_RefreshManifest()
    self:_PublishManifest(values)
    Workspace.GlobalWind = values.windWorld
    local meshCount = 0
    local fallbackCount = 0
    for _, child in ipairs(self.runtime:GetChildren()) do
      local meshDelta, fallbackDelta = self:_ApplyChildVisual(child, values)
      meshCount += meshDelta
      fallbackCount += fallbackDelta
    end
    local variant = self.materialVariant ~= "" and MaterialService:FindFirstChild(self.materialVariant) or nil
    local variantPresent = variant and variant:IsA("MaterialVariant")
    if variantPresent and self.assetFetchStatus == "pending" then self.assetFetchStatus = "ok" end
    self.runtime:SetAttribute("OceanMaterialMeshPartCount", meshCount)
    self.runtime:SetAttribute("OceanMaterialFallbackCount", fallbackCount)
    self.runtime:SetAttribute("OceanMaterialSurfaceAppearanceCount", 0)
    self.runtime:SetAttribute("OceanMaterialAssetFetchStatus", self.assetFetchStatus)
    self.runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
    self.runtime:SetAttribute("OceanMaterialValidationStatus", variantPresent and (self.assetFetchStatus == "failed" and "error" or "authoring-manifest-present") or "error")
    self.runtime:SetAttribute("OceanMaterialLastApplyReason", reason or "state")
    local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
    if atmosphere then
      local intensity = values.stormIntensity
      atmosphere.Color = values.horizonColor:Lerp(Color3.fromRGB(52, 66, 78), intensity * 0.45)
      atmosphere.Decay = values.horizonColor:Lerp(Color3.fromRGB(31, 42, 55), intensity * 0.35)
      atmosphere.Haze = math.clamp(0.3 + intensity * 1.5, 0.3, 2)
    end
  end, debug.traceback)
  self.applying = false
  if not ok then
    self.runtime:SetAttribute("OceanMaterialValidationStatus", "error")
    self.runtime:SetAttribute("OceanMaterialApplyError", tostring(errorMessage))
    warn("WaterMaterialController | apply failed | " .. tostring(errorMessage))
  end
end

function WaterMaterialController:Apply(state)
  local nextVisual = snapshot(state)
  local blendDuration = state.bankBlendDuration or 0
  if not self.current or blendDuration <= 0 then
    self.current = nextVisual
    self.from = nil
    self.target = nil
    self:_ApplyVisual(self.current, "state")
    return
  end
  self.from = self.current
  self.target = nextVisual
  self.transitionStart = state.bankBlendStart or Workspace:GetServerTimeNow()
  self.transitionDuration = math.max(blendDuration, 0.1)
end

function WaterMaterialController:Start()
  if self.connection then return end
  self.assetFetchFailedConnection = ContentProvider.AssetFetchFailed:Connect(function(assetId)
    self:_HandleAssetFetchFailed(assetId)
  end)
  self.childAddedConnection = self.runtime.ChildAdded:Connect(function(child)
    if self.current then self:_ApplyChildVisual(child, self.current) end
  end)
  self.connection = RunService.RenderStepped:Connect(function()
    if not self.target or not self.from then return end
    local alpha = math.clamp((Workspace:GetServerTimeNow() - self.transitionStart) / self.transitionDuration, 0, 1)
    self.current = blend(self.from, self.target, alpha)
    self:_ApplyVisual(self.current, "state transition")
    if alpha >= 1 then self.from = nil self.target = nil end
  end)
  if self.current then self:_ApplyVisual(self.current, "start") end
end

function WaterMaterialController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  if self.childAddedConnection then self.childAddedConnection:Disconnect() self.childAddedConnection = nil end
  if self.assetFetchFailedConnection then self.assetFetchFailedConnection:Disconnect() self.assetFetchFailedConnection = nil end
  self.from = nil
  self.target = nil
end

return WaterMaterialController
