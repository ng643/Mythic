--!strict

local Workspace = game:GetService("Workspace")

local Tests = {}

function Tests.Run(waveField, rendererModule): {[string]: any}
  local runtime = Workspace:FindFirstChild("OceanRuntime")
  local created = false
  if not runtime then
    runtime = Instance.new("Folder")
    runtime.Name = "OceanRuntime"
    runtime.Parent = Workspace
    created = true
  end
  runtime:ClearAllChildren()
  for name in pairs(runtime:GetAttributes()) do runtime:SetAttribute(name, nil) end
  local renderer = rendererModule.new(waveField)
  renderer:SetQuality("High")
  local ok, reason = pcall(function() renderer:_Build() end)
  local stats = renderer:GetStats()
  local nearPart = renderer.rings[1] and renderer.rings[1].part
  local passed = ok
    and not stats.fallback
    and stats.ringCount == 1
    and nearPart ~= nil
    and nearPart.Material == Enum.Material.Glass
    and runtime:GetAttribute("OceanMaterialPath") == "Glass"
  local result = {
    passed = passed,
    buildOk = ok,
    buildError = tostring(reason),
    fallback = stats.fallback,
    ringCount = stats.ringCount,
    vertexCount = stats.vertexCount,
    material = nearPart and nearPart.Material.Name or "None",
    materialPath = runtime:GetAttribute("OceanMaterialPath"),
  }
  renderer:Stop()
  if created then runtime:Destroy() end
  return result
end

return Tests
