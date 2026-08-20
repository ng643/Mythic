--!strict

local OceanTypes = require(script.Parent.OceanTypes)

local Config = {
  WaveGravity = 35.04,
  WorldGravity = 196.2,
  MetersToStuds = 1 / 0.28,
  MaxAggregateSteepness = 0.82,
  FoamJacobianThreshold = 0.82,
  FoamJacobianGain = 2.4,
  -- Height contribution keeps whitecaps readable on the low-poly fallback path.
  FoamHeightStart = 0.8,
  FoamHeightGain = 0.5,
  DefaultSeaLevel = 0,
  DefaultPreset = "Trade Sea",
  DefaultQuality = "High",
  MaxEventsPerSample = 4,
  StateVersion = 1,
  QualityProfiles = {
    Ultra = {resolution = 65, spacing = 3, ringCount = 6, nearCadence = 60, waveCap = 14, normalRings = 3, foamCap = 128},
    High = {resolution = 49, spacing = 4, ringCount = 6, nearCadence = 60, waveCap = 12, normalRings = 2, foamCap = 80},
    Medium = {resolution = 33, spacing = 6, ringCount = 5, nearCadence = 40, waveCap = 9, normalRings = 1, foamCap = 40},
    Low = {resolution = 25, spacing = 8, ringCount = 4, nearCadence = 24, waveCap = 6, normalRings = 0, foamCap = 16},
    Fallback = {resolution = 0, spacing = 0, ringCount = 0, nearCadence = 0, waveCap = 0, normalRings = 0, foamCap = 0},
  },
}

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
