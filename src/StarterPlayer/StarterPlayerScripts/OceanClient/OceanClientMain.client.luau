--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")

local ocean = ReplicatedStorage:WaitForChild("Ocean")
local shared = ocean:WaitForChild("Shared")
local remotes = ocean:WaitForChild("Remotes")
local clientFolder = script.Parent

local function hidePlaceholderBaseplate()
  local baseplate = Workspace:FindFirstChild("Baseplate")
  if baseplate and baseplate:IsA("BasePart") then
    baseplate.LocalTransparencyModifier = 1
    baseplate.Transparency = 1
    local texture = baseplate:FindFirstChildWhichIsA("Texture")
    if texture then texture.Transparency = 1 end
  end
end

local function clearCapabilityLab(runtime: Folder)
  local lab = clientFolder:FindFirstChild("OceanCapabilityLab")
  if lab then lab:Destroy() end
  for _, child in ipairs(runtime:GetChildren()) do
    if string.sub(child.Name, 1, 10) == "Capability" then
      child:Destroy()
    end
  end
end

local runtime = Workspace:FindFirstChild("OceanRuntime") :: Folder?
if not runtime then
  runtime = Instance.new("Folder")
  runtime.Name = "OceanRuntime"
  runtime.Parent = Workspace
end
runtime:SetAttribute("OceanClientStatus", "starting")

local getOceanState = remotes:WaitForChild("GetOceanState") :: RemoteFunction
local stateChanged = remotes:WaitForChild("OceanStateChanged") :: RemoteEvent
local ok, initialState = pcall(function()
  return getOceanState:InvokeServer()
end)
if not ok or type(initialState) ~= "table" then
  local message = "State: " .. tostring(initialState)
  runtime:SetAttribute("OceanClientStatus", "error")
  runtime:SetAttribute("OceanClientError", message)
  warn("OceanClient | startup failed | " .. message)
  return
end

local OceanClock = require(shared.OceanClock)
local WaveField = require(shared.WaveField)
local OceanRenderer = require(clientFolder.OceanRenderer)
local WaterMaterialController = require(clientFolder.WaterMaterialController)
local OceanQualityController = require(clientFolder.OceanQualityController)
local QualityProfiles = require(shared.QualityProfiles)
local UnderwaterController = require(clientFolder.UnderwaterController)
local FoamController = require(clientFolder.FoamController)
local SprayController = require(clientFolder.SprayController)
local WakeController = require(clientFolder.WakeController)
local SwimmingController = require(clientFolder.SwimmingController)
local BuoyancyVisualizer = require(clientFolder.BuoyancyVisualizer)
local ShorelineController = require(clientFolder.ShorelineController)
local VisualSampleScheduler = require(clientFolder.VisualSampleScheduler)

clearCapabilityLab(runtime)
hidePlaceholderBaseplate()
runtime:SetAttribute("OceanClientStatus", "starting")
runtime:SetAttribute("OceanClientError", nil)
runtime:SetAttribute("OceanAdaptiveQuality", true)
if runtime:GetAttribute("OceanExperimentalClipmaps") == nil then
  runtime:SetAttribute("OceanExperimentalClipmaps", true)
end
local featureDefaults = {
  OceanFoamEnabled = true,
  OceanSprayEnabled = true,
  OceanWakesEnabled = true,
  OceanUnderwaterEnabled = true,
  OceanSwimmingEnabled = true,
  OceanShorelineEnabled = true,
}
for attribute, defaultValue in pairs(featureDefaults) do
  if runtime:GetAttribute(attribute) == nil then runtime:SetAttribute(attribute, defaultValue) end
end
for _, debugName in ipairs({"OceanDebugBuoyancy", "OceanDebugSeams", "OceanDebugMetrics"}) do
  if runtime:GetAttribute(debugName) == nil then runtime:SetAttribute(debugName, false) end
