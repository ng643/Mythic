--!strict

local OceanTypes = require(script.Parent.OceanTypes)

local presets: {[string]: OceanTypes.OceanPreset} = {
  ["Glass Harbour"] = {
    name = "Glass Harbour",
    significantWaveHeightMeters = 0.25,
    peakPeriodSeconds = 4,
    windSpeedMetersPerSecond = 3,
    windDirectionDegrees = 0,
    directionalSpreadDegrees = 55,
    swellHeightMeters = 0.08,
    swellPeriodSeconds = 5,
    swellDirectionDegrees = 20,
    choppiness = 0.25,
    foamAmount = 0.1,
    waterColor = Color3.fromRGB(16, 92, 116),
    horizonColor = Color3.fromRGB(110, 164, 184),
    roughness = 0.18,
    stormIntensity = 0,
  },
  ["Calm Open Sea"] = {
    name = "Calm Open Sea",
    significantWaveHeightMeters = 0.75,
    peakPeriodSeconds = 6,
    windSpeedMetersPerSecond = 7,
    windDirectionDegrees = 15,
    directionalSpreadDegrees = 42,
    swellHeightMeters = 0.35,
    swellPeriodSeconds = 8,
    swellDirectionDegrees = 35,
    choppiness = 0.55,
    foamAmount = 0.2,
    waterColor = Color3.fromRGB(8, 70, 94),
    horizonColor = Color3.fromRGB(94, 150, 174),
    roughness = 0.13,
    stormIntensity = 0.05,
  },
  ["Trade Sea"] = {
    name = "Trade Sea",
    significantWaveHeightMeters = 1.7,
    peakPeriodSeconds = 8.5,
    windSpeedMetersPerSecond = 12,
    windDirectionDegrees = 25,
    directionalSpreadDegrees = 28,
    swellHeightMeters = 0.8,
    swellPeriodSeconds = 11,
    swellDirectionDegrees = 42,
    choppiness = 0.8,
    foamAmount = 0.42,
    waterColor = Color3.fromRGB(5, 62, 86),
    horizonColor = Color3.fromRGB(74, 133, 160),
    roughness = 0.1,
    stormIntensity = 0.2,
  },
  ["Gale"] = {
    name = "Gale",
    significantWaveHeightMeters = 3.4,
    peakPeriodSeconds = 11,
    windSpeedMetersPerSecond = 18,
    windDirectionDegrees = 35,
    directionalSpreadDegrees = 22,
    swellHeightMeters = 1.3,
    swellPeriodSeconds = 14,
    swellDirectionDegrees = 55,
    choppiness = 0.95,
    foamAmount = 0.72,
    waterColor = Color3.fromRGB(4, 44, 66),
    horizonColor = Color3.fromRGB(70, 103, 122),
    roughness = 0.16,
    stormIntensity = 0.65,
  },
  ["Mythic Storm"] = {
    name = "Mythic Storm",
    significantWaveHeightMeters = 5.2,
    peakPeriodSeconds = 13,
    windSpeedMetersPerSecond = 24,
    windDirectionDegrees = 45,
    directionalSpreadDegrees = 18,
    swellHeightMeters = 2.4,
    swellPeriodSeconds = 18,
    swellDirectionDegrees = 68,
    choppiness = 1,
    foamAmount = 1,
    waterColor = Color3.fromRGB(3, 28, 45),
    horizonColor = Color3.fromRGB(45, 65, 82),
    roughness = 0.22,
    stormIntensity = 1,
  },
}

local Presets = {}

function Presets.Get(name: string): OceanTypes.OceanPreset
  return presets[name] or presets["Trade Sea"]
end

function Presets.List(): {string}
  local names = {}
  for name in pairs(presets) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

function Presets.All(): {[string]: OceanTypes.OceanPreset}
  return presets
end

return Presets
