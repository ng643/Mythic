--!strict

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local QualityProfiles = require(ReplicatedStorage.Ocean.Shared.QualityProfiles)
local RenderEvaluator = require(ReplicatedStorage.Ocean.Shared.RenderEvaluator)

local OceanRenderer = {}
OceanRenderer.__index = OceanRenderer

local MAX_EDITABLE_EXTENT = 1900
local MAX_NEAR_RINGS = 6
local MAX_INITIAL_VERTICES = 12000
local MAX_HORIZON_OBJECTS = 64
local DEFAULT_HORIZON_RANGE = 6000
local HORIZON_TILE_MAX_SIZE = 1800
local MAX_VERTICAL_BOUNDS = 96
local BASE_COLOR = Color3.fromRGB(7, 64, 91)

local function smoothstep(value: number): number
  local t = math.clamp(value, 0, 1)
  return t * t * (3 - 2 * t)
end

local function keyOf(x: number, z: number): string
  return string.format("%.3f:%.3f", x, z)
end

local function finiteVector(value: Vector3): boolean
  return value.X == value.X and value.Y == value.Y and value.Z == value.Z
    and value.X > -math.huge and value.X < math.huge
    and value.Y > -math.huge and value.Y < math.huge
    and value.Z > -math.huge and value.Z < math.huge
end

local function materialVariantName(): string
  local slot = ReplicatedStorage.Ocean.Assets.WaterAppearances:FindFirstChild("OceanWaterPBR")
  local value = slot and slot:GetAttribute("MaterialVariant")
  return type(value) == "string" and value or "OceanWater"
end

local function waterMaps()
  local slot = ReplicatedStorage.Ocean.Assets.WaterAppearances:FindFirstChild("OceanWaterPBR")
  return {
    ColorMap = slot and slot:GetAttribute("ColorMap") or "",
    NormalMap = slot and slot:GetAttribute("NormalMap") or "",
    RoughnessMap = slot and slot:GetAttribute("RoughnessMap") or "",
    MetalnessMap = slot and slot:GetAttribute("MetalnessMap") or "",
  }
end

local function applySurfaceAppearance(part: MeshPart)
  local maps = waterMaps()
  local surface = part:FindFirstChild("OceanSurfaceAppearance")
  if not surface or not surface:IsA("SurfaceAppearance") then
    surface = Instance.new("SurfaceAppearance")
    surface.Name = "OceanSurfaceAppearance"
    surface.Parent = part
  end
  pcall(function()
    surface.AlphaMode = Enum.AlphaMode.Opaque
    surface.ColorMap = maps.ColorMap
    surface.NormalMap = maps.NormalMap
    surface.RoughnessMap = maps.RoughnessMap
    surface.MetalnessMap = maps.MetalnessMap
  end)
end

local function setMeshPartProperties(part: MeshPart, runtime: Folder)
  part.Anchored = true
  part.CanCollide = false
  part.CanTouch = false
  part.CanQuery = false
  part.CastShadow = false
  part.Massless = true
  part.DoubleSided = true
  part.Material = Enum.Material.SmoothPlastic
  part.MaterialVariant = materialVariantName()
  part.Color = BASE_COLOR
  part.Reflectance = 0
  part.Transparency = 0
  -- MaterialVariant supplies normal/roughness/metalness; an empty ColorMap
  -- must not create a white SurfaceAppearance over MeshPart.Color.
  if runtime:GetAttribute("OceanMaterialPath") == nil then
    self.runtime:SetAttribute("OceanMaterialPath", "MaterialVariant")
    runtime:SetAttribute("OceanUVSpace", "MaterialVariant.StudsPerTile")
    runtime:SetAttribute("OceanWorldLockedUV", true)
  end
end

local function setStaticPartProperties(part: Part)
  part.Anchored = true
  part.CanCollide = false
  part.CanTouch = false
  part.CanQuery = false
  part.CastShadow = false
  part.Material = Enum.Material.SmoothPlastic
  part.MaterialVariant = materialVariantName()
  part.Color = BASE_COLOR
  part.Reflectance = 0
  part.Transparency = 0
end

local function componentBound(state): number
  local bound = 0
  for _, bank in ipairs({state.bankA, state.bankB}) do
    local bankBound = 0
    for _, component in ipairs(bank) do
      bankBound += math.abs(component.amplitude)
    end
    bound = math.max(bound, bankBound)
  end
  return bound
end

