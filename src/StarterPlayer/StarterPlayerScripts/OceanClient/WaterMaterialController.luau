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
local WATER_SURFACE_COLOR = Color3.fromRGB(7, 64, 91)

local function normalizeAssetId(value: any): string
  local text = tostring(value)
  if string.match(text, "^%d+$") then return "rbxassetid://" .. text end
  return text
end

local function readManifest()
  local ocean = ReplicatedStorage:FindFirstChild("Ocean")
  local assets = ocean and ocean:FindFirstChild("Assets")
  local appearances = assets and assets:FindFirstChild("WaterAppearances")
  local slot = appearances and appearances:FindFirstChild("OceanWaterPBR")
  local variantValue = slot and slot:GetAttribute("MaterialVariant")
  local versionValue = slot and (slot:GetAttribute("ManifestVersion") or slot:GetAttribute("Version"))
  local sourceValue = slot and slot:GetAttribute("AuthoritativeSource")
  local tileValue = slot and slot:GetAttribute("StudsPerTile")
  local maps = {}
  for _, role in ipairs({"ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap"}) do
    maps[role] = normalizeAssetId(slot and slot:GetAttribute(role) or "")
  end
  return {
    variant = type(variantValue) == "string" and variantValue or "OceanWater",
    version = versionValue ~= nil and tostring(versionValue) or "",
    source = type(sourceValue) == "string" and sourceValue or "",
    tileScale = type(tileValue) == "number" and tileValue > 0 and tileValue or 96,
    slot = slot,
    maps = maps,
  }
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
    surfaces = {},
    applying = false,
    materialVariant = "OceanWater",
    manifestVersion = "",
    manifestSource = "missing",
    manifestSlot = "missing",
    tileScale = 96,
    maps = {},
    assetFetchStatus = "pending",
    assetFetchFailureCount = 0,
    failedAssetIds = {},
    lastTint = nil,
    lastWind = nil,
    lastAtmosphere = nil,
    transitionAccumulator = 0,
    warnedMissingVariant = false,
  }, WaterMaterialController)
  self:_RefreshManifest()
  return self
end

function WaterMaterialController:_RefreshManifest()
  local manifest = readManifest()
  self.materialVariant = manifest.variant
  self.manifestVersion = manifest.version
  self.manifestSource = manifest.source ~= "" and manifest.source or (manifest.slot and manifest.slot:GetFullName() or "missing")
  self.manifestSlot = manifest.slot and manifest.slot:GetFullName() or "missing"
  self.tileScale = manifest.tileScale
  self.maps = manifest.maps
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
  runtime:SetAttribute("OceanMaterialTintProperty", "MeshPart.Color")
  runtime:SetAttribute("OceanMaterialAlphaMode", "Opaque")
  runtime:SetAttribute("OceanMaterialActiveRoughness", values.roughness)
  runtime:SetAttribute("OceanMaterialRoughnessSource", "authoring-time RoughnessMap")
  runtime:SetAttribute("OceanMaterialAssetFetchStatus", self.assetFetchStatus)
  runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
  runtime:SetAttribute("OceanMaterialAuthoringValidation", "pixel-inspected; experience-owned manifest")
  for role, assetId in pairs(self.maps) do
    runtime:SetAttribute("OceanMaterialConfigured" .. role .. "Id", assetId)
    runtime:SetAttribute("OceanMaterialActive" .. role .. "Id", assetId)
  end
  local variant = MaterialService:FindFirstChild(self.materialVariant)
  local variantPresent = variant and variant:IsA("MaterialVariant")
  runtime:SetAttribute("OceanMaterialVariantPresent", variantPresent == true)
  runtime:SetAttribute("OceanMaterialMapBinding", variantPresent and "surfaceappearance-manifest" or "missing_variant")
  runtime:SetAttribute("OceanMaterialValidationStatus", variantPresent and "pixel-inspected" or "error")
end

function WaterMaterialController:_HandleAssetFetchFailed(assetId)
  local normalized = normalizeAssetId(assetId)
  local isKnown = false
  for _, configured in pairs(self.maps) do
    if configured == normalized then isKnown = true break end
  end
  if not isKnown or self.failedAssetIds[normalized] then return end
  self.failedAssetIds[normalized] = true
  self.assetFetchFailureCount += 1
  self.assetFetchStatus = "failed"
  self.runtime:SetAttribute("OceanMaterialAssetFetchStatus", "failed")
  self.runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
  self.runtime:SetAttribute("OceanMaterialAssetFetchFailedId", normalized)
  self.runtime:SetAttribute("OceanMaterialValidationStatus", "error")
  warn("WaterMaterialController | configured ocean asset fetch failed | id=" .. normalized)
end

function WaterMaterialController:_ApplySurfaceAppearance(child: MeshPart)
  local surface = child:FindFirstChild("OceanSurfaceAppearance")
  if not surface or not surface:IsA("SurfaceAppearance") then
    surface = Instance.new("SurfaceAppearance")
    surface.Name = "OceanSurfaceAppearance"
    surface.Parent = child
  end
  pcall(function()
    surface.AlphaMode = Enum.AlphaMode.Opaque
    surface.ColorMap = self.maps.ColorMap
    surface.NormalMap = self.maps.NormalMap
    surface.RoughnessMap = self.maps.RoughnessMap
    surface.MetalnessMap = self.maps.MetalnessMap
  end)
