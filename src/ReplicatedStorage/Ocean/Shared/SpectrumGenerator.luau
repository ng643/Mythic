--!strict

local Config = require(script.Parent.OceanConfig)
local OceanTypes = require(script.Parent.OceanTypes)

local SpectrumGenerator = {}
local TWO_PI = math.pi * 2

type SpectralRecord = {
  band: string,
  wavelength: number,
  weight: number,
  direction: Vector2,
  phase: number,
  minRenderTier: number,
}

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
  return (rng() * 2 - 1) * spreadDegrees
end

local function makeComponent(
  direction: Vector2,
  amplitude: number,
  wavelength: number,
  phase: number,
  minRenderTier: number?
): OceanTypes.WaveComponent
  local safeWavelength = math.max(wavelength, 0.1)
  local waveNumber = TWO_PI / safeWavelength
  local angularFrequency = math.sqrt(Config.WaveGravity * waveNumber)
  return {
    direction = direction.Unit,
    amplitude = amplitude,
    wavelength = safeWavelength,
    waveNumber = waveNumber,
    angularFrequency = angularFrequency,
    horizontalAmplitude = 0,
    phase = phase % TWO_PI,
    energy = amplitude * amplitude * 0.5,
    minRenderTier = minRenderTier,
  }
end

local function appendRecord(
  records: {SpectralRecord},
  band: string,
  wavelength: number,
  weight: number,
  direction: Vector2,
  phase: number,
  minRenderTier: number
)
  table.insert(records, {
    band = band,
    wavelength = wavelength,
    weight = math.max(weight, 1e-5),
    direction = direction,
    phase = phase,
    minRenderTier = minRenderTier,
  })
end

