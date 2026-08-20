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

local getOceanState = remotes:WaitForChild("GetOceanState") :: RemoteFunction
local stateChanged = remotes:WaitForChild("OceanStateChanged") :: RemoteEvent
local ok, initialState = pcall(function()
  return getOceanState:InvokeServer()
end)
if not ok or type(initialState) ~= "table" then
  warn("OceanClient | state request failed: " .. tostring(initialState))
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

local runtime = Workspace:FindFirstChild("OceanRuntime") :: Folder?
if not runtime then
  runtime = Instance.new("Folder")
  runtime.Name = "OceanRuntime"
  runtime.Parent = Workspace
end
clearCapabilityLab(runtime)
hidePlaceholderBaseplate()
runtime:SetAttribute("OceanAdaptiveQuality", true)
if runtime:GetAttribute("OceanExperimentalClipmaps") == nil then
  runtime:SetAttribute("OceanExperimentalClipmaps", true)
end
for _, debugName in ipairs({"OceanDebugBaseWater", "OceanDebugFoam", "OceanDebugSpray", "OceanDebugWakes", "OceanDebugBuoyancy"}) do
  if runtime:GetAttribute(debugName) == nil then runtime:SetAttribute(debugName, true) end
end
local requestedQuality = runtime:GetAttribute("OceanQuality") or "High"

local clock = OceanClock.new(initialState.epochServerTime)
local waveField = WaveField.new(initialState, clock)
local renderer = OceanRenderer.new(waveField)
renderer:SetQuality(requestedQuality)
renderer:Start()
local materialController = WaterMaterialController.new(runtime)
materialController:Apply(initialState)
materialController:Start()
local qualityController = OceanQualityController.new(renderer, runtime)
qualityController:Start()
local qualityAttributeConnection = runtime:GetAttributeChangedSignal("OceanQuality"):Connect(applyVfxBudget)
local underwaterController = UnderwaterController.new(waveField)
underwaterController:Start()
local foamController = FoamController.new(waveField, runtime)
local sprayController = SprayController.new(waveField, runtime)
local function applyVfxBudget()
  local profile = QualityProfiles.Get(runtime:GetAttribute("OceanQuality") or requestedQuality)
  foamController:SetCap(math.min(24, profile.foamCap))
  sprayController:SetCap(math.min(16, math.max(0, math.floor(profile.foamCap * 0.2))))
end
applyVfxBudget()
foamController:Start()
sprayController:Start()
local wakeController = WakeController.new(runtime)
wakeController:Start()
local swimmingController = SwimmingController.new(waveField)
swimmingController:Start()
local buoyancyVisualizer = BuoyancyVisualizer.new(waveField, runtime)
buoyancyVisualizer:Start()
local shorelineController = ShorelineController.new(waveField, runtime)
shorelineController:Start()

local function applyDebugVisibility()
  renderer:SetBaseVisible(runtime:GetAttribute("OceanDebugBaseWater") ~= false)
end
applyDebugVisibility()
local debugConnections = {}
for _, debugName in ipairs({"OceanDebugBaseWater"}) do
  table.insert(debugConnections, runtime:GetAttributeChangedSignal(debugName):Connect(applyDebugVisibility))
end

stateChanged.OnClientEvent:Connect(function(nextState)
  if type(nextState) == "table" then
    waveField:SetState(nextState)
    materialController:Apply(nextState)
  end
end)

runtime:SetAttribute("OceanClientStatus", "running")
runtime:SetAttribute("OceanQuality", requestedQuality)
script:SetAttribute("OceanClientRunning", true)
task.spawn(function()
  while script.Parent do
    task.wait(1)
    local stats = renderer:GetStats()
    runtime:SetAttribute("OceanRingCount", stats.ringCount)
    runtime:SetAttribute("OceanBatchAvailable", stats.batchAvailable)
    runtime:SetAttribute("OceanVertexCount", stats.vertexCount)
    runtime:SetAttribute("OceanTriangleCount", stats.triangleCount)
    runtime:SetAttribute("OceanFrameMs", stats.lastFrameMs)
    runtime:SetAttribute("OceanOceanMs", stats.lastOceanMs)
    runtime:SetAttribute("OceanUpdateMs", stats.lastUpdateMs)
    runtime:SetAttribute("OceanFallback", stats.fallback)
  end
end)

script.Destroying:Connect(function()
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
  qualityAttributeConnection:Disconnect()
  for _, connection in ipairs(debugConnections) do connection:Disconnect() end
end)

print(string.format("OceanClient | running quality=%s rings=%d vertices=%d triangles=%d", tostring(requestedQuality), renderer:GetStats().ringCount, renderer:GetStats().vertexCount, renderer:GetStats().triangleCount))