end

function WaterMaterialController:_RegisterSurface(child: Instance)
  if not isWaterSurface(child) then return end
  self.surfaces[child] = true
  local variant = MaterialService:FindFirstChild(self.materialVariant)
  local variantPresent = variant and variant:IsA("MaterialVariant")
  child.Material = Enum.Material.SmoothPlastic
  child.MaterialVariant = variantPresent and self.materialVariant or ""
  child.Color = WATER_SURFACE_COLOR
  child.Transparency = 0
  child.Reflectance = 0
  -- Keep MeshPart.Color authoritative when the neutral ColorMap is empty.
  if not variantPresent and not self.warnedMissingVariant then
    self.warnedMissingVariant = true
    warn("WaterMaterialController | configured MaterialVariant is missing: " .. self.materialVariant)
  end
end

function WaterMaterialController:_UnregisterSurface(child: Instance)
  self.surfaces[child] = nil
end

function WaterMaterialController:_ApplyTint(values)
  local changed = self.lastTint == nil
    or self.lastTint.waterColor ~= values.waterColor
    or self.lastTint.stormIntensity ~= values.stormIntensity
  if changed then
    for child in pairs(self.surfaces) do
      if child.Parent then
        child.Color = values.waterColor
      else
        self.surfaces[child] = nil
      end
    end
    self.lastTint = values
  end
  if not self.lastWind or self.lastWind ~= values.windWorld then
    Workspace.GlobalWind = values.windWorld
    self.lastWind = values.windWorld
  end
  local atmosphere = Lighting:FindFirstChildOfClass("Atmosphere")
  if atmosphere then
    local intensity = math.floor(values.stormIntensity * 40 + 0.5) / 40
    local atmosphereKey = tostring(intensity) .. ":" .. tostring(values.horizonColor)
    if atmosphereKey ~= self.lastAtmosphere then
      self.lastAtmosphere = atmosphereKey
      atmosphere.Color = values.horizonColor:Lerp(Color3.fromRGB(52, 66, 78), intensity * 0.45)
      atmosphere.Decay = values.horizonColor:Lerp(Color3.fromRGB(31, 42, 55), intensity * 0.35)
      atmosphere.Haze = math.clamp(0.3 + intensity * 1.5, 0.3, 2)
    end
  end
end

function WaterMaterialController:_ApplyVisual(values, reason: string?)
  if self.applying then return end
  self.applying = true
  local ok, errorMessage = xpcall(function()
    self:_RefreshManifest()
    self:_PublishManifest(values)
    for _, child in ipairs(self.runtime:GetChildren()) do
      self:_RegisterSurface(child)
    end
    self:_ApplyTint(values)
    self.runtime:SetAttribute("OceanMaterialSurfaceCount", 0)
    self.runtime:SetAttribute("OceanMaterialTrackedSurfaceCount", 0)
    self.runtime:SetAttribute("OceanMaterialAssetFetchStatus", self.assetFetchStatus)
    self.runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
    self.runtime:SetAttribute("OceanMaterialLastApplyReason", reason or "state")
    local count = 0
    for child in pairs(self.surfaces) do if child.Parent then count += 1 end end
    self.runtime:SetAttribute("OceanMaterialTrackedSurfaceCount", count)
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
    self:_RegisterSurface(child)
    if self.current then self:_ApplyTint(self.current) end
  end)
  self.connection = RunService.RenderStepped:Connect(function(dt)
    if not self.target or not self.from then return end
    self.transitionAccumulator += dt
    if self.transitionAccumulator < 0.1 then return end
    self.transitionAccumulator = 0
    local alpha = math.clamp((Workspace:GetServerTimeNow() - self.transitionStart) / self.transitionDuration, 0, 1)
    self.current = blend(self.from, self.target, alpha)
    self:_ApplyTint(self.current)
    self.runtime:SetAttribute("OceanMaterialActiveRoughness", self.current.roughness)
    if alpha >= 1 then self.from = nil self.target = nil end
  end)
  if self.current then self:_ApplyVisual(self.current, "start") end
  task.spawn(function()
    local ids = {}
    for _, assetId in pairs(self.maps) do if assetId ~= "" then table.insert(ids, assetId) end end
    if #ids > 0 then
      local ok = pcall(function() ContentProvider:PreloadAsync(ids) end)
      if ok and self.assetFetchStatus == "pending" then
        self.assetFetchStatus = "ok"
        self.runtime:SetAttribute("OceanMaterialAssetFetchStatus", "ok")
      end
    end
  end)
end

function WaterMaterialController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  if self.childAddedConnection then self.childAddedConnection:Disconnect() self.childAddedConnection = nil end
  if self.assetFetchFailedConnection then self.assetFetchFailedConnection:Disconnect() self.assetFetchFailedConnection = nil end
  self.from = nil
  self.target = nil
  table.clear(self.surfaces)
end

return WaterMaterialController
