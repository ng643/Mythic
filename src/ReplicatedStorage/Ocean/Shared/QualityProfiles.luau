--!strict

local Config = require(script.Parent.OceanConfig)

local QualityProfiles = {}

function QualityProfiles.Get(name: string)
  return Config.QualityProfiles[name] or Config.QualityProfiles[Config.DefaultQuality]
end

function QualityProfiles.Names(): {string}
  local names = {}
  for name in pairs(Config.QualityProfiles) do
    table.insert(names, name)
  end
  table.sort(names)
  return names
end

return QualityProfiles
