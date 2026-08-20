--!strict

local Config = require(script.Parent.OceanConfig)

local OceanRendererTests = {}

local function included(level: number, i: number, j: number, innerHalf: number): boolean
  if level == 0 then return true end
  return math.max(math.abs(i + 0.5), math.abs(j + 0.5)) >= innerHalf
end

local function checkProfile(profile): (boolean, string, number, number)
  local outerHalf = math.floor((profile.resolution - 1) * 0.5)
  local previousExtent = 0
  local cellsByLevel = 0
  for level = 0, profile.ringCount - 1 do
    local innerHalf = level == 0 and 0 or outerHalf * 0.5
    if level > 0 then
      local boundary = innerHalf * profile.spacing * 2 ^ level
      if math.abs(boundary - previousExtent) > 0.001 then
        return false, "shared boundary mismatch", cellsByLevel, level
      end
    end
    previousExtent = outerHalf * profile.spacing * 2 ^ level
    local count = 0
    for j = -outerHalf, outerHalf - 1 do
      for i = -outerHalf, outerHalf - 1 do
        if included(level, i, j, innerHalf) then
          count += 1
          if included(level, -i - 1, j, innerHalf) ~= included(level, i, j, innerHalf)
            or included(level, i, -j - 1, innerHalf) ~= included(level, i, j, innerHalf) then
            return false, "asymmetric cell-center donut", cellsByLevel, level
          end
        end
      end
    end
    if count <= 0 then return false, "empty ring", cellsByLevel, level end
    cellsByLevel += count
  end
  return true, "ok", cellsByLevel, profile.ringCount
end

function OceanRendererTests.Run(): {[string]: any}
  local failures = {}
  local totalCells = 0
  local levels = 0
  for name, profile in pairs(Config.QualityProfiles) do
    if name ~= "Fallback" then
      local ok, reason, cells, ringCount = checkProfile(profile)
      totalCells += cells
      levels += ringCount
      if not ok then table.insert(failures, name .. ": " .. reason) end
    end
  end
  return {
    passed = #failures == 0,
    failures = failures,
    totalCells = totalCells,
    levels = levels,
    seamTolerance = 0.02,
    normalToleranceDegrees = 1,
  }
end

return OceanRendererTests
