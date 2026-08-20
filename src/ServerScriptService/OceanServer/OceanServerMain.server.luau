--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local ocean = ReplicatedStorage:WaitForChild("Ocean")
local remotes = ocean:WaitForChild("Remotes")
local getOceanState = remotes:WaitForChild("GetOceanState") :: RemoteFunction
local stateChanged = remotes:WaitForChild("OceanStateChanged") :: RemoteEvent

local StateService = require(script.Parent.OceanStateService)
local WaveEventService = require(script.Parent.WaveEventService)
local WaveField = require(ReplicatedStorage.Ocean.Shared.WaveField)
local ShipRegistry = require(script.Parent.ShipRegistry)
local BuoyancyService = require(script.Parent.BuoyancyService)
local ShipValidationService = require(script.Parent.ShipValidationService)
local SwimmingValidationService = require(script.Parent.SwimmingValidationService)
local stateService = StateService.new()
local eventService = WaveEventService.new(stateService)
local waveField = WaveField.new(stateService:GetState())
local shipRegistry = ShipRegistry.new()
local buoyancyService = BuoyancyService.new(waveField, shipRegistry)
local validationService = ShipValidationService.new(shipRegistry)
local swimmingValidationService = SwimmingValidationService.new(waveField)
swimmingValidationService:Start()
stateService:Subscribe(function(state)
  waveField:SetState(state)
end)
buoyancyService:Start()
validationService:Start()

local debugCommand = script.Parent:FindFirstChild("OceanDebugCommand")
if debugCommand and debugCommand:IsA("BindableEvent") then
  debugCommand.Event:Connect(function(command)
    if type(command) ~= "table" then return end
    if command.kind == "Transition" then
      stateService:TransitionTo(command.preset or "Trade Sea", command.duration or 30)
    elseif command.kind == "Packet" then
      eventService:SpawnPacket(command.originXZ or Vector2.zero, command.direction or Vector2.xAxis, command.amplitude or 8, command.wavelength or 48, command.length or 144, command.width or 48, command.duration or 18, true)
    elseif command.kind == "Impact" then
      eventService:SpawnImpact(command.originXZ or Vector2.zero, command.amplitude or 8, command.wavelength or 24, command.duration or 10, true)
    elseif command.kind == "Cancel" and command.id then
      stateService:CancelEvent(command.id)
    end
  end)
end

local function publishAttributes()
  local state = stateService:GetState()
  ocean:SetAttribute("StateVersion", state.version)
  ocean:SetAttribute("OceanEpoch", state.epochServerTime)
  ocean:SetAttribute("SeaLevel", state.seaLevel)
  ocean:SetAttribute("PresetName", stateService:GetPresetName())
  ocean:SetAttribute("StormIntensity", state.stormIntensity)
end

stateService:Subscribe(function(state)
  publishAttributes()
  stateChanged:FireAllClients(state)
end)

getOceanState.OnServerInvoke = function(_player: Player)
  return stateService:GetState()
end

publishAttributes()

-- Keep expiry and attribute state maintenance off the render path.
local accumulator = 0
RunService.Heartbeat:Connect(function(dt)
  accumulator += dt
  if accumulator >= 0.5 then
    accumulator = 0
    stateService:PruneExpiredEvents(workspace:GetServerTimeNow())
    publishAttributes()
  end
end)

-- Server-only debug hooks for Studio command-bar experiments.
_G.OceanServer = {
  StateService = stateService,
  WaveEventService = eventService,
  WaveField = waveField,
  ShipRegistry = shipRegistry,
  BuoyancyService = buoyancyService,
  Transition = function(name: string, duration: number?) return stateService:TransitionTo(name, duration) end,
  RoguePacket = function(originXZ: Vector2, direction: Vector2, amplitude: number, wavelength: number) return eventService:SpawnPacket(originXZ, direction, amplitude, wavelength, wavelength * 3, wavelength, 18, true) end,
  Impact = function(originXZ: Vector2, amplitude: number) return eventService:SpawnImpact(originXZ, amplitude, 18, 8, true) end,
}
