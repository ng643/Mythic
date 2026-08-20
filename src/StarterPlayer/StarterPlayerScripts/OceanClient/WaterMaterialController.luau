--!strict

local ContentProvider = game:GetService("ContentProvider")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local WaterMaterialController = {}
WaterMaterialController.__index = WaterMaterialController

local WATER_APPEARANCE_SLOT = "OceanWaterPBR"
local SURFACE_APPEARANCE_NAME = "OceanSurfaceAppearance"
local UV_SPACE = "WorldXZ"
local UV_TILE_SCALE = 10
local ASSET_ROLES = {"ColorMap", "NormalMap", "RoughnessMap", "MetalnessMap"}
local FALLBACK_ASSET_IDS = {
  ColorMap = "rbxassetid://128922037556159",
  NormalMap = "rbxassetid://101286961773967",
  RoughnessMap = "rbxassetid://111100454366205",
  MetalnessMap = "rbxassetid://126230944196062",
}

local function findWaterAppearanceSlot(): Instance?
  local ocean = ReplicatedStorage:FindFirstChild("Ocean")
  local assets = ocean and ocean:FindFirstChild("Assets")
  local appearances = assets and assets:FindFirstChild("WaterAppearances")
  if not appearances then
    return nil
  end
  return appearances:FindFirstChild(WATER_APPEARANCE_SLOT)
end

local function normalizeAssetId(value: any): string
  local text = tostring(value)
  if string.match(text, "^%d+$") then
    return "rbxassetid://" .. text
  end
  return text
end

local function readAssetManifest(): ({[string]: string}, Instance?)
  local slot = findWaterAppearanceSlot()
  local manifest = {}
  for _, role in ipairs(ASSET_ROLES) do
    local fallback = FALLBACK_ASSET_IDS[role]
    local value = slot and slot:GetAttribute(role)
    manifest[role] = type(value) == "string" and value ~= "" and value or fallback
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

local function readSurfaceAssetId(appearance: SurfaceAppearance, role: string): string
  local value: any
  if role == "ColorMap" then
    value = appearance.ColorMap
  elseif role == "NormalMap" then
    value = appearance.NormalMap
  elseif role == "RoughnessMap" then
    value = appearance.RoughnessMap
  elseif role == "MetalnessMap" then
    value = appearance.MetalnessMap
  end
  local text = tostring(value)
  if text == "" or text == "nil" then
    return ""
  end
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
    qualityConnection = nil,
    childAddedConnection = nil,
    assetFetchFailedConnection = nil,
    applying = false,
    manifest = {},
    manifestSource = "missing",
    assetRoles = {},
    assetFetchStatus = "pending",
    assetFetchFailureCount = 0,
    failedAssetIds = {},
    warnedMissingAppearance = false,
    warnedMissingMaps = false,
    warnedFallback = false,
  }, WaterMaterialController)
  self:_RefreshManifest()
  return self
end

function WaterMaterialController:_RefreshManifest()
  local manifest, slot = readAssetManifest()
  self.manifest = manifest
  self.manifestSource = slot and slot:GetFullName() or "missing"
  table.clear(self.assetRoles)
  for _, role in ipairs(ASSET_ROLES) do
    self.assetRoles[normalizeAssetId(manifest[role])] = role
  end
end

function WaterMaterialController:_PublishManifest(values)
  local runtime = self.runtime
  runtime:SetAttribute("OceanMaterialPath", "SurfaceAppearance")
  runtime:SetAttribute("OceanMaterialUVSpace", UV_SPACE)
  runtime:SetAttribute("OceanMaterialWorldLockedUV", true)
  runtime:SetAttribute("OceanMaterialUVTileScale", UV_TILE_SCALE)
  runtime:SetAttribute("OceanMaterialUVFormula", "worldXZ / tileScale")
  runtime:SetAttribute("OceanMaterialUVConsumer", "OceanRenderer.EditableMesh")
  runtime:SetAttribute("OceanMaterialTintProperty", "SurfaceAppearance.Color")
  runtime:SetAttribute("OceanMaterialAlphaMode", "Opaque")
  runtime:SetAttribute("OceanMaterialNearTransparency", 0)
  runtime:SetAttribute("OceanMaterialActiveRoughness", values.roughness)
  runtime:SetAttribute("OceanMaterialRoughness", values.roughness)
  runtime:SetAttribute("OceanMaterialRoughnessSource", "SurfaceAppearance.RoughnessMap")
  runtime:SetAttribute("OceanMaterialManifestSource", self.manifestSource)
  runtime:SetAttribute("OceanMaterialAssetFetchStatus", self.assetFetchStatus)
  runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
  for _, role in ipairs(ASSET_ROLES) do
    local configuredId = self.manifest[role]
    runtime:SetAttribute("OceanMaterial" .. role .. "Id", configuredId)
    runtime:SetAttribute("OceanMaterialConfigured" .. role .. "Id", configuredId)
  end