function OceanRenderer.new(waveField)
  local runtime = Workspace:FindFirstChild("OceanRuntime")
  if not runtime then
    runtime = Instance.new("Folder")
    runtime.Name = "OceanRuntime"
    runtime.Parent = Workspace
  end
  for _, child in ipairs(runtime:GetChildren()) do
    if string.sub(child.Name, 1, 14) == "OceanClipmap_L"
      or string.sub(child.Name, 1, 16) == "OceanTransition_"
      or string.sub(child.Name, 1, 13) == "OceanHorizon_"
      or child.Name == "OceanFallbackSurface" then
      child:Destroy()
    end
  end

  return setmetatable({
    waveField = waveField,
    runtime = runtime,
    qualityName = "High",
    profile = QualityProfiles.Get("High"),
    topologySpacing = 4,
    rings = {},
    transition = nil,
    transitions = {},
    horizonTiles = {},
    fallback = nil,
    running = false,
    visible = true,
    baseVisible = true,
    farVisible = true,
    connection = nil,
    generation = 0,
    horizonAnchor = Vector2.zero,
    horizonAccumulator = 0,
    debugSeams = false,
    seamTimer = 0,
    stats = {
      vertexCount = 0,
      triangleCount = 0,
      horizonTileCount = 0,
      transitionVertexCount = 0,
      transitionTriangleCount = 0,
      transitionCount = 0,
      lastFrameMs = 0,
      lastOceanMs = 0,
      lastUpdateMs = 0,
      lastUVUpdateMs = 0,
      lastWaveEvaluateMs = 0,
      lastVertexCommitMs = 0,
      lastNormalCommitMs = 0,
      ringCount = 0,
      requestedRingCount = 0,
      seamPositionError = 0,
      seamNormalError = 0,
      seamSampleCount = 0,
      topologyStatus = "unverified",
      fallback = false,
      horizonFailed = false,
      ringFailureCount = 0,
      meshGeneration = 0,
      batchAvailable = false,
      batchFailureReason = "client-singular-setter-benchmarked",
    },
  }, OceanRenderer)
end

function OceanRenderer:_PublishStats()
  if self.runtime:GetAttribute("OceanDebugMetrics") ~= true then return end
  local stats = self.stats
  self.runtime:SetAttribute("OceanRingCount", stats.ringCount)
  self.runtime:SetAttribute("OceanRequestedRingCount", stats.requestedRingCount)
  self.runtime:SetAttribute("OceanHorizonTileCount", stats.horizonTileCount)
  self.runtime:SetAttribute("OceanTransitionCount", stats.transitionCount)
  self.runtime:SetAttribute("OceanSeamSampleCount", stats.seamSampleCount)
  self.runtime:SetAttribute("OceanHorizonFailed", stats.horizonFailed)
  self.runtime:SetAttribute("OceanRingFailureCount", stats.ringFailureCount)
  self.runtime:SetAttribute("OceanMeshGeneration", stats.meshGeneration)
  self.runtime:SetAttribute("OceanSeamMaxPositionError", stats.seamPositionError)
  self.runtime:SetAttribute("OceanSeamMaxNormalError", stats.seamNormalError)
  self.runtime:SetAttribute("OceanTopologyStatus", stats.topologyStatus)
  self.runtime:SetAttribute("OceanBatchAvailable", stats.batchAvailable)
  self.runtime:SetAttribute("OceanBatchFailureReason", stats.batchFailureReason)
  self.runtime:SetAttribute("OceanWaveEvaluateMs", stats.lastWaveEvaluateMs)
  self.runtime:SetAttribute("OceanVertexCommitMs", stats.lastVertexCommitMs)
  self.runtime:SetAttribute("OceanNormalCommitMs", stats.lastNormalCommitMs)
end

function OceanRenderer:_DestroyRings()
  for _, ring in ipairs(self.rings) do
    if ring.part then ring.part:Destroy() end
    if ring.mesh then ring.mesh:Destroy() end
  end
  table.clear(self.rings)
  self.stats.vertexCount = 0
  self.stats.triangleCount = 0
end

function OceanRenderer:_DestroyTransition()
  for _, transition in ipairs(self.transitions or {}) do
    if transition.part then transition.part:Destroy() end
    if transition.mesh then transition.mesh:Destroy() end
  end
  table.clear(self.transitions or {})
  self.transition = nil
  self.stats.transitionCount = 0
  self.stats.transitionVertexCount = 0
  self.stats.transitionTriangleCount = 0
end

function OceanRenderer:_DestroyHorizon()
  for _, tile in ipairs(self.horizonTiles) do
    if tile.part then tile.part:Destroy() end
  end
  table.clear(self.horizonTiles)
  self.stats.horizonTileCount = 0
end

function OceanRenderer:_CellIncluded(i: number, j: number, innerHalf: number): boolean
  if innerHalf <= 0 then return true end
  return math.max(math.abs(i + 0.5), math.abs(j + 0.5)) >= innerHalf
end

