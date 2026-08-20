--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local OceanTypes = require(ReplicatedStorage.Ocean.Shared.OceanTypes)

local WaveEventService = {}
WaveEventService.__index = WaveEventService

function WaveEventService.new(stateService)
  return setmetatable({stateService = stateService, nextId = 0}, WaveEventService)
end

function WaveEventService:_Id(prefix: string): string
  self.nextId += 1
  return string.format("%s_%d_%d", prefix, math.floor(Workspace:GetServerTimeNow() * 1000), self.nextId)
end

function WaveEventService:SpawnPacket(originXZ: Vector2, direction: Vector2, amplitude: number, wavelength: number, length: number, width: number, duration: number, gameplayRelevant: boolean?): (boolean, string?, string?)
  local event: OceanTypes.WaveEvent = {
    id = self:_Id("packet"),
    kind = "Packet",
    startServerTime = Workspace:GetServerTimeNow(),
    duration = duration,
    originXZ = originXZ,
    direction = direction,
    amplitude = amplitude,
    wavelength = wavelength,
    length = length,
    width = width,
    phase = 0,
    choppiness = 0.4,
    gameplayRelevant = gameplayRelevant == true,
  }
  local ok, reason = self.stateService:AddEvent(event)
  return ok, reason, event.id
end

function WaveEventService:SpawnImpact(originXZ: Vector2, amplitude: number, wavelength: number, duration: number, gameplayRelevant: boolean?): (boolean, string?, string?)
  local event: OceanTypes.WaveEvent = {
    id = self:_Id("impact"),
    kind = "Impact",
    startServerTime = Workspace:GetServerTimeNow(),
    duration = duration,
    originXZ = originXZ,
    direction = Vector2.xAxis,
    amplitude = amplitude,
    wavelength = wavelength,
    length = math.max(wavelength * 2, 12),
    width = math.max(wavelength * 2, 12),
    phase = 0,
    choppiness = 0.2,
    gameplayRelevant = gameplayRelevant == true,
  }
  local ok, reason = self.stateService:AddEvent(event)
  return ok, reason, event.id
end

return WaveEventService
