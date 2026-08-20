--!strict

local Config = require(script.Parent.OceanConfig)
local OceanTypes = require(script.Parent.OceanTypes)

local SpectrumGenerator = {}
local TWO_PI = math.pi * 2

local function makeRng(seed: number): () -> number
  local state = math.floor(math.abs(seed)) % 2147483647
  if state == 0 then state = 1 end
  return function(): number
    state = (state * 48271) % 2147483647
    return state / 2147483647
  end
end

local function degreesToDirection(degrees: number): Vector2
  local radians = math.rad(degrees)
  return Vector2.new(math.cos(radians), math.sin(radians)).Unit
end

local function directionalOffset(rng: () -> number, spreadDegrees: number): number
  local centered = rng() * 2 - 1
  return centered * spreadDegrees
end

local function makeComponent(direction: Vector2, amplitude: number, wavelength: number, phase: number, minRenderTier: number?): OceanTypes.WaveComponent
  local waveNumber = TWO_PI / wavelength
  local angularFrequency = math.sqrt(Config.WaveGravity * waveNumber)
  return {
    direction = direction.Unit,
    amplitude = amplitude,
    wavelength = wavelength,
    waveNumber = waveNumber,
    angularFrequency = angularFrequency,
    horizontalAmplitude = 0,
    phase = phase % TWO_PI,
    energy = amplitude * amplitude * 0.5,
    minRenderTier = minRenderTier,
  }
end

function SpectrumGenerator.Generate(preset: OceanTypes.OceanPreset, seed: number, maxSteepness: number?): {OceanTypes.WaveComponent}
  local ok, reason = Config.ValidatePreset(preset)
  if not ok then
    error(reason)
  end
  local rng = makeRng(seed)
  local components: {OceanTypes.WaveComponent} = {}
  local meterToStuds = Config.MetersToStuds
  local peakWavelength = math.max(18, Config.WaveGravity * (preset.peakPeriodSeconds * meterToStuds) ^ 2 / TWO_PI)
  local rawEnergy = {}
  local rawSum = 0

  for i = 1, 10 do
    local logOffset = (i - 5.5) / 3.2
    local wavelength = math.clamp(peakWavelength * 2 ^ logOffset, 18, 720)
    local ratio = wavelength / peakWavelength
    local logRatio = math.log(ratio)
    local broad = math.exp(-0.5 * (logRatio / 0.82) ^ 2)
    local peakBoost = math.exp(-0.5 * (logRatio / 0.22) ^ 2) * 1.35
    local energy = (broad + peakBoost) * (0.85 + rng() * 0.3)
    table.insert(rawEnergy, {wavelength, energy})
    rawSum += energy
  end

  local targetHsStuds = preset.significantWaveHeightMeters * meterToStuds
  local targetM0 = (targetHsStuds * 0.25) ^ 2
  local amplitudeScale = math.sqrt((2 * targetM0) / math.max(rawSum, 1e-6))
  local windDirection = degreesToDirection(preset.windDirectionDegrees)
  for i, data in ipairs(rawEnergy) do
    local wavelength = data[1]
    local amplitude = math.sqrt(data[2]) * amplitudeScale
    local direction = degreesToDirection(preset.windDirectionDegrees + directionalOffset(rng, preset.directionalSpreadDegrees))
    local phase = rng() * TWO_PI
    local component = makeComponent(direction, amplitude, wavelength, phase, i > 6 and 2 or 1)
    component.horizontalAmplitude = amplitude * preset.choppiness * 0.55
    table.insert(components, component)
  end

  if preset.swellHeightMeters > 0 then
    local swellWavelength = math.max(42, Config.WaveGravity * (preset.swellPeriodSeconds * meterToStuds) ^ 2 / TWO_PI)
    local swellAmplitude = preset.swellHeightMeters * meterToStuds * 0.5
    local swellDirection = degreesToDirection(preset.swellDirectionDegrees)
    for side = -1, 1, 2 do
      local direction = (swellDirection + Vector2.new(-swellDirection.Y, swellDirection.X) * (0.08 * side)).Unit
      local component = makeComponent(direction, swellAmplitude * 0.72, swellWavelength, rng() * TWO_PI, 1)
      component.horizontalAmplitude = component.amplitude * preset.choppiness * 0.38
      table.insert(components, component)
    end
  end

  local aggregate = 0
  for _, component in ipairs(components) do
    aggregate += component.waveNumber * math.abs(component.horizontalAmplitude)
  end
  local safeSteepness = math.clamp(maxSteepness or Config.MaxAggregateSteepness, 0.1, 0.9)
  local normalizer = aggregate > safeSteepness and safeSteepness / aggregate or 1
  for _, component in ipairs(components) do
    component.horizontalAmplitude *= normalizer
  end

  local _ = windDirection
  return components
end

function SpectrumGenerator.BuildState(preset: OceanTypes.OceanPreset, seed: number, epochServerTime: number): OceanTypes.OceanState
  local bank = SpectrumGenerator.Generate(preset, seed)
  return {
    version = Config.StateVersion,
    seed = seed,
    epochServerTime = epochServerTime,
    seaLevel = Config.DefaultSeaLevel,
    waveGravity = Config.WaveGravity,
    bankA = bank,
    bankB = table.clone(bank),
    bankBlendStart = epochServerTime,
    bankBlendDuration = 0,
    bankBlendTarget = 0,
    waterColor = preset.waterColor,
    horizonColor = preset.horizonColor,
    roughness = preset.roughness,
    clarity = math.clamp(1 - preset.stormIntensity * 0.65, 0.15, 1),
    foamThreshold = Config.FoamJacobianThreshold - preset.foamAmount * 0.18,
    windWorld = Vector3.new(math.cos(math.rad(preset.windDirectionDegrees)), 0, math.sin(math.rad(preset.windDirectionDegrees))) * preset.windSpeedMetersPerSecond * Config.MetersToStuds,
    stormIntensity = preset.stormIntensity,
    disturbances = {},
  }
end

return SpectrumGenerator