function OceanRenderer:_BuildMesh(name: string, resolution: number, spacing: number, innerHalf: number, kind: string, level: number)
  local outerHalf = math.floor((resolution - 1) * 0.5)
  local mesh, reason = AssetService:CreateEditableMesh()
  if not mesh then error("CreateEditableMesh failed: " .. tostring(reason)) end

  local vertexMap = {}
  local vertices = {}
  local normals = {}
  local labelsX = {}
  local labelsZ = {}
  local triangleCount = 0

  local function getVertex(x: number, z: number): number
    local mapKey = keyOf(x, z)
    local existing = vertexMap[mapKey]
    if existing then return existing end
    local vertexId = mesh:AddVertex(Vector3.new(x, 0, z))
    local normalId = mesh:AddNormal(Vector3.yAxis)
    local index = #vertices + 1
    vertexMap[mapKey] = index
    vertices[index] = vertexId
    normals[index] = normalId
    labelsX[index] = x
    labelsZ[index] = z
    return index
  end

  local function edgeIsHole(i: number, j: number): boolean
    return not self:_CellIncluded(i, j, innerHalf)
  end

  for j = -outerHalf, outerHalf - 1 do
    for i = -outerHalf, outerHalf - 1 do
      if self:_CellIncluded(i, j, innerHalf) then
        local ax, az = i * spacing, j * spacing
        local bx, bz = i * spacing, (j + 1) * spacing
        local cx, cz = (i + 1) * spacing, j * spacing
        local dx, dz = (i + 1) * spacing, (j + 1) * spacing
        local holeEdges = {
          edgeIsHole(i - 1, j),
          edgeIsHole(i, j + 1),
          edgeIsHole(i + 1, j),
          edgeIsHole(i, j - 1),
        }
        local hasHoleEdge = holeEdges[1] or holeEdges[2] or holeEdges[3] or holeEdges[4]
        if not hasHoleEdge then
          local a = getVertex(ax, az)
          local b = getVertex(bx, bz)
          local c = getVertex(cx, cz)
          local d = getVertex(dx, dz)
          mesh:AddTriangle(vertices[a], vertices[b], vertices[c])
          mesh:AddTriangle(vertices[c], vertices[b], vertices[d])
          triangleCount += 2
        else
          local polygon = {{ax, az}, {bx, bz}, {dx, dz}, {cx, cz}}
          local edgeCells = {{i - 1, j}, {i, j + 1}, {i + 1, j}, {i, j - 1}}
          local expanded = {}
          for polygonIndex, label in ipairs(polygon) do
            table.insert(expanded, label)
            if edgeIsHole(edgeCells[polygonIndex][1], edgeCells[polygonIndex][2]) then
              local nextLabel = polygon[polygonIndex % #polygon + 1]
              table.insert(expanded, {(label[1] + nextLabel[1]) * 0.5, (label[2] + nextLabel[2]) * 0.5})
            end
          end
          local center = getVertex((ax + bx + cx + dx) * 0.25, (az + bz + cz + dz) * 0.25)
          for polygonIndex, label in ipairs(expanded) do
            local nextLabel = expanded[polygonIndex % #expanded + 1]
            local first = getVertex(label[1], label[2])
            local second = getVertex(nextLabel[1], nextLabel[2])
            mesh:AddTriangle(vertices[center], vertices[first], vertices[second])
            triangleCount += 1
          end
        end
      end
    end
  end

  local state = self.waveField:GetState()
  local verticalBound = math.clamp(math.max(24, componentBound(state) * 2 + 8), 16, MAX_VERTICAL_BOUNDS)
  mesh:AddVertex(Vector3.new(0, -verticalBound, 0))
  mesh:AddVertex(Vector3.new(0, verticalBound, 0))
  local part = AssetService:CreateMeshPartAsync(Content.fromObject(mesh))
  part.Name = name
  setMeshPartProperties(part, self.runtime)
  part.DoubleSided = kind == "near" and level == 0
  part.Parent = self.runtime

  local ring = {
    name = name,
    kind = kind,
    level = level,
    mesh = mesh,
    part = part,
    vertices = vertices,
    normals = normals,
    labelsX = labelsX,
    labelsZ = labelsZ,
    labelIndex = vertexMap,
    positions = table.create(#vertices),
    normalValues = table.create(#vertices),
    spacing = spacing,
    outerHalf = outerHalf,
    innerHalf = innerHalf,
    innerExtent = innerHalf * spacing,
    outerExtent = outerHalf * spacing,
    origin = Vector2.new(math.huge, math.huge),
    accumulator = 0,
    boundaryAccumulator = 0,
    cadence = 1 / 30,
    boundaryCadence = 1 / 30,
    componentCap = 6,
    sharedComponentCap = 6,
    updateNormals = true,
    triangleCount = triangleCount,
    lastCommittedServerTime = -math.huge,
    lastNormalServerTime = -math.huge,
    failureCount = 0,
    frozen = false,
  }
  for index = 1, #vertices do
    ring.positions[index] = Vector3.new(labelsX[index], 0, labelsZ[index])
    ring.normalValues[index] = Vector3.yAxis
  end
  ring.boundaryIndices = {}
  local boundaryTolerance = spacing * 0.51
  for index = 1, #vertices do
    local edge = math.max(math.abs(labelsX[index]), math.abs(labelsZ[index]))
    if math.abs(edge - ring.outerExtent) <= boundaryTolerance
      or (ring.innerExtent > 0 and math.abs(edge - ring.innerExtent) <= boundaryTolerance) then
      table.insert(ring.boundaryIndices, index)
    end
  end
  return ring
end
function OceanRenderer:_BuildRectMesh(
  name: string,
  xMin: number,
  xMax: number,
  zMin: number,
  zMax: number,
  spacing: number,
  level: number
)
  local xCount = math.max(1, math.floor((xMax - xMin) / spacing + 0.5))
  local zCount = math.max(1, math.floor((zMax - zMin) / spacing + 0.5))
  xMax = xMin + xCount * spacing
  zMax = zMin + zCount * spacing
  local mesh, reason = AssetService:CreateEditableMesh()
  if not mesh then error("CreateEditableMesh transition failed: " .. tostring(reason)) end
  local vertices = {}
  local normals = {}
  local labelsX = {}
  local labelsZ = {}
  local vertexMap = {}
  local triangleCount = 0

  local function getVertex(x: number, z: number): number
    local mapKey = keyOf(x, z)
    local existing = vertexMap[mapKey]
    if existing then return existing end
    local vertexId = mesh:AddVertex(Vector3.new(x, 0, z))
    local normalId = mesh:AddNormal(Vector3.yAxis)
    local index = #vertices + 1
    vertexMap[mapKey] = index
    vertices[index] = vertexId
    normals[index] = normalId
    labelsX[index] = x
    labelsZ[index] = z
    return index
  end

  for iz = 0, zCount - 1 do
    for ix = 0, xCount - 1 do
      local ax, az = xMin + ix * spacing, zMin + iz * spacing
      local bx, bz = ax, az + spacing
      local cx, cz = ax + spacing, az
      local dx, dz = cx, bz
      local a = getVertex(ax, az)
      local b = getVertex(bx, bz)
      local c = getVertex(cx, cz)
      local d = getVertex(dx, dz)
      mesh:AddTriangle(vertices[a], vertices[b], vertices[c])
      mesh:AddTriangle(vertices[c], vertices[b], vertices[d])
      triangleCount += 2
    end
  end

  local state = self.waveField:GetState()
  local verticalBound = math.clamp(math.max(24, componentBound(state) * 2 + 8), 16, MAX_VERTICAL_BOUNDS)
  mesh:AddVertex(Vector3.new(0, -verticalBound, 0))
  mesh:AddVertex(Vector3.new(0, verticalBound, 0))
  local part = AssetService:CreateMeshPartAsync(Content.fromObject(mesh))
  part.Name = name
  setMeshPartProperties(part, self.runtime)
  part.DoubleSided = false
  part.Parent = self.runtime

  local ring = {
    name = name,
    kind = "transition",
    level = level,
    mesh = mesh,
    part = part,
    vertices = vertices,
    normals = normals,
    labelsX = labelsX,
    labelsZ = labelsZ,
    labelIndex = vertexMap,
    positions = table.create(#vertices),
    normalValues = table.create(#vertices),
    spacing = spacing,
    outerHalf = 0,
    innerHalf = 0,
    innerExtent = self.transitionInnerExtent,
    outerExtent = self.transitionOuterExtent,
    origin = Vector2.new(math.huge, math.huge),
    accumulator = 0,
    boundaryAccumulator = 0,
    cadence = 1 / 10,
    boundaryCadence = 1 / 30,
    componentCap = 6,
    sharedComponentCap = 6,
    updateNormals = true,
    triangleCount = triangleCount,
    lastCommittedServerTime = -math.huge,
    lastNormalServerTime = -math.huge,
    failureCount = 0,
    frozen = false,
  }
  for index = 1, #vertices do
    ring.positions[index] = Vector3.new(labelsX[index], 0, labelsZ[index])
    ring.normalValues[index] = Vector3.yAxis
  end
  ring.boundaryIndices = {}
  local boundaryTolerance = spacing * 0.51
  for index = 1, #vertices do
    local edge = math.max(math.abs(labelsX[index]), math.abs(labelsZ[index]))
    if math.abs(edge - ring.outerExtent) <= boundaryTolerance
      or math.abs(edge - ring.innerExtent) <= boundaryTolerance then
      table.insert(ring.boundaryIndices, index)
    end
  end
  return ring
end

function OceanRenderer:_BuildTransitionSectors(finalRing)
  self:_DestroyTransition()
  local innerExtent = finalRing.outerExtent
  local width = self.profile.transitionWidth or 768
  local spacing = self.profile.transitionSpacing or 64
  local outerExtent = innerExtent + width
  local innerSteps = math.max(1, math.floor(innerExtent / spacing + 0.5))
  local outerSteps = math.max(innerSteps + 1, math.ceil(outerExtent / spacing))
  innerExtent = innerSteps * spacing
  outerExtent = outerSteps * spacing
  self.transitionInnerExtent = innerExtent
  self.transitionOuterExtent = outerExtent
  self.transitions = {}
  local specs = {
    {-innerExtent, innerExtent, innerExtent, outerExtent},
    {-outerExtent, -innerExtent, innerExtent, outerExtent},
    {innerExtent, outerExtent, innerExtent, outerExtent},
    {-innerExtent, innerExtent, -outerExtent, -innerExtent},
    {-outerExtent, -innerExtent, -outerExtent, -innerExtent},
    {innerExtent, outerExtent, -outerExtent, -innerExtent},
    {-outerExtent, -innerExtent, -innerExtent, innerExtent},
    {innerExtent, outerExtent, -innerExtent, innerExtent},
  }
  for index, spec in ipairs(specs) do
    local sector = self:_BuildRectMesh(
      string.format("OceanTransition_%d", index),
      spec[1],
      spec[2],
      spec[3],
      spec[4],
      spacing,
      #self.rings
    )
    table.insert(self.transitions, sector)
  end
  self.transition = self.transitions[1]
  self.stats.transitionCount = #self.transitions
  self.stats.transitionVertexCount = 0
  self.stats.transitionTriangleCount = 0
  for _, transition in ipairs(self.transitions) do
    self.stats.transitionVertexCount += #transition.vertices + 2
    self.stats.transitionTriangleCount += transition.triangleCount
  end
end


function OceanRenderer:_BuildFallback()
  if self.fallback then return end
  local part = Instance.new("Part")
  part.Name = "OceanFallbackSurface"
  setStaticPartProperties(part)
  part.Size = Vector3.new(8192, 0.25, 8192)
  part.Position = Vector3.zero
  part.Transparency = 0.05
  part.Parent = self.runtime
  self.fallback = part
  self.stats.fallback = true
end

function OceanRenderer:_UseFallback(reason: string)
  if not self.stats.fallback then
    warn("OceanRenderer | falling back to static surface: " .. reason)
  end
  self:_DestroyRings()
  self:_DestroyTransition()
  self:_DestroyHorizon()
  self:_BuildFallback()
end

function OceanRenderer:_BuildHorizon(innerExtent: number)
  self:_DestroyHorizon()
  local range = math.max(self.profile.horizonRange or DEFAULT_HORIZON_RANGE, innerExtent + 1)
  range = math.min(range, DEFAULT_HORIZON_RANGE)
  local tileSize = math.min(self.profile.horizonTileSize or HORIZON_TILE_MAX_SIZE, HORIZON_TILE_MAX_SIZE)
  local seaLevel = self.waveField:GetState().seaLevel
  local intervals = {}
  local cursor = -range
  while cursor < range - 0.01 do
    local finish = math.min(cursor + tileSize, range)
    table.insert(intervals, {cursor, finish})
    cursor = finish
  end
  local innerIntervals = {}
  cursor = -innerExtent
  while cursor < innerExtent - 0.01 do
    local finish = math.min(cursor + tileSize, innerExtent)
    table.insert(innerIntervals, {cursor, finish})
    cursor = finish
  end

  local function addTile(xMin: number, xMax: number, zMin: number, zMax: number)
    if #self.horizonTiles >= MAX_HORIZON_OBJECTS then
      error("horizon object budget exceeded")
    end
    local width = xMax - xMin
    local depth = zMax - zMin
    if width <= 0.01 or depth <= 0.01 then return end
    local part = Instance.new("Part")
    part.Name = string.format("OceanHorizon_%d", #self.horizonTiles + 1)
    setStaticPartProperties(part)
    part.Size = Vector3.new(width, 0.25, depth)
    part.Position = Vector3.new(xMin + width * 0.5, seaLevel, zMin + depth * 0.5)
    part.Parent = self.runtime
    table.insert(self.horizonTiles, {
      part = part,
      center = Vector2.new(xMin + width * 0.5, zMin + depth * 0.5),
    })
  end

  for _, outer in ipairs(intervals) do
    for _, north in ipairs(intervals) do
      if north[1] >= innerExtent then addTile(outer[1], outer[2], north[1], north[2]) end
      if north[2] <= -innerExtent then addTile(outer[1], outer[2], north[1], north[2]) end
    end
  end
  for _, east in ipairs(intervals) do
    if east[1] >= innerExtent or east[2] <= -innerExtent then
      for _, middle in ipairs(innerIntervals) do
        addTile(east[1], east[2], middle[1], middle[2])
      end
    end
  end
  self.stats.horizonTileCount = #self.horizonTiles
  self.runtime:SetAttribute("OceanHorizonCoverage", "transition-plus-static-annulus")
end

function OceanRenderer:_AssignTopologyCaps()
  local fullCap = self.waveField:GetGameplayComponentCap()
  for index, ring in ipairs(self.rings) do
    ring.componentCap = index == 1 and fullCap or math.min(self.profile.waveCap, fullCap)
    ring.cadence = 1 / math.max(self.profile.nearCadence / 2 ^ (index - 1), 5)
    ring.boundaryCadence = 1 / math.max(self.profile.nearCadence, 5)
  end
  for index, ring in ipairs(self.rings) do
    ring.sharedComponentCap = index < #self.rings and self.rings[index + 1].componentCap or math.min(6, fullCap)
  end
  for _, transition in ipairs(self.transitions or {}) do
    transition.componentCap = math.min(self.profile.transitionWaveCap or 6, fullCap)
    transition.sharedComponentCap = transition.componentCap
    transition.cadence = self.profile.transitionCadence or 0.12
    transition.boundaryCadence = 1 / math.max(self.profile.nearCadence, 5)
  end
  if self.rings[#self.rings] then self.rings[#self.rings].updateNormals = true end
end

function OceanRenderer:_Build()
  self.generation += 1
  self.stats.meshGeneration = self.generation
  self.stats.fallback = false
  self.stats.horizonFailed = false
  self.stats.ringFailureCount = 0
  self:_DestroyRings()
  self:_DestroyTransition()
  self:_DestroyHorizon()
  if self.fallback then self.fallback:Destroy() self.fallback = nil end
  self.stats.requestedRingCount = math.min(self.profile.ringCount, MAX_NEAR_RINGS)
  local nearOk, nearReason = pcall(function()
    local resolutions = self.profile.ringResolutions or {self.profile.resolution}
    local extents = self.profile.ringExtents or {}
    for level = 1, self.stats.requestedRingCount do
      local extent = extents[level]
      if not extent then break end
      if extent > MAX_EDITABLE_EXTENT then break end
      local resolution = resolutions[level] or self.profile.resolution
      local outerHalf = math.floor((resolution - 1) * 0.5)
      local spacing = extent / math.max(outerHalf, 1)
      local innerExtent = level == 1 and 0 or extents[level - 1]
      local innerHalf = level == 1 and 0 or math.floor(innerExtent / spacing + 0.5)
      local ring = self:_BuildMesh(string.format("OceanClipmap_L%d", level - 1), resolution, spacing, innerHalf, "near", level - 1)
      table.insert(self.rings, ring)
      self.stats.vertexCount += #ring.vertices + 2
      self.stats.triangleCount += ring.triangleCount
      if self.stats.vertexCount > MAX_INITIAL_VERTICES then error("near vertex budget exceeded") end
    end
    if #self.rings == 0 then error("no near rings were created") end
  end)
  if not nearOk then
    self.runtime:SetAttribute("OceanRendererBuildError", tostring(nearReason))
    self:_UseFallback(tostring(nearReason))
  else
    self.runtime:SetAttribute("OceanRendererBuildError", nil)
    local transitionOk, transitionReason = pcall(function()
      self:_BuildTransitionSectors(self.rings[#self.rings])
    end)
    if not transitionOk then
      self.stats.horizonFailed = true
      self.runtime:SetAttribute("OceanTransitionBuildError", tostring(transitionReason))
      warn("OceanRenderer | transition disabled: " .. tostring(transitionReason))
    else
      self.runtime:SetAttribute("OceanTransitionBuildError", nil)
      local horizonOk, horizonReason = pcall(function()
        self:_BuildHorizon(self.transitionOuterExtent)
      end)
      if not horizonOk then
        self.stats.horizonFailed = true
        self.runtime:SetAttribute("OceanHorizonBuildError", tostring(horizonReason))
        warn("OceanRenderer | horizon disabled: " .. tostring(horizonReason))
      else
        self.runtime:SetAttribute("OceanHorizonBuildError", nil)
      end
    end
  end
  self.stats.ringCount = #self.rings
  self:_AssignTopologyCaps()
  self.runtime:SetAttribute("OceanRendererVertexBudget", MAX_INITIAL_VERTICES)
  self.runtime:SetAttribute("OceanRendererBatchMode", "singular-setter-client-benchmark")
  self:_PublishStats()
end

function OceanRenderer:_UpdateRing(ring, serverTime: number, anchor: Vector2, plansA, plansB, blendAlpha: number, seaLevel: number, boundaryOnly: boolean?)
  if ring.frozen then return end
  if ring.origin ~= anchor then
    ring.origin = anchor
    ring.part.CFrame = CFrame.new(anchor.X, seaLevel, anchor.Y)
  end

  local startEval = os.clock()
  local sharedCount = math.min(ring.sharedComponentCap, ring.componentCap)
  local updateIndices = boundaryOnly and ring.boundaryIndices or nil
  local updateCount = updateIndices and #updateIndices or #ring.vertices
  for sequence = 1, updateCount do
    local index = updateIndices and updateIndices[sequence] or sequence
    local x = anchor.X + ring.labelsX[index]
    local z = anchor.Y + ring.labelsZ[index]
    local residualWeight = 1
    if ring.kind == "transition" then
      local edge = math.max(math.abs(ring.labelsX[index]), math.abs(ring.labelsZ[index]))
      local t = (edge - ring.innerExtent) / math.max(ring.outerExtent - ring.innerExtent, 1)
      residualWeight = 1 - smoothstep(t)
    elseif ring.componentCap > sharedCount then
      local edge = math.max(math.abs(ring.labelsX[index]), math.abs(ring.labelsZ[index])) / math.max(ring.outerExtent, 1)
      residualWeight = edge > 0.62 and 1 - smoothstep((edge - 0.62) / 0.38) or 1
    end
    local px, py, pz, nx, ny, nz = RenderEvaluator.EvaluateScalars(
      x,
      z,
      seaLevel,
      plansA[ring.componentCap],
      plansB[ring.componentCap],
      blendAlpha,
      sharedCount,
      residualWeight
    )
    if ring.kind == "transition" then
      px = x + (px - x) * residualWeight
      py = seaLevel + (py - seaLevel) * residualWeight
      pz = z + (pz - z) * residualWeight
      local normal = Vector3.new(nx, ny, nz):Lerp(Vector3.yAxis, 1 - residualWeight).Unit
      nx, ny, nz = normal.X, normal.Y, normal.Z
    end
    local displacement = Vector3.new(px - x, py - seaLevel, pz - z)
    local normal = Vector3.new(nx, ny, nz)
    if not finiteVector(displacement) or displacement.Magnitude > MAX_VERTICAL_BOUNDS * 2 or not finiteVector(normal) then
      ring.failureCount += 1
      self.stats.ringFailureCount += 1
      if ring.failureCount >= 3 then ring.frozen = true end
      return
    end
    ring.positions[index] = Vector3.new(ring.labelsX[index] + displacement.X, displacement.Y, ring.labelsZ[index] + displacement.Z)
    if ring.updateNormals then ring.normalValues[index] = normal end
  end
  self.stats.lastWaveEvaluateMs += (os.clock() - startEval) * 1000

  local startCommit = os.clock()
  debug.profilebegin("Ocean/VertexCommit")
  local commitOk, commitReason = pcall(function()
    for sequence = 1, updateCount do
      local index = updateIndices and updateIndices[sequence] or sequence
      ring.mesh:SetPosition(ring.vertices[index], ring.positions[index])
    end
  end)
  debug.profileend()
  self.stats.lastVertexCommitMs += (os.clock() - startCommit) * 1000
  if not commitOk then
    ring.failureCount += 1
    self.stats.ringFailureCount += 1
    if ring.failureCount >= 3 then ring.frozen = true end
    self.runtime:SetAttribute("OceanRingFailureReason", tostring(commitReason))
    return
  end

  if ring.updateNormals then
    local startNormals = os.clock()
    debug.profilebegin("Ocean/Normals")
    local normalOk, normalReason = pcall(function()
      for sequence = 1, updateCount do
        local index = updateIndices and updateIndices[sequence] or sequence
        ring.mesh:SetNormal(ring.normals[index], ring.normalValues[index])
      end
    end)
    debug.profileend()
    self.stats.lastNormalCommitMs += (os.clock() - startNormals) * 1000
    if not normalOk then
      ring.failureCount += 1
      self.stats.ringFailureCount += 1
      self.runtime:SetAttribute("OceanRingNormalFailure", tostring(normalReason))
      return
    end
    ring.lastNormalServerTime = serverTime
  end
  ring.failureCount = 0
  ring.lastCommittedServerTime = serverTime
end

function OceanRenderer:_UpdateHorizon(anchor: Vector2, seaLevel: number)
  if self.horizonAnchor == anchor then return end
  self.horizonAnchor = anchor
  for _, tile in ipairs(self.horizonTiles) do
    tile.part.Position = Vector3.new(anchor.X + tile.center.X, seaLevel, anchor.Y + tile.center.Y)
  end
end

function OceanRenderer:_UpdateSeamStats()
  if self.runtime:GetAttribute("OceanDebugSeams") ~= true then return end
  local maxPosition = 0
  local maxNormal = 0
  local count = 0
  for index = 1, #self.rings - 1 do
    local fine = self.rings[index]
    local coarse = self.rings[index + 1]
    local boundary = fine.outerExtent
    local coarseStep = coarse.spacing
    local steps = math.floor(boundary / coarseStep + 0.001)
    for sampleIndex = -steps, steps do
      local offset = sampleIndex * coarseStep
      for _, point in ipairs({Vector2.new(-boundary, offset), Vector2.new(boundary, offset), Vector2.new(offset, -boundary), Vector2.new(offset, boundary)}) do
        local fineIndex = fine.labelIndex[keyOf(point.X, point.Y)]
        local coarseIndex = coarse.labelIndex[keyOf(point.X, point.Y)]
        if fineIndex and coarseIndex then
          local finePosition = fine.part.Position + fine.positions[fineIndex]
          local coarsePosition = coarse.part.Position + coarse.positions[coarseIndex]
          maxPosition = math.max(maxPosition, (finePosition - coarsePosition).Magnitude)
          if fine.updateNormals and coarse.updateNormals then
            local fineNormal = fine.normalValues[fineIndex]
            local coarseNormal = coarse.normalValues[coarseIndex]
            maxNormal = math.max(maxNormal, math.deg(math.acos(math.clamp(fineNormal:Dot(coarseNormal), -1, 1))))
          end
          count += 1
        end
      end
    end
  end
  self.stats.seamPositionError = maxPosition
  self.stats.seamNormalError = maxNormal
  self.stats.seamSampleCount = count
  self.stats.topologyStatus = count > 0 and maxPosition <= 0.02 and maxNormal <= 1 and "passed" or "failed"
end

function OceanRenderer:SetQuality(profileName: string)
  if profileName == "Fallback" then
    return {topologyChanged = false, rejected = true, reason = "fallback is initialization-only"}
  end
  local profile = QualityProfiles.Get(profileName)
  if not profile or profile.resolution == 0 or not profile.ringResolutions then
    return {topologyChanged = false, rejected = true, reason = "unknown quality profile"}
  end
  if self.qualityName == profileName then
    return {topologyChanged = false, unchanged = true}
  end
  self.qualityName = profileName
  self.profile = profile
  if self.running then
    self:_AssignTopologyCaps()
  end
  return {topologyChanged = false, unchanged = false}
end

function OceanRenderer:SetBaseVisible(visible: boolean)
  self.baseVisible = visible
  for _, ring in ipairs(self.rings) do ring.part.Transparency = visible and 0 or 1 end
  for _, transition in ipairs(self.transitions or {}) do transition.part.Transparency = visible and 0 or 1 end
  if self.fallback then self.fallback.Transparency = visible and 0.05 or 1 end
end

function OceanRenderer:SetFarVisible(visible: boolean)
  self.farVisible = visible
  for _, tile in ipairs(self.horizonTiles) do tile.part.Transparency = visible and 0 or 1 end
end

function OceanRenderer:SetVisible(visible: boolean)
  self.visible = visible
  self:SetBaseVisible(visible)
  self:SetFarVisible(visible)
end

function OceanRenderer:_Update(dt: number)
  if not self.running or not self.visible then return end
  local camera = Workspace.CurrentCamera
  if not camera then return end
  local started = os.clock()
  self.stats.lastUpdateMs = 0
  self.stats.lastUVUpdateMs = 0
  self.stats.lastWaveEvaluateMs = 0
  self.stats.lastVertexCommitMs = 0
  self.stats.lastNormalCommitMs = 0
  local serverTime = self.waveField:StepClock(math.clamp(dt, 0, 0.05))
  local state = self.waveField:GetState()
  local seaLevel = state.seaLevel
  local anchor = Vector2.new(
    math.floor(camera.CFrame.Position.X / self.topologySpacing + 0.5) * self.topologySpacing,
    math.floor(camera.CFrame.Position.Z / self.topologySpacing + 0.5) * self.topologySpacing
  )
  local fullCap = self.waveField:GetGameplayComponentCap()
  local blendAlpha = self.waveField:_BlendAlpha(serverTime)
  local elapsed = serverTime - state.epochServerTime
  local plansA = {}
  local plansB = {}
  local caps = {fullCap}
  for _, ring in ipairs(self.rings) do table.insert(caps, ring.componentCap) end
  for _, transition in ipairs(self.transitions or {}) do table.insert(caps, transition.componentCap) end
  table.sort(caps)
  local lastCap = nil
  for _, cap in ipairs(caps) do
    if cap ~= lastCap then
      plansA[cap] = RenderEvaluator.Prepare(state.bankA, elapsed, cap)
      if blendAlpha > 0 and #state.bankB > 0 then plansB[cap] = RenderEvaluator.Prepare(state.bankB, elapsed, cap) end
      lastCap = cap
    end
  end
  for _, ring in ipairs(self.rings) do
    ring.accumulator += dt
    ring.boundaryAccumulator += dt
    if ring.accumulator >= ring.cadence then
      ring.accumulator %= ring.cadence
      ring.boundaryAccumulator = 0
      self:_UpdateRing(ring, serverTime, anchor, plansA, plansB, blendAlpha, seaLevel, false)
    elseif ring.boundaryAccumulator >= ring.boundaryCadence then
      ring.boundaryAccumulator %= ring.boundaryCadence
      self:_UpdateRing(ring, serverTime, anchor, plansA, plansB, blendAlpha, seaLevel, true)
    end
  end
  for _, transition in ipairs(self.transitions or {}) do
    transition.accumulator += dt
    transition.boundaryAccumulator += dt
    if transition.accumulator >= transition.cadence then
      transition.accumulator %= transition.cadence
      transition.boundaryAccumulator = 0
      self:_UpdateRing(transition, serverTime, anchor, plansA, plansB, blendAlpha, seaLevel, false)
    elseif transition.boundaryAccumulator >= transition.boundaryCadence then
      transition.boundaryAccumulator %= transition.boundaryCadence
      self:_UpdateRing(transition, serverTime, anchor, plansA, plansB, blendAlpha, seaLevel, true)
    end
  end
  self.seamTimer += dt
  if self.seamTimer >= 1 then
    self.seamTimer = 0
    self:_UpdateSeamStats()
  end
  self.stats.lastOceanMs = (os.clock() - started) * 1000
  self.stats.lastFrameMs = dt * 1000
  self.stats.lastUpdateMs = self.stats.lastWaveEvaluateMs + self.stats.lastVertexCommitMs + self.stats.lastNormalCommitMs
  self:_PublishStats()
end

function OceanRenderer:Start()
  if self.running then return end
  self.running = true
  self:_Build()
  self.connection = RunService.RenderStepped:Connect(function(dt)
    self:_Update(dt)
  end)
end

function OceanRenderer:Stop()
  self.generation += 1
  if self.connection then self.connection:Disconnect() self.connection = nil end
  self.running = false
  self:_DestroyRings()
  self:_DestroyTransition()
  self:_DestroyHorizon()
  if self.fallback then self.fallback:Destroy() self.fallback = nil end
end

function OceanRenderer:GetStats()
  return self.stats
end

return OceanRenderer
