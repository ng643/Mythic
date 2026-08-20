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
local UnderwaterController = require(clientFolder.UnderwaterController)
local FoamController = require(clientFolder.FoamController)
local SprayController = require(clientFolder.SprayController)
local WakeController = require(clientFolder.WakeController)
local SwimmingController = require(clientFolder.SwimmingController)

local runtime = Workspace:FindFirstChild("OceanRuntime") :: Folder?
if not runtime then
  runtime = Instance.new("Folder")
  runtime.Name = "OceanRuntime"
  runtime.Parent = Workspace
end
clearCapabilityLab(runtime)
hidePlaceholderBaseplate()
runtime:SetAttribute("OceanAdaptiveQuality", true)
runtime:SetAttribute("OceanExperimentalClipmaps", false)
local requestedQuality = runtime:GetAttribute("OceanQuality") or "High"

local clock = OceanClock.new(initialState.epochServerTime)
local waveField = WaveField.new(initialState, clock)
local renderer = OceanRenderer.new(waveField)
renderer:SetQuality(requestedQuality)
renderer:Start()
local materialController = WaterMaterialController.new(runtime)
materialController:Apply(initialState)
local qualityController = OceanQualityController.new(renderer, runtime)
qualityController:Start()
local underwaterController = UnderwaterController.new(waveField)
underwaterController:Start()
local foamController = FoamController.new(waveField, runtime)
foamController:SetCap(24)
foamController:Start()
local sprayController = SprayController.new(waveField, runtime)
sprayController:SetCap(16)
sprayController:Start()
local wakeController = WakeController.new(runtime)
wakeController:Start()
local swimmingController = SwimmingController.new(waveField)
swimmingController:Start()

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
    runtime:SetAttribute("OceanVertexCount", stats.vertexCount)
    runtime:SetAttribute("OceanTriangleCount", stats.triangleCount)
    runtime:SetAttribute("OceanFrameMs", stats.lastFrameMs)
    runtime:SetAttribute("OceanUpdateMs", stats.lastUpdateMs)
    runtime:SetAttribute("OceanFallback", stats.fallback)
  end
end)

script.Destroying:Connect(function()
  underwaterController:Stop()
  qualityController:Stop()
  foamController:Stop()
  sprayController:Stop()
  wakeController:Stop()
  swimmingController:Stop()
  renderer:Stop()
end)

print(string.format("OceanClient | running quality=%s rings=%d vertices=%d triangles=%d", tostring(requestedQuality), renderer:GetStats().ringCount, renderer:GetStats().vertexCount, renderer:GetStats().triangleCount))
