--!strict

local AssetService = game:GetService("AssetService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local GRID_SIDE = 33
local CELL_COUNT = GRID_SIDE - 1
local SPACING = 4
local WIDTH = CELL_COUNT * SPACING
local VERTEX_COUNT = GRID_SIDE * GRID_SIDE
local TWO_PI = math.pi * 2

type Wave = {
  direction: Vector2,
  amplitude: number,
  horizontalAmplitude: number,
  waveNumber: number,
  angularFrequency: number,
  phase: number,
}

local waves: {Wave} = {
  {
    direction = Vector2.new(1, 0).Unit,
    amplitude = 1.8,
    horizontalAmplitude = 0.35,
    waveNumber = TWO_PI / 72,
    angularFrequency = math.sqrt(35.04 * (TWO_PI / 72)),
    phase = 0.0,
  },
  {
    direction = Vector2.new(0.72, 0.69).Unit,
    amplitude = 0.9,
    horizontalAmplitude = 0.18,
    waveNumber = TWO_PI / 38,
    angularFrequency = math.sqrt(35.04 * (TWO_PI / 38)),
    phase = 1.1,
  },
  {
    direction = Vector2.new(-0.35, 0.94).Unit,
    amplitude = 0.45,
    horizontalAmplitude = 0.08,
    waveNumber = TWO_PI / 20,
    angularFrequency = math.sqrt(35.04 * (TWO_PI / 20)),
    phase = 2.4,
  },
  {
    direction = Vector2.new(0.95, -0.3).Unit,
    amplitude = 0.22,
    horizontalAmplitude = 0.035,
    waveNumber = TWO_PI / 11,
    angularFrequency = math.sqrt(35.04 * (TWO_PI / 11)),
    phase = 4.0,
  },
}

local runtime = Workspace:FindFirstChild("OceanRuntime")
if not runtime then
  runtime = Instance.new("Folder")
  runtime.Name = "OceanRuntime"
  runtime.Parent = Workspace
end

-- The starter place has a placeholder Baseplate at sea level. Hide it locally
-- so troughs and the fallback bake-off are not occluded during this disposable lab.
local placeholderBaseplate = Workspace:FindFirstChild("Baseplate")
if placeholderBaseplate and placeholderBaseplate:IsA("BasePart") then
  placeholderBaseplate.LocalTransparencyModifier = 1
  placeholderBaseplate.Transparency = 1
  local placeholderTexture = placeholderBaseplate:FindFirstChildWhichIsA("Texture")
  if placeholderTexture then
    placeholderTexture.Transparency = 1
  end
end

if runtime:GetAttribute("CapabilityLabMode") == nil then
  runtime:SetAttribute("CapabilityLabMode", "EditableMesh")
end
if runtime:GetAttribute("CapabilityLabBatch") == nil then
  runtime:SetAttribute("CapabilityLabBatch", true)
end

local vertexIds: {number} = table.create(VERTEX_COUNT)
local normalIds: {number} = table.create(VERTEX_COUNT)
local colorIds: {number} = table.create(VERTEX_COUNT)
local labels: {Vector2} = table.create(VERTEX_COUNT)
local positionBuffer: {Vector3} = table.create(VERTEX_COUNT)
local normalBuffer: {Vector3} = table.create(VERTEX_COUNT)

local editableMesh: EditableMesh? = nil
local meshPart: MeshPart? = nil
local fallbackPart: Part? = nil
local updateConnection: RBXScriptConnection? = nil
local modeConnection: RBXScriptConnection? = nil
local batchAvailable = true
local batchErrorReported = false
local frameCount = 0
local accumulatedUpdate = 0
local accumulatedFrames = 0
local reportClock = 0
local elapsed = 0
local terrain = Workspace.Terrain
local terrainWasModified = false
local originalWaterTransparency = terrain.WaterTransparency
local originalWaterWaveSize = terrain.WaterWaveSize
local originalWaterWaveSpeed = terrain.WaterWaveSpeed

local function clearTerrainLabVolume()
  if terrainWasModified then
    terrain:FillBlock(CFrame.new(0, -0.25, 0), Vector3.new(WIDTH, 1, WIDTH), Enum.Material.Air)
    terrainWasModified = false
  end
end

local function setMode(mode: string)
  clearTerrainLabVolume()
  local showCustom = mode == "EditableMesh" or mode == "Hybrid"
  if meshPart then
    meshPart.Transparency = showCustom and 0.03 or 1
  end
  if fallbackPart then
    fallbackPart.Transparency = mode == "Static" and 0.12 or 1
  end
  if mode == "Terrain" or mode == "Hybrid" then
    terrain.WaterTransparency = mode == "Hybrid" and 1 or 0.25
    terrain.WaterWaveSize = 0.15
    terrain.WaterWaveSpeed = 5
    terrain:FillBlock(CFrame.new(0, -0.25, 0), Vector3.new(WIDTH, 1, WIDTH), Enum.Material.Water)
    terrainWasModified = true
  end
  runtime:SetAttribute("CapabilityLabResolvedMode", mode)
  print(string.format("OceanCapabilityLab | mode=%s batch=%s", mode, tostring(batchAvailable)))
end

local function evaluate(label: Vector2, timeSeconds: number): (Vector3, Vector3)
  local position = Vector3.new(label.X, 0, label.Y)
  local tangentX = Vector3.new(1, 0, 0)
  local tangentZ = Vector3.new(0, 0, 1)
  for _, wave in ipairs(waves) do
    local theta = wave.waveNumber * wave.direction:Dot(label) - wave.angularFrequency * timeSeconds + wave.phase
    theta = theta % TWO_PI
    local sinTheta = math.sin(theta)
    local cosTheta = math.cos(theta)
    local dx = wave.direction.X
    local dz = wave.direction.Y
    local ak = wave.amplitude * wave.waveNumber
    local bk = wave.horizontalAmplitude * wave.waveNumber
    position += Vector3.new(
      wave.horizontalAmplitude * dx * cosTheta,
      wave.amplitude * sinTheta,
      wave.horizontalAmplitude * dz * cosTheta
    )
    tangentX += Vector3.new(
      -bk * dx * dx * sinTheta,
      ak * dx * cosTheta,
      -bk * dx * dz * sinTheta
    )
    tangentZ += Vector3.new(
      -bk * dx * dz * sinTheta,
      ak * dz * cosTheta,
      -bk * dz * dz * sinTheta
    )
  end
  local cross = tangentZ:Cross(tangentX)
  local normal = cross.Magnitude > 1e-5 and cross.Unit or Vector3.yAxis
  return position, normal
end

local function updateBuffers(timeSeconds: number)
  for index = 1, VERTEX_COUNT do
    local position, normal = evaluate(labels[index], timeSeconds)
    positionBuffer[index] = position
    normalBuffer[index] = normal
  end
end

local function updateMesh(timeSeconds: number)
  local mesh = editableMesh
  if not mesh then
    return
  end
  updateBuffers(timeSeconds)
  local start = os.clock()
  local useBatch = runtime:GetAttribute("CapabilityLabBatch") ~= false and batchAvailable
  local updateNormals = runtime:GetAttribute("CapabilityLabUpdateNormals") ~= false
  if useBatch then
    local ok, err = pcall(function()
      mesh:BatchSetValues(vertexIds, positionBuffer)
      if updateNormals then
        mesh:BatchSetValues(normalIds, normalBuffer)
      end
    end)
    if not ok then
      batchAvailable = false
      if not batchErrorReported then
        batchErrorReported = true
        warn("OceanCapabilityLab | BatchSetValues failed; falling back to singular setters: " .. tostring(err))
      end
      for index = 1, VERTEX_COUNT do
        mesh:SetPosition(vertexIds[index], positionBuffer[index])
        if updateNormals then
          mesh:SetNormal(normalIds[index], normalBuffer[index])
        end
      end
    end
  else
    for index = 1, VERTEX_COUNT do
      mesh:SetPosition(vertexIds[index], positionBuffer[index])
      if updateNormals then
        mesh:SetNormal(normalIds[index], normalBuffer[index])
      end
    end
  end
  accumulatedUpdate += os.clock() - start
  accumulatedFrames += 1
  frameCount += 1
end

local function buildEditableMesh()
  local mesh = AssetService:CreateEditableMesh()
  for z = 0, CELL_COUNT do
    for x = 0, CELL_COUNT do
      local index = z * GRID_SIDE + x + 1
      local label = Vector2.new((x - CELL_COUNT * 0.5) * SPACING, (z - CELL_COUNT * 0.5) * SPACING)
      labels[index] = label
      vertexIds[index] = mesh:AddVertex(Vector3.new(label.X, 0, label.Y))
      normalIds[index] = mesh:AddNormal(Vector3.yAxis)
      colorIds[index] = mesh:AddColor(Color3.fromRGB(8, 80, 100), 0)
    end
  end
  for z = 0, CELL_COUNT - 1 do
    for x = 0, CELL_COUNT - 1 do
      local a = z * GRID_SIDE + x + 1
      local b = a + GRID_SIDE
      local c = a + 1
      local d = b + 1
      local faceOne = mesh:AddTriangle(vertexIds[a], vertexIds[b], vertexIds[c])
      mesh:SetFaceNormals(faceOne, {normalIds[a], normalIds[b], normalIds[c]})
      mesh:SetFaceColors(faceOne, {colorIds[a], colorIds[b], colorIds[c]})
      local faceTwo = mesh:AddTriangle(vertexIds[c], vertexIds[b], vertexIds[d])
      mesh:SetFaceNormals(faceTwo, {normalIds[c], normalIds[b], normalIds[d]})
      mesh:SetFaceColors(faceTwo, {colorIds[c], colorIds[b], colorIds[d]})
    end
  end
  -- Keep the generated MeshPart bounds large enough for runtime crest displacement.
  mesh:AddVertex(Vector3.new(0, -8, 0))
  mesh:AddVertex(Vector3.new(0, 8, 0))
  local part = AssetService:CreateMeshPartAsync(Content.fromObject(mesh))
  part.Name = "CapabilityMesh_33x33"
  part.Anchored = true
  part.CanCollide = false
  part.CanTouch = false
  part.CanQuery = false
  part.CastShadow = false
  part.DoubleSided = true
  part.Material = Enum.Material.SmoothPlastic
  part.Color = Color3.fromRGB(8, 80, 100)
  part.Reflectance = 0.12
  part.Transparency = 0.03
  part.Parent = runtime
  editableMesh = mesh
  meshPart = part
end

local function buildFallback()
  local part = Instance.new("Part")
  part.Name = "CapabilityFallback_Static"
  part.Anchored = true
  part.CanCollide = false
  part.CanTouch = false
  part.CanQuery = false
  part.CastShadow = false
  part.Material = Enum.Material.SmoothPlastic
  part.Color = Color3.fromRGB(8, 80, 100)
  part.Reflectance = 0.08
  part.Size = Vector3.new(WIDTH, 0.2, WIDTH)
  part.Position = Vector3.new(0, -0.35, 0)
  part.Transparency = 1
  part.Parent = runtime
  fallbackPart = part
end

local function teardown()
  if updateConnection then
    updateConnection:Disconnect()
  end
  if modeConnection then
    modeConnection:Disconnect()
  end
  clearTerrainLabVolume()
  terrain.WaterTransparency = originalWaterTransparency
  terrain.WaterWaveSize = originalWaterWaveSize
  terrain.WaterWaveSpeed = originalWaterWaveSpeed
  if meshPart then
    meshPart:Destroy()
  end
  if editableMesh then
    editableMesh:Destroy()
  end
  if fallbackPart then
    fallbackPart:Destroy()
  end
end

local ok, errorMessage = pcall(function()
  buildEditableMesh()
  buildFallback()
  local mesh = editableMesh
  if not mesh then
    error("EditableMesh was not created")
  end
  updateBuffers(0)
  local batchOk, batchError = pcall(function()
    mesh:BatchSetValues(vertexIds, positionBuffer)
    mesh:BatchSetValues(normalIds, normalBuffer)
  end)
  if not batchOk then
    warn("OceanCapabilityLab | initial BatchSetValues probe failed: " .. tostring(batchError))
  end
  batchAvailable = batchOk
  runtime:SetAttribute("CapabilityLabBatchAvailable", batchAvailable)
  runtime:SetAttribute("CapabilityLabVertexCount", VERTEX_COUNT)
  runtime:SetAttribute("CapabilityLabTriangleCount", CELL_COUNT * CELL_COUNT * 2)
  runtime:SetAttribute("CapabilityLabStatus", "ready")
  modeConnection = runtime:GetAttributeChangedSignal("CapabilityLabMode"):Connect(function()
    setMode(tostring(runtime:GetAttribute("CapabilityLabMode") or "EditableMesh"))
  end)
  setMode(tostring(runtime:GetAttribute("CapabilityLabMode") or "EditableMesh"))
  updateConnection = RunService.RenderStepped:Connect(function(dt)
    elapsed += dt
    updateMesh(elapsed)
    reportClock += dt
    if reportClock >= 2 then
      local averageMs = accumulatedFrames > 0 and (accumulatedUpdate / accumulatedFrames) * 1000 or 0
      local fps = reportClock > 0 and frameCount / reportClock or 0
      print(string.format("OceanCapabilityLab | status=running mode=%s batch=%s vertices=%d triangles=%d fps=%.1f updateMs=%.3f", tostring(runtime:GetAttribute("CapabilityLabResolvedMode")), tostring(runtime:GetAttribute("CapabilityLabBatch") ~= false and batchAvailable), VERTEX_COUNT, CELL_COUNT * CELL_COUNT * 2, fps, averageMs))
      reportClock = 0
      frameCount = 0
      accumulatedFrames = 0
      accumulatedUpdate = 0
    end
  end)
end)

if not ok then
  runtime:SetAttribute("CapabilityLabStatus", "fallback")
  warn("OceanCapabilityLab | EditableMesh allocation/setup failed; using static fallback: " .. tostring(errorMessage))
  local fallbackOk, fallbackError = pcall(buildFallback)
  if fallbackOk then
    setMode("Static")
  else
    warn("OceanCapabilityLab | static fallback failed: " .. tostring(fallbackError))
  end
end

Players.LocalPlayer.AncestryChanged:Connect(function(_, parent)
  if not parent then
    teardown()
  end
end)
