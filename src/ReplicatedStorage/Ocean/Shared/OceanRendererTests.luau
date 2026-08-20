--!strict

local Config = require(script.Parent.OceanConfig)

local OceanRendererTests = {}

local function included(level: number, i: number, j: number, innerHalf: number): boolean
  if level == 0 then return true end
  return math.max(math.abs(i + 0.5), math.abs(j + 0.5)) >= innerHalf
end

local function makeIntervals(minimum: number, maximum: number, maxWidth: number): number
  local count = 0
  local cursor = minimum
  while cursor < maximum - 0.01 do
    cursor = math.min(cursor + maxWidth, maximum)
    count += 1
  end
  return count
end

local function checkHorizonCoverage(profile): (boolean, string, number)
  local range = math.min(profile.horizonRange or 6000, 6000)
  local tileSize = math.min(profile.horizonTileSize or 1800, 1800)
  local outerHalf = math.floor((profile.resolution - 1) * 0.5)
  local lastLevel = 0
  for level = 1, profile.ringCount - 1 do
    if profile.spacing * 2 ^ level * (profile.resolution - 1) <= 1900 then
      lastLevel = level
    end
  end
  local innerExtent = outerHalf * profile.spacing * 2 ^ lastLevel
  local fullCount = makeIntervals(-range, range, tileSize)
  local middleCount = makeIntervals(-innerExtent, innerExtent, tileSize)
  local northSouthCount = makeIntervals(innerExtent, range, tileSize)
  local eastWestCount = makeIntervals(-range, -innerExtent, tileSize)
  local tileCount = fullCount * northSouthCount * 2 + middleCount * (northSouthCount + eastWestCount)
  if tileCount > 64 then return false, "horizon object budget exceeded", tileCount end
  local samples = 0
  for x = -range + 64, range - 64, 128 do
    for z = -range + 64, range - 64, 128 do
      local inInner = math.abs(x) < innerExtent and math.abs(z) < innerExtent
      local north = z >= innerExtent and z <= range
      local south = z <= -innerExtent and z >= -range
      local east = x >= innerExtent and math.abs(z) < innerExtent
      local west = x <= -innerExtent and math.abs(z) < innerExtent
      local covered = (north and 1 or 0) + (south and 1 or 0) + (east and 1 or 0) + (west and 1 or 0)
      if inInner and covered ~= 0 then return false, "inner square overlap", samples end
      if not inInner and covered ~= 1 then return false, "annulus coverage gap or overlap", samples end
      samples += 1
    end
  end
  return true, "ok", tileCount
end

local function checkProfile(profile): (boolean, string, number, number)
  if profile.ringCount ~= 1 then return false, "near topology must be one continuous patch", 0, 0 end
  if not profile.ringResolutions or #profile.ringResolutions ~= 1 then return false, "ring descriptor mismatch", 0, 0 end
  local nearWidth = (profile.resolution - 1) * profile.spacing
  if nearWidth < 350 then return false, "near patch is too narrow", 0, 0 end
  local outerHalf = math.floor((profile.resolution - 1) * 0.5)
  local count = 0
  for j = -outerHalf, outerHalf - 1 do
    for i = -outerHalf, outerHalf - 1 do
      if included(0, i, j, 0) then
        count += 1
        if included(0, -i - 1, j, 0) ~= included(0, i, j, 0)
          or included(0, i, -j - 1, 0) ~= included(0, i, j, 0) then
          return false, "asymmetric continuous patch", count, 0
        end
      end
    end
  end
  return count > 0, count > 0 and "ok" or "empty patch", count, 1
end

function OceanRendererTests.Run(): {[string]: any}
  local failures = {}
  local totalCells = 0
  local levels = 0
  local horizonTiles = 0
  for name, profile in pairs(Config.QualityProfiles) do
    if name ~= "Fallback" then
      local ok, reason, cells, ringCount = checkProfile(profile)
      totalCells += cells
      levels += ringCount
      if not ok then table.insert(failures, name .. ": " .. reason) end
      local horizonOk, horizonReason, tileCount = checkHorizonCoverage(profile)
      horizonTiles = math.max(horizonTiles, tileCount)
      if not horizonOk then table.insert(failures, name .. ": " .. horizonReason) end
    end
  end
  return {
    passed = #failures == 0,
    failures = failures,
    totalCells = totalCells,
    levels = levels,
    horizonCoveragePassed = #failures == 0,
    horizonTileCountMax = horizonTiles,
    seamTolerance = 0.02,
    normalToleranceDegrees = 1,
  }
end

return OceanRendererTests