end
local qualityOverride = runtime:GetAttribute("OceanQualityOverride")
local requestedQuality = type(qualityOverride) == "string" and qualityOverride or "Medium"
local requestedProfile = QualityProfiles.Get(requestedQuality)
local validRequestedQuality = requestedQuality == "Ultra"
  or requestedQuality == "High"
  or requestedQuality == "Medium"
  or requestedQuality == "Low"
if not validRequestedQuality or requestedQuality == "Fallback" or not requestedProfile or requestedProfile.resolution == 0 then
  requestedQuality = "Medium"
  runtime:SetAttribute("OceanQualityOverrideRejected", true)
end

local clock = OceanClock.new(initialState.epochServerTime)
local waveField = WaveField.new(initialState, clock)
local visualSamples = VisualSampleScheduler.new(waveField)
local renderer = OceanRenderer.new(waveField)
local materialController = WaterMaterialController.new(runtime)
local qualityController = OceanQualityController.new(renderer, runtime)
local underwaterController = UnderwaterController.new(waveField, runtime, visualSamples)
local foamController = FoamController.new(waveField, runtime, visualSamples)
local sprayController = SprayController.new(waveField, runtime, visualSamples)
local wakeController = WakeController.new(runtime, waveField, visualSamples)
local swimmingController = SwimmingController.new(waveField, runtime, visualSamples)
local buoyancyVisualizer = BuoyancyVisualizer.new(waveField, runtime)
local shorelineController = ShorelineController.new(waveField, runtime, visualSamples)
local qualityAttributeConnection = nil
local stateConnection = nil
local startedStops = {}

local function failStartup(subsystem: string, reason: any)
  local message = string.format("%s: %s", subsystem, tostring(reason))
  runtime:SetAttribute("OceanClientStatus", "error")
  runtime:SetAttribute("OceanClientError", message)
  warn("OceanClient | startup failed | " .. message)
end

local function startSubsystem(subsystem: string, startFn, stopFn): boolean
  local started, reason = pcall(startFn)
  if not started then
    failStartup(subsystem, reason)
    for index = #startedStops, 1, -1 do
      pcall(startedStops[index])
    end
    return false
  end
  table.insert(startedStops, stopFn)
  return true
end

local function applyVfxBudget()
  local profile = QualityProfiles.Get(runtime:GetAttribute("OceanQuality") or requestedQuality)
  foamController:SetCap(math.min(24, profile.foamCap))
  sprayController:SetCap(math.min(16, math.max(0, math.floor(profile.foamCap * 0.2))))
end

local startupSteps = {
  {"Renderer", function() renderer:SetQuality(requestedQuality) renderer:Start() end, function() renderer:Stop() end},
  {"Material", function() materialController:Apply(initialState) materialController:Start() end, function() materialController:Stop() end},
  {"Quality", function() qualityController:Start() end, function() qualityController:Stop() end},
  {"Underwater", function() underwaterController:Start() end, function() underwaterController:Stop() end},
  {"Foam", function() applyVfxBudget() foamController:Start() end, function() foamController:Stop() end},
  {"Spray", function() sprayController:Start() end, function() sprayController:Stop() end},
  {"Wake", function() wakeController:Start() end, function() wakeController:Stop() end},
  {"Swimming", function() swimmingController:Start() end, function() swimmingController:Stop() end},
  {"BuoyancyVisualizer", function() buoyancyVisualizer:Start() end, function() buoyancyVisualizer:Stop() end},
  {"Shoreline", function() shorelineController:Start() end, function() shorelineController:Stop() end},
}
for _, step in ipairs(startupSteps) do
  if not startSubsystem(step[1], step[2], step[3]) then return end
end

