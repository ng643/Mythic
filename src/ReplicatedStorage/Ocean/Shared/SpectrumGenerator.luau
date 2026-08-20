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
  local studsPerMeter = Config.MetersToStuds
  -- Deep-water dispersion: wavelength = g * T² / (2π). T is already seconds;
  -- convert the resulting length once by using WaveGravity in studs/s².
  local peakWavelength = math.max(18, Config.WaveGravity * preset.peakPeriodSeconds ^ 2 / TWO_PI)
  local minimumWavelength = 18
  local maximumWavelength = math.max(720, peakWavelength * 3)
  local swellWavelength = preset.swellHeightMeters > 0 and math.max(42, Config.WaveGravity * preset.swellPeriodSeconds ^ 2 / TWO_PI) or 0
  local rawEnergy = {}
  local rawSum = 0

  for i = 1, 10 do
    -- Include the exact spectral peak while retaining logarithmic coverage.
    local logOffset = (i - 5) / 3.2
    local wavelength = math.clamp(peakWavelength * 2 ^ logOffset, minimumWavelength, maximumWavelength)
    -- Keep the exact swell wavelength unique when the logarithmic wind grid lands on it.
    if swellWavelength > 0 and math.abs(wavelength - swellWavelength) / swellWavelength < 0.01 then
      wavelength *= 0.93
    end
    local ratio = wavelength / peakWavelength
    local logRatio = math.log(ratio)
    local broad = math.exp(-0.5 * (logRatio / 0.82) ^ 2)
    local peakBoost = math.exp(-0.5 * (logRatio / 0.22) ^ 2) * 1.35
    local energy = (broad + peakBoost) * (0.85 + rng() * 0.3)
    table.insert(rawEnergy, {wavelength, energy})
    rawSum += energy
  end

  local targetHsStuds = preset.significantWaveHeightMeters * studsPerMeter
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
    local swellAmplitude = preset.swellHeightMeters * studsPerMeter * 0.5
    local swellDirection = degreesToDirection(preset.swellDirectionDegrees)
    for side = -1, 1, 2 do
      local direction = (swellDirection + Vector2.new(-swellDirection.Y, swellDirection.X) * (0.08 * side)).Unit
      local component = makeComponent(direction, swellAmplitude * 0.72, swellWavelength, rng() * TWO_PI, 1)
      component.horizontalAmplitude = component.amplitude * preset.choppiness * 0.38
      table.insert(components, component)
    end
  end

  -- Order for capped LODs: required long waves first, then dominant energy.
  -- Full gameplay/LOD0 sampling still uses every generated component.
  table.sort(components, function(a, b)
    local tierA = a.minRenderTier or 1
    local tierB = b.minRenderTier or 1
    if tierA ~= tierB then return tierA < tierB end
    if a.wavelength ~= b.wavelength then return a.wavelength > b.wavelength end
    return a.energy > b.energy
  end)

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

function SpectrumGenerator.Summarize(components: {OceanTypes.WaveComponent}): {[string]: number}
  local wavelengths = {}
  local variance = 0
  local steepness = 0
  for _, component in ipairs(components) do
    table.insert(wavelengths, component.wavelength)
    variance += component.amplitude * component.amplitude * 0.5
    steepness += component.waveNumber * math.abs(component.horizontalAmplitude)
  end
  table.sort(wavelengths)
  local count = #wavelengths
  local minimum = count > 0 and wavelengths[1] or 0
  local maximum = count > 0 and wavelengths[count] or 0
  local median = count > 0 and wavelengths[math.floor((count + 1) * 0.5)] or 0
  local periodMinimum = minimum > 0 and math.sqrt(minimum * TWO_PI / Config.WaveGravity) or 0
  local periodMaximum = maximum > 0 and math.sqrt(maximum * TWO_PI / Config.WaveGravity) or 0
  return {
    wavelengthMin = minimum,
    wavelengthMedian = median,
    wavelengthMax = maximum,
    periodMin = periodMinimum,
    periodMax = periodMaximum,
    totalVariance = variance,
    significantHeight = 4 * math.sqrt(math.max(variance, 0)),
    aggregateSteepness = steepness,
    componentCount = count,
  }
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