function SpectrumGenerator.Generate(preset: OceanTypes.OceanPreset, seed: number, maxSteepness: number?): {OceanTypes.WaveComponent}
  local ok, reason = Config.ValidatePreset(preset)
  if not ok then
    error(reason)
  end

  local rng = makeRng(seed)
  local records: {SpectralRecord} = {}
  local storm = math.clamp(preset.stormIntensity, 0, 1)
  local spread = math.clamp(preset.directionalSpreadDegrees, 0, 180)
  local peakWavelength = Config.WaveGravity * preset.peakPeriodSeconds ^ 2 / TWO_PI
  local swellWavelength = Config.WaveGravity * preset.swellPeriodSeconds ^ 2 / TWO_PI
  local windAngle = preset.windDirectionDegrees
  local swellAngle = preset.swellDirectionDegrees
  local crossAngle = 24 + 42 * storm

  -- Three long-swell components retain the exact requested swell wavelength
  -- in the center while the side components provide a non-synchronous crest
  -- profile. A no-swell custom preset still receives an explicit long band.
  local longBase = preset.swellHeightMeters > 0 and swellWavelength or math.max(120, peakWavelength * 1.85)
  local swellFactors = {0.82, 1, 1.23}
  local swellWeights = {0.82, 1.08, 0.76}
  for index = 1, 3 do
    local wavelength = index == 2 and longBase or math.max(20, longBase * swellFactors[index])
    local side = index - 2
    local angle = swellAngle
      + side * math.min(9, 2 + spread * 0.10)
      + directionalOffset(rng, math.min(8, spread * 0.12))
    appendRecord(
      records,
      "long",
      wavelength,
      swellWeights[index] * (0.9 + rng() * 0.2),
      degreesToDirection(angle),
      rng() * TWO_PI,
      1
    )
  end

  -- Five dominant wind-sea components are log-spaced around the exact peak.
  -- In storms, two deterministic members turn across the wind to guarantee
  -- cross-sea energy without introducing frame-time randomness.
  local windFactors = {0.58, 0.78, 1, 1.27, 1.62}
  local windWeights = {0.74, 0.96, 1.22, 1.00, 0.68}
  for index = 1, 5 do
    local wavelength = index == 3 and peakWavelength or math.max(20, peakWavelength * windFactors[index])
    local angle = windAngle + directionalOffset(rng, spread * 0.72)
    local weight = windWeights[index] * (0.88 + rng() * 0.24)
    if storm > 0.08 and (index == 2 or index == 4) then
      local side = index == 2 and -1 or 1
      angle += side * crossAngle
      weight *= 0.72 + storm * 0.45
    end
    appendRecord(records, "wind", wavelength, weight, degreesToDirection(angle), rng() * TWO_PI, 1)
  end

  -- A six-member 20-120 stud tail supplies readable L0/L1 silhouettes. Its
  -- energy remains lower than the wind sea, but grows intentionally in storms.
  local shortWavelengths = {20, 28, 40, 56, 78, 108}
  local shortWeights = {0.42, 0.68, 0.95, 0.88, 0.64, 0.36}
  for index, baseWavelength in ipairs(shortWavelengths) do
    local jitter = 0.94 + rng() * 0.12
    local wavelength = math.clamp(baseWavelength * jitter, 20, 120)
    local angle = windAngle + directionalOffset(rng, math.min(52, spread + 12))
    local weight = shortWeights[index] * (0.88 + rng() * 0.24) * (0.9 + storm * 0.45)
    if storm > 0.22 and (index == 2 or index == 5) then
      local side = index == 2 and 1 or -1
      angle += side * (crossAngle + 8)
      weight *= 0.74 + storm * 0.42
    end
    appendRecord(records, "short", wavelength, weight, degreesToDirection(angle), rng() * TWO_PI, 2)
  end

  -- Normalize vertical energy by band. This keeps Hs exact even though the
  -- artistic spectrum deliberately moves energy into the short/mid tail.
  local targetHsStuds = preset.significantWaveHeightMeters * Config.MetersToStuds
  local targetM0 = (targetHsStuds * 0.25) ^ 2
  local swellRatio = preset.swellHeightMeters / math.max(preset.significantWaveHeightMeters, 1e-4)
  local longFraction = math.clamp(0.10 + swellRatio * swellRatio * 0.60, 0.10, 0.28)
  local shortFraction = math.clamp(0.055 + storm * 0.085, 0.055, 0.14)
  local bandFraction: {[string]: number} = {
    long = longFraction,
    short = shortFraction,
    wind = math.max(0.1, 1 - longFraction - shortFraction),
  }
  local bandWeight: {[string]: number} = {long = 0, wind = 0, short = 0}
  for _, record in ipairs(records) do
    bandWeight[record.band] += record.weight
  end

  local targetSteepness = Config.TargetAggregateSteepness(preset)
  local bandRatio: {[string]: number} = {
    long = preset.choppiness * (0.45 + storm * 0.12),
    wind = preset.choppiness * (0.72 + storm * 0.18),
    short = preset.choppiness * (0.85 + storm * 0.25),
  }
  local aggregate = 0
  local components: {OceanTypes.WaveComponent} = {}
  for _, record in ipairs(records) do
    local fraction = bandFraction[record.band]
    local amplitude = math.sqrt(2 * targetM0 * fraction * record.weight / math.max(bandWeight[record.band], 1e-6))
    local component = makeComponent(record.direction, amplitude, record.wavelength, record.phase, record.minRenderTier)
    component.horizontalAmplitude = amplitude * bandRatio[record.band]
    aggregate += component.waveNumber * math.abs(component.horizontalAmplitude)
    table.insert(components, component)
  end

  -- The band ratios establish distinct horizontal behavior; this final
  -- normalization only places their aggregate in the preset's readable
  -- target range and enforces the no-fold safety ceiling.
  local requestedSteepness = math.min(targetSteepness, maxSteepness or Config.MaxAggregateSteepness)
  local normalizer = aggregate > 1e-6 and requestedSteepness / aggregate or 1
  for _, component in ipairs(components) do
    component.horizontalAmplitude *= normalizer
  end

  -- Capped LODs receive long waves first, then dominant wind-sea, then the
  -- explicit short/mid tail. L0/gameplay still consume all 14 components.
  table.sort(components, function(a, b)
    local tierA = a.minRenderTier or 1
    local tierB = b.minRenderTier or 1
    if tierA ~= tierB then return tierA < tierB end
    if a.wavelength ~= b.wavelength then return a.wavelength > b.wavelength end
    return a.energy > b.energy
  end)
  return components
end

function SpectrumGenerator.Summarize(
  components: {OceanTypes.WaveComponent},
  targetHsStuds: number?,
  targetSteepness: number?
): {[string]: number}
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