local requiredSubsystems = {
  Renderer = function() return renderer.running end,
  Material = function() return materialController.connection ~= nil end,
  Underwater = function() return underwaterController.connection ~= nil end,
  Foam = function() return foamController.connection ~= nil end,
  Spray = function() return sprayController.connection ~= nil end,
  Wake = function() return wakeController.connection ~= nil end,
  Swimming = function() return swimmingController.connection ~= nil end,
  Shoreline = function() return shorelineController.connection ~= nil end,
}
for subsystem, check in pairs(requiredSubsystems) do
  local checkOk, running = pcall(check)
  if not checkOk or running ~= true then
    failStartup("Smoke/" .. subsystem, checkOk and "not running" or running)
    return
  end
  runtime:SetAttribute("OceanSubsystem_" .. subsystem, true)
end

qualityAttributeConnection = runtime:GetAttributeChangedSignal("OceanQuality"):Connect(applyVfxBudget)
stateConnection = stateChanged.OnClientEvent:Connect(function(nextState)
  if type(nextState) == "table" then
    waveField:SetState(nextState)
    if swimmingController.Invalidate then swimmingController:Invalidate() end
    if underwaterController.Invalidate then underwaterController:Invalidate() end
    materialController:Apply(nextState)
  end
end)
runtime:SetAttribute("OceanQuality", requestedQuality)
runtime:SetAttribute("OceanClientStatus", "running")
runtime:SetAttribute("OceanClientError", nil)
script:SetAttribute("OceanClientRunning", true)
task.spawn(function()
  while script.Parent do
    task.wait(1)
    local stats = renderer:GetStats()
    runtime:SetAttribute("OceanRingCount", stats.ringCount)
    runtime:SetAttribute("OceanRequestedRingCount", stats.requestedRingCount)
    runtime:SetAttribute("OceanHorizonTileCount", stats.horizonTileCount)
    runtime:SetAttribute("OceanTransitionCount", stats.transitionCount)
    runtime:SetAttribute("OceanSeamMaxPositionError", stats.seamPositionError)
    runtime:SetAttribute("OceanSeamMaxNormalError", stats.seamNormalError)
    runtime:SetAttribute("OceanTopologyStatus", stats.topologyStatus)
    runtime:SetAttribute("OceanBatchAvailable", stats.batchAvailable)
    runtime:SetAttribute("OceanBatchFailureReason", stats.batchFailureReason)
    runtime:SetAttribute("OceanVertexCount", stats.vertexCount + stats.transitionVertexCount)
    runtime:SetAttribute("OceanTriangleCount", stats.triangleCount + stats.transitionTriangleCount)
    runtime:SetAttribute("OceanNearVertexCount", stats.vertexCount)
    runtime:SetAttribute("OceanNearTriangleCount", stats.triangleCount)
    runtime:SetAttribute("OceanFrameMs", stats.lastFrameMs)
    runtime:SetAttribute("OceanOceanMs", stats.lastOceanMs)
    runtime:SetAttribute("OceanUpdateMs", stats.lastUpdateMs)
    runtime:SetAttribute("OceanWaveEvaluateMs", stats.lastWaveEvaluateMs)
    runtime:SetAttribute("OceanVertexCommitMs", stats.lastVertexCommitMs)
    runtime:SetAttribute("OceanNormalCommitMs", stats.lastNormalCommitMs)
    runtime:SetAttribute("OceanUVUpdateMs", stats.lastUVUpdateMs)
    runtime:SetAttribute("OceanFallback", stats.fallback)
  end
end)
script.Destroying:Connect(function()
  runtime:SetAttribute("OceanClientStatus", "stopped")
  script:SetAttribute("OceanClientRunning", false)
  underwaterController:Stop()
  materialController:Stop()
  qualityController:Stop()
  foamController:Stop()
  sprayController:Stop()
  wakeController:Stop()
  swimmingController:Stop()
  buoyancyVisualizer:Stop()
  shorelineController:Stop()
  renderer:Stop()
  if qualityAttributeConnection then qualityAttributeConnection:Disconnect() end
  if stateConnection then stateConnection:Disconnect() end
end)

print(string.format("OceanClient | running quality=%s rings=%d vertices=%d triangles=%d", tostring(requestedQuality), renderer:GetStats().ringCount, renderer:GetStats().vertexCount, renderer:GetStats().triangleCount))
