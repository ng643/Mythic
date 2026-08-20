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

local function directionFromDegrees(degrees: number): Vector2
  local radians = math.rad(degrees)
  return Vector2.new(math.cos(radians), math.sin(radians)).Unit
end

local function makeComponent(direction: Vector2, amplitude: number, wavelength: number, phase: number, minRenderTier: number): OceanTypes.WaveComponent
  local safeWavelength = math.max(wavelength, 0.1)
  local waveNumber = TWO_PI / safeWavelength
  return {
    direction = direction.Unit,
    amplitude = amplitude,
    wavelength = safeWavelength,
    waveNumber = waveNumber,
    angularFrequency = math.sqrt(Config.WaveGravity * waveNumber),
    horizontalAmplitude = 0,
    phase = phase % TWO_PI,
    energy = amplitude * amplitude * 0.5,
    minRenderTier = minRenderTier,
  }
end

local function clampSeparated(first: number, second: number): (number, number)
  if math.abs(first - second) < 12 then
    first = math.min(150, second + 18)
  end
  return first, second
end

function SpectrumGenerator.Generate(preset: OceanTypes.OceanPreset, seed: number, maxSteepness: number?): {OceanTypes.WaveComponent}
  local valid, reason = Config.ValidatePreset(preset)
  if not valid then error(reason) end

  local rng = makeRng(seed)
  local peakWavelength = Config.WaveGravity * preset.peakPeriodSeconds ^ 2 / TWO_PI
  local swellWavelength = Config.WaveGravity * preset.swellPeriodSeconds ^ 2 / TWO_PI
  local windWavelengthA = math.clamp(peakWavelength * 0.34, 70, 140)
  local windWavelengthB = math.clamp(peakWavelength * 0.22, 70, 125)
  windWavelengthA, windWavelengthB = clampSeparated(windWavelengthA, windWavelengthB)
  local longSwell = math.max(80, swellWavelength)
  local secondarySwell = math.max(70, longSwell * 0.78)
  local windAngle = preset.windDirectionDegrees
  local swellAngle = preset.swellDirectionDegrees
  local storm = math.clamp(preset.stormIntensity, 0, 1)
  local spread = math.clamp(preset.directionalSpreadDegrees, 0, 180)

  local roles = {
    {band = "swell", wavelength = longSwell, weight = 0.25, direction = swellAngle, q = 0.42, tier = 1},
    {band = "swell", wavelength = secondarySwell, weight = 0.18, direction = swellAngle + 8, q = 0.46, tier = 1},
    {band = "wind", wavelength = peakWavelength, weight = 0.28, direction = windAngle, q = 0.74, tier = 1},
    {band = "wind", wavelength = windWavelengthA, weight = 0.15, direction = windAngle + math.min(18, spread * 0.35), q = 0.82, tier = 1},
    {band = "wind", wavelength = windWavelengthB, weight = 0.14, direction = windAngle + math.min(30, spread * 0.65), q = 0.84, tier = 1},
  }
  if storm >= 0.35 then
    table.insert(roles, {
      band = "cross",
      wavelength = math.max(110, windWavelengthA * 1.18),
      weight = 0.10 + storm * 0.05,
      direction = windAngle + 72 + storm * 18,
      q = 0.82,
      tier = 1,
    })
  end

  local totalWeight = 0
  for _, role in ipairs(roles) do totalWeight += role.weight end
  local targetHsStuds = preset.significantWaveHeightMeters * Config.MetersToStuds
  local targetM0 = (targetHsStuds * 0.25) ^ 2
  local components = {}
  local aggregateSteepness = 0
  for _, role in ipairs(roles) do
    local amplitude = math.sqrt(2 * targetM0 * (role.weight / totalWeight))
    local component = makeComponent(
      directionFromDegrees(role.direction + (rng() - 0.5) * math.min(spread * 0.18, 8)),
      amplitude,
      role.wavelength,
      rng() * TWO_PI,
      role.tier
    )
    component.horizontalAmplitude = amplitude * preset.choppiness * role.q
    aggregateSteepness += component.waveNumber * math.abs(component.horizontalAmplitude)
    table.insert(components, component)
  end

  local targetSteepness = math.min(Config.TargetAggregateSteepness(preset), maxSteepness or Config.MaxAggregateSteepness)
  local normalizer = aggregateSteepness > 1e-6 and targetSteepness / aggregateSteepness or 1
  for _, component in ipairs(components) do
    component.horizontalAmplitude *= normalizer
  end

  table.sort(components, function(a, b)
    local tierA = a.minRenderTier or 1
    local tierB = b.minRenderTier or 1
    if tierA ~= tierB then return tierA < tierB end
    return a.wavelength > b.wavelength
  end)
  return components
end

function SpectrumGenerator.Summarize(components: {OceanTypes.WaveComponent}, targetHsStuds: number?, targetSteepness: number?): {[string]: number}
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
  local measuredHs = 4 * math.sqrt(math.max(variance, 0))
  local summary: {[string]: number} = {
    wavelengthMin = minimum,
    wavelengthMedian = median,
    wavelengthMax = maximum,
    periodMin = periodMinimum,
    periodMax = periodMaximum,
    totalVariance = variance,
    significantHeight = measuredHs,
    aggregateSteepness = steepness,
    componentCount = count,
  }
  if targetHsStuds then
    summary.targetSignificantHeight = targetHsStuds
    summary.hsError = measuredHs - targetHsStuds
    summary.hsErrorRatio = math.abs(summary.hsError) / math.max(targetHsStuds, 1e-6)
  end
  if targetSteepness then
    summary.targetAggregateSteepness = targetSteepness
    summary.steepnessError = steepness - targetSteepness
  end
  return summary
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
    foamThreshold = Config.FoamThresholdForPreset(preset),
    windWorld = Vector3.new(math.cos(math.rad(preset.windDirectionDegrees)), 0, math.sin(math.rad(preset.windDirectionDegrees))) * preset.windSpeedMetersPerSecond * Config.MetersToStuds,
    stormIntensity = preset.stormIntensity,
    disturbances = {},
  }
end

return SpectrumGenerator
