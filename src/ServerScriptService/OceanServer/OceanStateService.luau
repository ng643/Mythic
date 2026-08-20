--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Workspace = game:GetService("Workspace")
local RunService = game:GetService("RunService")
local Config = require(ReplicatedStorage.Ocean.Shared.OceanConfig)
local OceanTypes = require(ReplicatedStorage.Ocean.Shared.OceanTypes)
local Presets = require(ReplicatedStorage.Ocean.Shared.OceanPresets)
local SpectrumGenerator = require(ReplicatedStorage.Ocean.Shared.SpectrumGenerator)

local OceanStateService = {}
OceanStateService.__index = OceanStateService

local function now(): number
  return Workspace:GetServerTimeNow()
end

function OceanStateService.new()
  local seed = math.floor(now() * 1000) % 1000000000
  local epoch = now()
  local preset = Presets.Get(Config.DefaultPreset)
  local self = setmetatable({
    state = SpectrumGenerator.BuildState(preset, seed, epoch),
    presetName = preset.name,
    callbacks = {},
  }, OceanStateService)
  if RunService:IsStudio() and ReplicatedStorage.Ocean:GetAttribute("OceanDebugSpectrum") == true then
    local summary = SpectrumGenerator.Summarize(self.state.bankA)
    print(string.format("OceanSpectrum | preset=%s components=%d wavelengths=%.1f/%.1f/%.1f periods=%.2f..%.2f variance=%.3f steepness=%.3f", preset.name, summary.componentCount, summary.wavelengthMin, summary.wavelengthMedian, summary.wavelengthMax, summary.periodMin, summary.periodMax, summary.totalVariance, summary.aggregateSteepness))
  end
  return self
end

function OceanStateService:_PromoteDestination(serverTime: number, notify: boolean): boolean
  if self.state.bankBlendDuration <= 0 then return false end
  self.state.bankA = self.state.bankB
  self.state.bankB = table.clone(self.state.bankA)
  self.state.bankBlendStart = serverTime
  self.state.bankBlendDuration = 0
  self.state.bankBlendTarget = 0
  if notify then self:_Changed() end
  return true
end

function OceanStateService:GetState(): OceanTypes.OceanState
  local serverTime = now()
  if self.state.bankBlendDuration > 0 and serverTime >= self.state.bankBlendStart + self.state.bankBlendDuration then
    self:_PromoteDestination(serverTime, true)
  end
  self:PruneExpiredEvents(serverTime)
  return self.state
end

function OceanStateService:GetPresetName(): string
  return self.presetName
end

function OceanStateService:Subscribe(callback: (OceanTypes.OceanState) -> ())
  table.insert(self.callbacks, callback)
end

function OceanStateService:_Changed()
  self.state.version += 1
  for _, callback in ipairs(self.callbacks) do
    task.spawn(callback, self.state)
  end
end

function OceanStateService:TransitionTo(presetName: string, duration: number?): (boolean, string?)
  local preset = Presets.Get(presetName)
  if preset.name ~= presetName and presetName ~= Config.DefaultPreset then
    return false, "unknown preset: " .. presetName
  end
  local transitionDuration = math.clamp(duration or 30, 5, 120)
  local transitionNow = now()
  -- A new transition must start from the latest destination, never stale bankA.
  if self.state.bankBlendDuration > 0 then
    self:_PromoteDestination(transitionNow, false)
  end
  local transitionSeed = self.state.seed + math.floor(now() * 1000) % 1000003
  self.state.bankB = SpectrumGenerator.Generate(preset, transitionSeed)
  if RunService:IsStudio() and ReplicatedStorage.Ocean:GetAttribute("OceanDebugSpectrum") == true then
    local summary = SpectrumGenerator.Summarize(self.state.bankB)
    print(string.format("OceanSpectrum | transition=%s components=%d wavelengths=%.1f/%.1f/%.1f periods=%.2f..%.2f variance=%.3f steepness=%.3f", preset.name, summary.componentCount, summary.wavelengthMin, summary.wavelengthMedian, summary.wavelengthMax, summary.periodMin, summary.periodMax, summary.totalVariance, summary.aggregateSteepness))
  end
  self.state.bankBlendStart = transitionNow
  self.state.bankBlendDuration = transitionDuration
  self.state.bankBlendTarget = 1
  self.state.waterColor = preset.waterColor
  self.state.horizonColor = preset.horizonColor
  self.state.roughness = preset.roughness
  self.state.clarity = math.clamp(1 - preset.stormIntensity * 0.65, 0.15, 1)
  self.state.foamThreshold = Config.FoamJacobianThreshold - preset.foamAmount * 0.18
  self.state.windWorld = Vector3.new(math.cos(math.rad(preset.windDirectionDegrees)), 0, math.sin(math.rad(preset.windDirectionDegrees))) * preset.windSpeedMetersPerSecond * Config.MetersToStuds
  self.state.stormIntensity = preset.stormIntensity
  self.state.seed = transitionSeed
  self.presetName = preset.name
  self:_Changed()
  return true
end

function OceanStateService:AddEvent(event: OceanTypes.WaveEvent): (boolean, string?)
  if event.id == "" or event.duration <= 0 or event.wavelength <= 0 or event.amplitude == 0 then
    return false, "invalid wave event"
  end
  event.direction = event.direction.Magnitude > 1e-5 and event.direction.Unit or Vector2.xAxis
  event.startServerTime = event.startServerTime > 0 and event.startServerTime or now()
  table.insert(self.state.disturbances, event)
  self:_Changed()
  return true
end

function OceanStateService:CancelEvent(id: string): boolean
  for index = #self.state.disturbances, 1, -1 do
    if self.state.disturbances[index].id == id then
      table.remove(self.state.disturbances, index)
      self:_Changed()
      return true
    end
  end
  return false
end

function OceanStateService:PruneExpiredEvents(serverTime: number)
  if self.state.bankBlendDuration > 0 and serverTime >= self.state.bankBlendStart + self.state.bankBlendDuration then
    self:_PromoteDestination(serverTime, true)
  end
  local changed = false
  for index = #self.state.disturbances, 1, -1 do
    local event = self.state.disturbances[index]
    if serverTime > event.startServerTime + event.duration then
      table.remove(self.state.disturbances, index)
      changed = true
    end
  end
  if changed then
    self:_Changed()
  end
end

return OceanStateService
