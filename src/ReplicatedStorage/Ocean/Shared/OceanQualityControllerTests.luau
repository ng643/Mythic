--!strict

local qualitySource = game.StarterPlayer.StarterPlayerScripts.OceanClient.OceanQualityController
local qualityProbe = qualitySource:Clone()
qualityProbe.Name = "OceanQualityControllerTestsDependency"
qualityProbe.Parent = qualitySource.Parent
local OceanQualityController = require(qualityProbe)

local OceanQualityControllerTests = {}

function OceanQualityControllerTests.Run(): {[string]: any}
  local attributes: {[string]: any} = {}
  local runtime = {}
  function runtime:GetAttribute(name: string): any
    return attributes[name]
  end
  function runtime:SetAttribute(name: string, value: any)
    attributes[name] = value
  end

  local renderer = {
    qualityName = "High",
    setCalls = 0,
    buildCalls = 0,
  }
  function renderer:SetQuality(name: string)
    self.setCalls += 1
    return {topologyChanged = false}
  end

  local controller = OceanQualityController.new(renderer, runtime)
  local failures = {}
  local changed = controller:_Set("Medium", "regression")
  if not changed then table.insert(failures, "first quality change rejected") end
  if renderer.setCalls ~= 1 then table.insert(failures, "first change did not call SetQuality once") end
  if attributes.OceanQuality ~= "Medium" then table.insert(failures, "quality attribute not published") end
  if attributes.OceanQualityTopologyChanged ~= false then table.insert(failures, "topology change flag incorrect") end
  local duplicate = controller:_Set("Medium", "duplicate")
  if duplicate then table.insert(failures, "duplicate quality change accepted") end
  if renderer.setCalls ~= 1 then table.insert(failures, "duplicate invoked SetQuality") end
  local fallbackOk = controller:SetOverride("Fallback")
  if fallbackOk then table.insert(failures, "Fallback override accepted") end
  if renderer.buildCalls ~= 0 then table.insert(failures, "renderer build was invoked") end
  qualityProbe:Destroy()
  return {
    passed = #failures == 0,
    failures = failures,
    setCalls = renderer.setCalls,
    buildCalls = renderer.buildCalls,
    topologyChanged = attributes.OceanQualityTopologyChanged,
  }
end

return OceanQualityControllerTests