end

function WaterMaterialController:_HandleAssetFetchFailed(assetId)
  local normalizedId = normalizeAssetId(assetId)
  local role = self.assetRoles[normalizedId]
  if not role or self.failedAssetIds[normalizedId] then
    return
  end
  self.failedAssetIds[normalizedId] = true
  self.assetFetchFailureCount += 1
  self.assetFetchStatus = "failed"
  self.runtime:SetAttribute("OceanMaterialAssetFetchStatus", self.assetFetchStatus)
  self.runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
  self.runtime:SetAttribute("OceanMaterialAssetFetchFailedId", normalizedId)
  self.runtime:SetAttribute("OceanMaterialAssetFetchFailedMap", role)
  self.runtime:SetAttribute("OceanMaterialValidationStatus", "error")
  warn(string.format(
    "WaterMaterialController | SurfaceAppearance asset fetch failed | map=%s id=%s quality=%s",
    role,
    normalizedId,
    tostring(self.runtime:GetAttribute("OceanQuality") or "unknown")
  ))
end

function WaterMaterialController:_RecordSurfaceAppearance(appearance: SurfaceAppearance, values, mapBindingState)
  appearance.Color = values.waterColor
  appearance.AlphaMode = Enum.AlphaMode.Opaque
  appearance:SetAttribute("OceanMaterialPath", "SurfaceAppearance")
  appearance:SetAttribute("OceanUVSpace", UV_SPACE)
  appearance:SetAttribute("OceanWorldLockedUV", true)
  appearance:SetAttribute("OceanUVTileScale", UV_TILE_SCALE)
  appearance:SetAttribute("OceanActiveRoughness", values.roughness)
  appearance:SetAttribute("OceanRoughnessMapId", self.manifest.RoughnessMap)

  local allMapsBound = true
  for _, role in ipairs(ASSET_ROLES) do
    local activeId = readSurfaceAssetId(appearance, role)
    if activeId == "" then
      allMapsBound = false
      activeId = "unassigned"
    end
    appearance:SetAttribute("Ocean" .. role .. "Id", activeId)
    self.runtime:SetAttribute("OceanMaterialActive" .. role .. "Id", activeId)
  end
  mapBindingState.count += 1
  if not allMapsBound then
    mapBindingState.allBound = false
  end
  appearance:SetAttribute("OceanMaterialMapBinding", allMapsBound and "active" or "missing")
end

