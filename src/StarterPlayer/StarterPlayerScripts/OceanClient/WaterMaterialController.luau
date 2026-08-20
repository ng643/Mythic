--!strict

local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local MaterialService = game:GetService("MaterialService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WaterMaterialController = {}
WaterMaterialController.__index = WaterMaterialController

local MATERIAL_VARIANT = "OceanWater"
local UV_SPACE = "MaterialVariant.StudsPerTile"
local ASSET_ROLES = {"ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap"}
local FALLBACK_ASSET_IDS = {
  ColorMap = "rbxassetid://128922037556159",
  NormalMap = "rbxassetid://101286961773967",
  RoughnessMap = "rbxassetid://111100454366205",
  MetalnessMap = "rbxassetid://126230944196062",
}

local function normalizeAssetId(value: any): string
  local text = tostring(value)
  if string.match(text, "^%d+$") then return "rbxassetid://" .. text end
  return text
end

local function readManifest(): ({[string]: string}, Instance?)
  local ocean = ReplicatedStorage:FindFirstChild("Ocean")
  local assets = ocean and ocean:FindFirstChild("Assets")
  local appearances = assets and assets:FindFirstChild("WaterAppearances")
  local slot = appearances and appearances:FindFirstChild("OceanWaterPBR")
  local manifest = {}
  for _, role in ipairs(ASSET_ROLES) do
    local value = slot and slot:GetAttribute(role)
    manifest[role] = type(value) == "string" and value ~= "" and value or FALLBACK_ASSET_IDS[role]
  end
  return manifest, slot
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

local function readVariantAsset(variant: MaterialVariant, role: string): string
  local ok, value = pcall(function()
    if role == "ColorMap" then return variant.ColorMap end
    if role == "NormalMap" then return variant.NormalMap end
    if role == "RoughnessMap" then return variant.RoughnessMap end
    return variant.MetalnessMap
  end)
  if not ok or value == nil then return "" end
  return tostring(value)
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
    qualityConnection = nil,
    childAddedConnection = nil,
    assetFetchFailedConnection = nil,
    applying = false,
    manifest = {},
    manifestSource = "missing",
    assetFetchStatus = "pending",
    assetFetchFailureCount = 0,
    failedAssetIds = {},
    warnedMissingVariant = false,
  }, WaterMaterialController)
  self:_RefreshManifest()
  return self
end

function WaterMaterialController:_RefreshManifest()
  local manifest, slot = readManifest()
  self.manifest = manifest
  self.manifestSource = slot and slot:GetFullName() or "missing"
end

function WaterMaterialController:_PublishManifest(values)
  local runtime = self.runtime
  runtime:SetAttribute("OceanMaterialPath", "MaterialVariant")
  runtime:SetAttribute("OceanMaterialVariant", MATERIAL_VARIANT)
  runtime:SetAttribute("OceanMaterialUVSpace", UV_SPACE)
  runtime:SetAttribute("OceanMaterialWorldLockedUV", true)
  runtime:SetAttribute("OceanMaterialUVTileScale", 10)
  runtime:SetAttribute("OceanMaterialUVFormula", "MaterialVariant.StudsPerTile")
  runtime:SetAttribute("OceanMaterialUVConsumer", "MaterialService.OceanWater")
  runtime:SetAttribute("OceanMaterialTintProperty", "MeshPart.Color")
  runtime:SetAttribute("OceanMaterialAlphaMode", "Opaque")
  runtime:SetAttribute("OceanMaterialNearTransparency", 0)
  runtime:SetAttribute("OceanMaterialActiveRoughness", values.roughness)
  runtime:SetAttribute("OceanMaterialRoughness", values.roughness)
  runtime:SetAttribute("OceanMaterialRoughnessSource", "MaterialVariant.RoughnessMap")
  runtime:SetAttribute("OceanMaterialManifestSource", self.manifestSource)
  runtime:SetAttribute("OceanMaterialAssetFetchStatus", self.assetFetchStatus)
  runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
  for _, role in ipairs(ASSET_ROLES) do
    runtime:SetAttribute("OceanMaterialConfigured" .. role .. "Id", self.manifest[role])
  end
  local variant = MaterialService:FindFirstChild(MATERIAL_VARIANT)
  local variantOk = variant and variant:IsA("MaterialVariant")
  runtime:SetAttribute("OceanMaterialVariantPresent", variantOk == true)
  if variantOk then
    local allBound = true
    for _, role in ipairs(ASSET_ROLES) do
      local activeId = readVariantAsset(variant :: MaterialVariant, role)
      if activeId == "" then allBound = false end
      runtime:SetAttribute("OceanMaterialActive" .. role .. "Id", activeId)
    end
    runtime:SetAttribute("OceanMaterialMapBinding", allBound and "active" or "missing")
  else
    runtime:SetAttribute("OceanMaterialMapBinding", "missing_variant")
  end
end

function WaterMaterialController:_HandleAssetFetchFailed(assetId)
  local normalized = normalizeAssetId(assetId)
  for _, role in ipairs(ASSET_ROLES) do
    if normalizeAssetId(self.manifest[role]) == normalized and not self.failedAssetIds[normalized] then
      self.failedAssetIds[normalized] = true
      self.assetFetchFailureCount += 1
      self.assetFetchStatus = "failed"
      self.runtime:SetAttribute("OceanMaterialAssetFetchStatus", "failed")
      self.runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
      self.runtime:SetAttribute("OceanMaterialAssetFetchFailedId", normalized)
      self.runtime:SetAttribute("OceanMaterialAssetFetchFailedMap", role)
      self.runtime:SetAttribute("OceanMaterialValidationStatus", "error")
      warn(string.format("WaterMaterialController | MaterialVariant asset fetch failed | map=%s id=%s", role, normalized))
      return
    end
  end
