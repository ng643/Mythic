--!strict

local OceanTypes = require(script.Parent.OceanTypes)

local Config = {
  WaveGravity = 35.04,
  WorldGravity = 196.2,
  MetersToStuds = 1 / 0.28,
  MaxAggregateSteepness = 0.82,
  FoamJacobianThreshold = 0.12,
  FoamJacobianGain = 8,
  FoamThresholdRange = 0.105,
  FoamHeightStart = 0.45,
  FoamHeightGain = 0.10,
  FoamSlopeGain = 1.8,
  FoamUpwardMotionWeight = 0.72,
  FoamForwardMotionWeight = 0.20,
  FoamMotionGain = 0.12,
  FoamCrestHeightWeight = 1.15,
  FoamCrestMotionWeight = 1.10,
  FoamPersistenceCrestWeight = 0.65,
  FoamPersistenceCompressionWeight = 0.45,
  FoamPersistenceMotionWeight = 0.25,
  FoamCompressionWeight = 0.62,
  FoamSlopeWeight = 0.24,
  FoamMotionWeight = 0.14,
  FoamPersistenceWeight = 0.12,
  DefaultSeaLevel = 0,
  DefaultPreset = "Trade Sea",
  DefaultQuality = "High",
  MaxEventsPerSample = 4,
  StateVersion = 1,
  QualityProfiles = {
    Ultra = {
      resolution = 41,
      spacing = 3,
      ringCount = 5,
      ringResolutions = {41, 21, 17, 17, 17},
      ringExtents = {60, 120, 240, 480, 960},
      nearCadence = 45,
      waveCap = 12,
      normalRings = 2,
      foamCap = 96,
      horizonRange = 6000,
      horizonTileSize = 1800,
      horizonCadence = 0.75,
      transitionWidth = 768,
      transitionSpacing = 160,
      transitionWaveCap = 6,
      transitionCadence = 0.12,
    },
    High = {
      resolution = 31,
      spacing = 4,
      ringCount = 5,
      ringResolutions = {31, 17, 17, 17, 17},
      ringExtents = {60, 120, 240, 480, 960},
      nearCadence = 45,
      waveCap = 10,
      normalRings = 1,
      foamCap = 64,
      horizonRange = 6000,
      horizonTileSize = 1800,
      horizonCadence = 0.75,
      transitionWidth = 768,
      transitionSpacing = 160,
      transitionWaveCap = 6,
      transitionCadence = 0.12,
    },
    Medium = {
      resolution = 25,
      spacing = 6,
      ringCount = 4,
      ringResolutions = {25, 17, 17, 17},
      ringExtents = {72, 144, 288, 576},
      nearCadence = 30,
      waveCap = 8,
      normalRings = 1,
      foamCap = 40,
      horizonRange = 6000,
      horizonTileSize = 1800,
      horizonCadence = 1,
      transitionWidth = 720,
      transitionSpacing = 144,
      transitionWaveCap = 6,
      transitionCadence = 0.16,
    },
    Low = {
      resolution = 21,
      spacing = 8,
      ringCount = 4,
      ringResolutions = {21, 15, 15, 15},
      ringExtents = {80, 160, 320, 640},
      nearCadence = 24,
      waveCap = 6,
      normalRings = 0,
      foamCap = 16,
      horizonRange = 6000,
      horizonTileSize = 1800,
      horizonCadence = 1.25,
      transitionWidth = 640,
      transitionSpacing = 160,
      transitionWaveCap = 5,
      transitionCadence = 0.2,
    },
    Fallback = {
      resolution = 0,
      spacing = 0,
      ringCount = 0,
      ringResolutions = {},
      ringExtents = {},
      nearCadence = 0,
      waveCap = 0,
      normalRings = 0,
      foamCap = 0,
      horizonRange = 0,
      horizonTileSize = 0,
      horizonCadence = 0,
      transitionWidth = 0,
      transitionSpacing = 0,
      transitionWaveCap = 0,
      transitionCadence = 0,
    },
  },
}

function Config.TargetAggregateSteepness(preset: OceanTypes.OceanPreset): number
  local hsRatio = math.clamp(preset.significantWaveHeightMeters / 1.7, 0, 1)
  local storm = math.clamp(preset.stormIntensity, 0, 1)
  return math.clamp(0.045 + hsRatio * 0.16 + storm ^ 0.8 * 0.26, 0.03, Config.MaxAggregateSteepness)
end

function Config.FoamThresholdForPreset(preset: OceanTypes.OceanPreset): number
  local amount = math.clamp(preset.foamAmount, 0, 1)
  local storm = math.clamp(preset.stormIntensity, 0, 1)
  local intensity = amount * 0.72 + storm * 0.28
  return math.clamp(
    Config.FoamJacobianThreshold - intensity * Config.FoamThresholdRange,
    0.01,
    Config.FoamJacobianThreshold
  )
end

function Config.FoamIntensityFromThreshold(threshold: number): number
  return math.clamp(
    (Config.FoamJacobianThreshold - threshold) / math.max(Config.FoamThresholdRange, 1e-4),
    0,
    1
  )
end

function Config.IsFinite(value: number): boolean
  return value == value and value > -math.huge and value < math.huge
end

function Config.ClampFinite(value: number, minimum: number, maximum: number, fallback: number): number
  if not Config.IsFinite(value) then
    return fallback
  end
  return math.clamp(value, minimum, maximum)
end

function Config.NormalizeDirection(direction: Vector2, fallback: Vector2): Vector2
  if direction.Magnitude < 1e-5 then
    return fallback
  end
  return direction.Unit
end

function Config.ValidatePreset(preset: any): (boolean, string?)
  if type(preset) ~= "table" then
    return false, "preset must be a table"
  end
  local numericFields = {
    "significantWaveHeightMeters", "peakPeriodSeconds", "windSpeedMetersPerSecond",
    "windDirectionDegrees", "directionalSpreadDegrees", "swellHeightMeters",
    "swellPeriodSeconds", "swellDirectionDegrees", "choppiness", "foamAmount",
    "roughness", "stormIntensity",
  }
  for _, field in ipairs(numericFields) do
    if type(preset[field]) ~= "number" or not Config.IsFinite(preset[field]) then
      return false, field .. " must be finite"
    end
  end
  if preset.significantWaveHeightMeters <= 0 or preset.peakPeriodSeconds <= 0 then
    return false, "wave height and peak period must be positive"
  end
  if preset.swellHeightMeters < 0 or preset.swellPeriodSeconds <= 0 then
    return false, "swell values are invalid"
  end
  if preset.directionalSpreadDegrees < 0 or preset.directionalSpreadDegrees > 180 then
    return false, "directional spread is outside 0..180"
  end
  if preset.choppiness < 0 or preset.choppiness > 1.5 then
    return false, "choppiness is outside safe range"
  end
  return true
end

return Config