function WaterMaterialController:_ApplyVisual(values, reason: string?)
  if self.applying then
    return
  end
  self.applying = true
  self:_RefreshManifest()
  self:_PublishManifest(values)
  Workspace.GlobalWind = values.windWorld

  local meshCount = 0
  local fallbackCount = 0
  local surfaceAppearanceCount = 0
  local missingAppearanceCount = 0
  local mapBindingState = {count = 0, allBound = true}

  for _, child in ipairs(self.runtime:GetChildren()) do
    if child:IsA("MeshPart") then
      meshCount += 1
      child.Material = Enum.Material.SmoothPlastic
      child.MaterialVariant = ""
      child.Transparency = 0
      child.Reflectance = 0
      child:SetAttribute("OceanMaterialPath", "SurfaceAppearance")
      child:SetAttribute("OceanUVSpace", UV_SPACE)
      child:SetAttribute("OceanWorldLockedUV", true)
      child:SetAttribute("OceanUVTileScale", UV_TILE_SCALE)

      local namedAppearance = child:FindFirstChild(SURFACE_APPEARANCE_NAME)
      if namedAppearance and not namedAppearance:IsA("SurfaceAppearance") then
        missingAppearanceCount += 1
        if not self.warnedMissingAppearance then
          warn(string.format(
            "WaterMaterialController | expected SurfaceAppearance %s on %s, found %s",
            SURFACE_APPEARANCE_NAME,
            child:GetFullName(),
            namedAppearance.ClassName
          ))
          self.warnedMissingAppearance = true
        end
      else
        local appearance: SurfaceAppearance
        if namedAppearance then
          appearance = namedAppearance :: SurfaceAppearance
        else
          appearance = Instance.new("SurfaceAppearance")
          appearance.Name = SURFACE_APPEARANCE_NAME
          appearance.Parent = child
        end
        surfaceAppearanceCount += 1
        self:_RecordSurfaceAppearance(appearance, values, mapBindingState)
      end
    elseif child:IsA("BasePart") and child.Name == "OceanFallbackSurface" then
      fallbackCount += 1
      child.Material = Enum.Material.SmoothPlastic
      child.Color = values.waterColor
      child.Reflectance = 0
      child.Transparency = 0
      child:SetAttribute("OceanMaterialPath", "FallbackOpaque")
      child:SetAttribute("OceanMaterialNearTransparency", 0)
      if not self.warnedFallback then
        warn("WaterMaterialController | using opaque fallback surface; SurfaceAppearance path is unavailable")
        self.warnedFallback = true
      end
    end
  end

  if surfaceAppearanceCount > 0 and not mapBindingState.allBound and not self.warnedMissingMaps then
    warn(string.format(
      "WaterMaterialController | SurfaceAppearance maps are not bound on the active instance(s) | configured=%s source=%s quality=%s",
      table.concat(ASSET_ROLES, ","),
      self.manifestSource,
      tostring(self.runtime:GetAttribute("OceanQuality") or "unknown")
    ))
    self.warnedMissingMaps = true
  end

  if surfaceAppearanceCount > 0 and mapBindingState.allBound and self.assetFetchStatus == "pending" then
    self.assetFetchStatus = "ok"
  end

  local validationStatus = "active"
  if self.assetFetchStatus == "failed" then
    validationStatus = "error"
  elseif meshCount == 0 and fallbackCount > 0 then
    validationStatus = "fallback"
  elseif meshCount == 0 then
    validationStatus = "missing_surface"
  elseif surfaceAppearanceCount == 0 or missingAppearanceCount > 0 or not mapBindingState.allBound then
    validationStatus = "error"
  end
  self.runtime:SetAttribute("OceanMaterialSurfaceAppearanceCount", surfaceAppearanceCount)
  self.runtime:SetAttribute("OceanMaterialMeshPartCount", meshCount)
  self.runtime:SetAttribute("OceanMaterialFallbackCount", fallbackCount)
  self.runtime:SetAttribute("OceanMaterialAssetFetchStatus", self.assetFetchStatus)
  self.runtime:SetAttribute("OceanMaterialAssetFetchFailureCount", self.assetFetchFailureCount)
  self.runtime:SetAttribute("OceanMaterialValidationStatus", validationStatus)
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
  if self.current then
    self:_ApplyVisual(self.current, reason)
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
  if self.connection then
    return
  end
  self:_RefreshManifest()
  self.assetFetchFailedConnection = ContentProvider.AssetFetchFailed:Connect(function(assetId)
    self:_HandleAssetFetchFailed(assetId)
  end)
  self.qualityConnection = self.runtime:GetAttributeChangedSignal("OceanQuality"):Connect(function()
    self:_ReapplyCurrent("renderer quality rebuild")
  end)
  self.childAddedConnection = self.runtime.ChildAdded:Connect(function(child)
    if child:IsA("MeshPart") or (child:IsA("BasePart") and child.Name == "OceanFallbackSurface") then
      self:_ReapplyCurrent("renderer quality rebuild")
    end
  end)
  self.connection = RunService.RenderStepped:Connect(function()
    if not self.target or not self.from then
      return
    end
    local alpha = math.clamp((Workspace:GetServerTimeNow() - self.transitionStart) / self.transitionDuration, 0, 1)
    self.current = blend(self.from, self.target, alpha)
    self:_ApplyVisual(self.current, "state transition")
    if alpha >= 1 then
      self.from = nil
      self.target = nil
    end
  end)
  self:_ReapplyCurrent("start")
end

function WaterMaterialController:Stop()
  if self.connection then
    self.connection:Disconnect()
    self.connection = nil
  end
  if self.qualityConnection then
    self.qualityConnection:Disconnect()
    self.qualityConnection = nil
  end
  if self.childAddedConnection then
    self.childAddedConnection:Disconnect()
    self.childAddedConnection = nil
  end
  if self.assetFetchFailedConnection then
    self.assetFetchFailedConnection:Disconnect()
    self.assetFetchFailedConnection = nil
  end
  self.from = nil
  self.target = nil
end

return WaterMaterialController