end

function WaterMaterialController:_ApplyVisual(values, reason: string?)
  if self.applying then return end
  self.applying = true
  self:_RefreshManifest()
  self:_PublishManifest(values)
  Workspace.GlobalWind = values.windWorld
  local variant = MaterialService:FindFirstChild(MATERIAL_VARIANT)
  local variantPresent = variant and variant:IsA("MaterialVariant")
  local meshCount = 0
  local fallbackCount = 0
  for _, child in ipairs(self.runtime:GetChildren()) do
    if child:IsA("MeshPart") then
      meshCount += 1
      child.Material = Enum.Material.SmoothPlastic
      child.MaterialVariant = variantPresent and MATERIAL_VARIANT or ""
      child.Color = values.waterColor
      child.Transparency = 0
      child.Reflectance = 0
      local surfaceAppearance = child:FindFirstChild("OceanSurfaceAppearance")
      if surfaceAppearance then surfaceAppearance:Destroy() end
      child:SetAttribute("OceanMaterialPath", "MaterialVariant")
      child:SetAttribute("OceanMaterialUVSpace", UV_SPACE)
      child:SetAttribute("OceanMaterialWorldLockedUV", true)
    elseif child:IsA("BasePart") and string.sub(child.Name, 1, 13) == "OceanHorizon_" then
      child.Material = Enum.Material.SmoothPlastic
      child.MaterialVariant = variantPresent and MATERIAL_VARIANT or ""
      child.Color = values.horizonColor
      child.Transparency = 0
      child.Reflectance = 0
    elseif child:IsA("BasePart") and child.Name == "OceanFallbackSurface" then
      fallbackCount += 1
      child.Material = Enum.Material.SmoothPlastic
      child.MaterialVariant = variantPresent and MATERIAL_VARIANT or ""
      child.Color = values.waterColor
      child.Transparency = 0
      child.Reflectance = 0
    end
  end
  if not variantPresent then
    self.runtime:SetAttribute("OceanMaterialValidationStatus", "error")
    if not self.warnedMissingVariant then
      self.warnedMissingVariant = true
      warn("WaterMaterialController | MaterialService.OceanWater is missing")
    end
  elseif self.assetFetchStatus == "pending" then
    self.assetFetchStatus = "ok"
  end
  self.runtime:SetAttribute("OceanMaterialMeshPartCount", meshCount)
  self.runtime:SetAttribute("OceanMaterialFallbackCount", fallbackCount)
  self.runtime:SetAttribute("OceanMaterialSurfaceAppearanceCount", 0)
  self.runtime:SetAttribute("OceanMaterialAssetFetchStatus", self.assetFetchStatus)
  self.runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
  self.runtime:SetAttribute("OceanMaterialValidationStatus", variantPresent and (self.assetFetchStatus == "failed" and "error" or "active") or "error")
  self.runtime:SetAttribute("OceanMaterialLastApplyReason", reason or "state")
  local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
  if atmosphere then
    local intensity = values.stormIntensity
    atmosphere.Color = values.horizonColor:Lerp(Color3.fromRGB(52, 66, 78), intensity * 0.45)
    atmosphere.Decay = values.horizonColor:Lerp(Color3.fromRGB(31, 42, 55), intensity * 0.35)
    atmosphere.Haze = math.clamp(0.3 + intensity * 1.5, 0.3, 2)
  end
  self.applying = false
end

function WaterMaterialController:_ReapplyCurrent(reason: string)
  if self.current then self:_ApplyVisual(self.current, reason) end
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
  self.qualityConnection = self.runtime:GetAttributeChangedSignal("OceanQuality"):Connect(function()
    self:_ReapplyCurrent("renderer quality rebuild")
  end)
  self.childAddedConnection = self.runtime.ChildAdded:Connect(function(child)
    if child:IsA("MeshPart") or (child:IsA("BasePart") and (child.Name == "OceanFallbackSurface" or string.sub(child.Name, 1, 13) == "OceanHorizon_")) then
      self:_ReapplyCurrent("renderer quality rebuild")
    end
  end)
  self.connection = RunService.RenderStepped:Connect(function()
    if not self.target or not self.from then return end
    local alpha = math.clamp((Workspace:GetServerTimeNow() - self.transitionStart) / self.transitionDuration, 0, 1)
    self.current = blend(self.from, self.target, alpha)
    self:_ApplyVisual(self.current, "state transition")
    if alpha >= 1 then self.from = nil self.target = nil end
  end)
  self:_ReapplyCurrent("start")
end

function WaterMaterialController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  if self.qualityConnection then self.qualityConnection:Disconnect() self.qualityConnection = nil end
  if self.childAddedConnection then self.childAddedConnection:Disconnect() self.childAddedConnection = nil end
  if self.assetFetchFailedConnection then self.assetFetchFailedConnection:Disconnect() self.assetFetchFailedConnection = nil end
  self.from = nil
  self.target = nil
end

return WaterMaterialController
