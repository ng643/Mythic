--!strict

local AssetService = game:GetService("AssetService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(game.ReplicatedStorage.Ocean.Shared.OceanConfig)
local QualityProfiles = require(game.ReplicatedStorage.Ocean.Shared.QualityProfiles)

local OceanRenderer = {}
OceanRenderer.__index = OceanRenderer

local DEFAULT_VERTICAL_BOUNDS = 64
local MAX_EDITABLE_EXTENT = 1900
local MAX_NEAR_RINGS = 6
local MAX_HORIZON_OBJECTS = 64
local MAX_INITIAL_VERTICES = 24000
local MAX_RING_FAILURES = 3
local HORIZON_TILE_MAX_SIZE = 1800
local HORIZON_REBASE_STUDS = 128
local UV_TILE_SCALE = 10
local DEFAULT_HORIZON_RANGE = 6000
local SEAM_COLORS = {
  Color3.fromRGB(255, 90, 90),
  Color3.fromRGB(90, 190, 255),
  Color3.fromRGB(130, 255, 130),
  Color3.fromRGB(255, 220, 100),
}

local function smoothstep(value: number): number
  local t = math.clamp(value, 0, 1)
  return t * t * (3 - 2 * t)
end

local function keyOf(x: number, z: number): string
  return string.format("%.3f:%.3f", x, z)
end

local function worldUV(worldXZ: Vector2): Vector2
  return Vector2.new(worldXZ.X / UV_TILE_SCALE, worldXZ.Y / UV_TILE_SCALE)
end
local function materialVariantName(): string
  local ocean = ReplicatedStorage:FindFirstChild("Ocean")
  local assets = ocean and ocean:FindFirstChild("Assets")
  local appearances = assets and assets:FindFirstChild("WaterAppearances")
  local slot = appearances and appearances:FindFirstChild("OceanWaterPBR")
  local value = slot and slot:GetAttribute("MaterialVariant")
  return type(value) == "string" and value or ""
end



local function setOceanPartProperties(part: MeshPart, runtime: Folder)
  part.Anchored = true
  part.CanCollide = false
  part.CanTouch = false
  part.CanQuery = false
  part.CastShadow = false
  part.Massless = true
  part.DoubleSided = true
  part.Material = Enum.Material.SmoothPlastic
  part.MaterialVariant = materialVariantName()
  part.Color = Color3.fromRGB(5, 62, 86)
  part.Reflectance = 0
  part.Transparency = 0
end

local function setFaceUVs(mesh, faceId: number, ids: {number}, runtime: Folder)
  local ok, reason = pcall(function()
    mesh:SetFaceUVs(faceId, ids)
  end)
  if not ok and runtime:GetAttribute("OceanUVError") == nil then
    local message = tostring(reason)
    runtime:SetAttribute("OceanUVError", message)
    warn("OceanRenderer | face UV assignment failed | " .. message)
  end
end

local function isFinite(value: number): boolean
  return value == value and value > -math.huge and value < math.huge
end

local function isFiniteVector3(value: Vector3): boolean
  return isFinite(value.X) and isFinite(value.Y) and isFinite(value.Z)
end

local function isSafeNormal(value: Vector3): boolean
  if not isFiniteVector3(value) then return false end
  local magnitude = value.Magnitude
  return isFinite(magnitude) and magnitude >= 0.5 and magnitude <= 1.5
end

local function recordRingFailure(ring, runtime: Folder, reason: any)
  ring.failureCount = (ring.failureCount or 0) + 1
  ring.lastError = tostring(reason)
  if ring.failureCount >= MAX_RING_FAILURES then
    ring.frozen = true
  end
  runtime:SetAttribute("OceanRingFailureLevel", ring.level)
  runtime:SetAttribute("OceanRingFailureCount", ring.failureCount)
  runtime:SetAttribute("OceanRingFailureReason", ring.lastError)
  runtime:SetAttribute("OceanRingFrozen", ring.frozen == true)
  if ring.failureCount == 1 or ring.frozen then
    warn(string.format("OceanRenderer | ring mutation skipped | level=%d | count=%d | %s", ring.level, ring.failureCount, ring.lastError))
  end
end

local function componentBound(state): number
  local bound = 0
  for _, component in ipairs(state.bankA) do
    bound += math.abs(component.amplitude)
  end
  for _, component in ipairs(state.bankB) do
    bound = math.max(bound, math.abs(component.amplitude))
  end
  return bound
end

local function makeIntervals(minimum: number, maximum: number, maxWidth: number): {{number}}
  local intervals = {}
  local cursor = minimum
  while cursor < maximum - 0.01 do
    local finish = math.min(cursor + maxWidth, maximum)
    table.insert(intervals, {cursor, finish})
    cursor = finish
  end
  return intervals
end

function OceanRenderer.new(waveField)
  local runtime = Workspace:FindFirstChild("OceanRuntime")
  if not runtime then
    runtime = Instance.new("Folder")
    runtime.Name = "OceanRuntime"
    runtime.Parent = Workspace
  end
  for _, child in ipairs(runtime:GetChildren()) do
    local name = child.Name
    if string.sub(name, 1, 14) == "OceanClipmap_L"
      or string.sub(name, 1, 13) == "OceanHorizon_"
      or name == "OceanFallbackSurface"
      or string.sub(name, 1, 18) == "OceanLOD_Boundary_" then
      child:Destroy()
    end
  end
  return setmetatable({
    waveField = waveField,
    runtime = runtime,
    qualityName = "High",
    profile = QualityProfiles.Get("High"),
    topologySpacing = QualityProfiles.Get("High").spacing,
    rings = {},
    horizonTiles = {},
    generation = 0,
    seamTimer = 0,
    visible = true,
    baseVisible = true,
    connection = nil,
    fallback = nil,
    horizonAnchor = Vector2.new(math.huge, math.huge),
    horizonAccumulator = 0,
    debugParts = {},
    debugSeams = false,
    stats = {
      vertexCount = 0,
      triangleCount = 0,
      horizonTileCount = 0,
      lastFrameMs = 0,
      lastOceanMs = 0,
      lastUpdateMs = 0,
      lastUVUpdateMs = 0,
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
    },
    serverTime = 0,
  }, OceanRenderer)
end

function OceanRenderer:_PublishStats()
  local stats = self.stats
  self.runtime:SetAttribute("OceanRingCount", stats.ringCount)
  self.runtime:SetAttribute("OceanRequestedRingCount", stats.requestedRingCount)
  self.runtime:SetAttribute("OceanHorizonTileCount", stats.horizonTileCount)
  self.runtime:SetAttribute("OceanSeamSampleCount", stats.seamSampleCount)
  self.runtime:SetAttribute("OceanHorizonFailed", stats.horizonFailed)
  self.runtime:SetAttribute("OceanRingFailureCount", stats.ringFailureCount)
  self.runtime:SetAttribute("OceanMeshGeneration", stats.meshGeneration)
  self.runtime:SetAttribute("OceanSeamMaxPositionError", stats.seamPositionError)
  self.runtime:SetAttribute("OceanSeamMaxNormalError", stats.seamNormalError)
  self.runtime:SetAttribute("OceanTopologyStatus", stats.topologyStatus)
  self.runtime:SetAttribute("OceanBatchAvailable", stats.batchAvailable)
end

function OceanRenderer:_DestroyRings()
  for _, ring in ipairs(self.rings) do
    if ring.part then ring.part:Destroy() end
    if ring.mesh then ring.mesh:Destroy() end
  end
  table.clear(self.rings)
  self.stats.vertexCount = 0
  self.stats.triangleCount = 0
  self.stats.batchAvailable = false
end

function OceanRenderer:_DestroyHorizon()
  for _, tile in ipairs(self.horizonTiles) do
    if tile.part then tile.part:Destroy() end
    if tile.mesh then tile.mesh:Destroy() end
  end
  table.clear(self.horizonTiles)
  self.stats.horizonTileCount = 0
end
function OceanRenderer:_DestroyDebugSeams()
  for _, group in ipairs(self.debugParts) do
    for _, part in ipairs(group.parts) do part:Destroy() end
  end
  table.clear(self.debugParts)
  self.debugSeams = false
  self.runtime:SetAttribute("OceanDebugSeamsActive", false)
end

function OceanRenderer:_UpdateDebugSeams()
  local enabled = self.runtime:GetAttribute("OceanDebugSeams") == true
  if enabled ~= self.debugSeams then
    self:_DestroyDebugSeams()
    self.debugSeams = enabled
    if enabled then
      for _, ring in ipairs(self.rings) do
        local color = SEAM_COLORS[ring.level % #SEAM_COLORS + 1]
        local parts = {}
        for edge = 1, 4 do
          local part = Instance.new("Part")
          part.Name = string.format("OceanLOD_Boundary_L%d_%d", ring.level, edge)
          part.Anchored = true
          part.CanCollide = false
          part.CanTouch = false
          part.CanQuery = false
          part.CastShadow = false
          part.Material = Enum.Material.Neon
          part.Color = color
          part.Transparency = 0.15
          part.Parent = self.runtime
          table.insert(parts, part)
        end
        table.insert(self.debugParts, {ring = ring, parts = parts})
      end
    end
  end
  if not enabled then return end
  local seaLevel = self.waveField:GetState().seaLevel
  for _, group in ipairs(self.debugParts) do
    local ring = group.ring
    local extent = ring.outerHalf * ring.spacing
    local origin = ring.origin
    local width = extent * 2
    group.parts[1].Size = Vector3.new(width, 0.06, 0.08)
    group.parts[1].Position = Vector3.new(origin.X, seaLevel + 0.08, origin.Y - extent)
    group.parts[2].Size = Vector3.new(width, 0.06, 0.08)
    group.parts[2].Position = Vector3.new(origin.X, seaLevel + 0.08, origin.Y + extent)
    group.parts[3].Size = Vector3.new(0.08, 0.06, width)
    group.parts[3].Position = Vector3.new(origin.X - extent, seaLevel + 0.08, origin.Y)
    group.parts[4].Size = Vector3.new(0.08, 0.06, width)
    group.parts[4].Position = Vector3.new(origin.X + extent, seaLevel + 0.08, origin.Y)
  end
  self.runtime:SetAttribute("OceanDebugSeamsActive", true)
end

function OceanRenderer:_CellIncluded(level: number, i: number, j: number, innerHalf: number): boolean
  if level == 0 then return true end
  return math.max(math.abs(i + 0.5), math.abs(j + 0.5)) >= innerHalf
end

function OceanRenderer:_BuildRing(level: number)
  local profile = self.profile
  local spacing = profile.spacing * 2 ^ level
  local outerHalf = math.floor((profile.resolution - 1) * 0.5)
  local innerHalf = level == 0 and 0 or outerHalf * 0.5
  local mesh, meshReason = AssetService:CreateEditableMesh()
  if not mesh then error("CreateEditableMesh ring failed: " .. tostring(meshReason)) end
  local vertexMap = {}
  local vertices = {}
  local normals = {}
  local uvs = {}
  local labels = {}
  local positions = {}
  local normalValues = {}

  local function getVertex(label: Vector2): number
    local mapKey = keyOf(label.X, label.Y)
    local existing = vertexMap[mapKey]
    if existing then return existing end
    local vertexId = mesh:AddVertex(Vector3.new(label.X, 0, label.Y))
    local normalId = mesh:AddNormal(Vector3.yAxis)
    local uvId = mesh:AddUV(worldUV(label))
    local index = #vertices + 1
    vertexMap[mapKey] = index
    vertices[index] = vertexId
    normals[index] = normalId
    uvs[index] = uvId
    labels[index] = label
    positions[index] = Vector3.new(label.X, 0, label.Y)
    normalValues[index] = Vector3.yAxis
    return index
  end

  local function edgeIsHole(i: number, j: number): boolean
    return level > 0 and not self:_CellIncluded(level, i, j, innerHalf)
  end

  local triangleCount = 0
  for j = -outerHalf, outerHalf - 1 do
    for i = -outerHalf, outerHalf - 1 do
      if self:_CellIncluded(level, i, j, innerHalf) then
        local aLabel = Vector2.new(i * spacing, j * spacing)
        local bLabel = Vector2.new(i * spacing, (j + 1) * spacing)
        local dLabel = Vector2.new((i + 1) * spacing, (j + 1) * spacing)
        local cLabel = Vector2.new((i + 1) * spacing, j * spacing)
        local boundaryEdges = {
          edgeIsHole(i - 1, j),
          edgeIsHole(i, j + 1),
          edgeIsHole(i + 1, j),
          edgeIsHole(i, j - 1),
        }
        local hasHoleEdge = boundaryEdges[1] or boundaryEdges[2] or boundaryEdges[3] or boundaryEdges[4]
        if not hasHoleEdge then
          local a = getVertex(aLabel)
          local b = getVertex(bLabel)
          local c = getVertex(cLabel)
          local d = getVertex(dLabel)
          local faceOne = mesh:AddTriangle(vertices[a], vertices[b], vertices[c])
          mesh:SetFaceNormals(faceOne, {normals[a], normals[b], normals[c]})
          setFaceUVs(mesh, faceOne, {uvs[a], uvs[b], uvs[c]}, self.runtime)
          local faceTwo = mesh:AddTriangle(vertices[c], vertices[b], vertices[d])
          mesh:SetFaceNormals(faceTwo, {normals[c], normals[b], normals[d]})
          setFaceUVs(mesh, faceTwo, {uvs[c], uvs[b], uvs[d]}, self.runtime)
          triangleCount += 2
        else
          local polygon = {aLabel, bLabel, dLabel, cLabel}
          local labelsForEdges = {{i - 1, j}, {i, j + 1}, {i + 1, j}, {i, j - 1}}
          local expanded = {}
          for edgeIndex, label in ipairs(polygon) do
            table.insert(expanded, label)
            local neighbor = labelsForEdges[edgeIndex]
            if edgeIsHole(neighbor[1], neighbor[2]) then
              local nextLabel = polygon[edgeIndex % #polygon + 1]
              table.insert(expanded, (label + nextLabel) * 0.5)
            end
          end
          local center = getVertex((aLabel + bLabel + cLabel + dLabel) * 0.25)
          for polygonIndex, label in ipairs(expanded) do
            local nextLabel = expanded[polygonIndex % #expanded + 1]
            local first = getVertex(label)
            local second = getVertex(nextLabel)
            local face = mesh:AddTriangle(vertices[center], vertices[first], vertices[second])
            mesh:SetFaceNormals(face, {normals[center], normals[first], normals[second]})
            setFaceUVs(mesh, face, {uvs[center], uvs[first], uvs[second]}, self.runtime)
            triangleCount += 1
          end
        end
      end
    end
  end

  local state = self.waveField:GetState()
  local verticalBound = math.clamp(math.max(DEFAULT_VERTICAL_BOUNDS, componentBound(state) * 2 + 8), 16, 96)
  mesh:AddVertex(Vector3.new(0, -verticalBound, 0))
  mesh:AddVertex(Vector3.new(0, verticalBound, 0))
  local part = AssetService:CreateMeshPartAsync(Content.fromObject(mesh))
  part.Name = string.format("OceanClipmap_L%d", level)
  setOceanPartProperties(part, self.runtime)
  part.DoubleSided = level == 0
  part.Parent = self.runtime

  local fullCap = self.waveField:GetGameplayComponentCap()
  local nextCap = level + 1 < self.profile.ringCount and math.min(self.profile.waveCap, fullCap) or math.min(6, fullCap)
  local ring = {
    level = level,
    mesh = mesh,
    part = part,
    vertices = vertices,
    normals = normals,
    uvs = uvs,
    labels = labels,
    labelIndex = vertexMap,
    positions = positions,
    normalValues = normalValues,
    spacing = spacing,
    outerHalf = outerHalf,
    innerHalf = innerHalf,
    origin = Vector2.new(math.huge, math.huge),
    accumulator = 0,
    cadence = 1 / math.max(profile.nearCadence / 2 ^ level, 3),
    componentCap = level == 0 and fullCap or math.min(profile.waveCap, fullCap),
    sharedComponentCap = nextCap,
    updateNormals = level <= profile.normalRings,
    triangleCount = triangleCount,
    batchAvailable = false,
    failed = false,
    frozen = false,
    failureCount = 0,
    invalidFrames = 0,
    lastError = nil,
    generation = self.generation,
  }
  pcall(function() ring.batchAvailable = type(mesh.BatchSetValues) == "function" end)
  self.stats.vertexCount += #vertices
  self.stats.triangleCount += triangleCount
  self.stats.batchAvailable = self.stats.batchAvailable or ring.batchAvailable
  table.insert(self.rings, ring)
end

function OceanRenderer:_BuildFallback()
  if self.fallback then return end
  local part = Instance.new("Part")
  part.Name = "OceanFallbackSurface"
  part.Anchored = true
  part.CanCollide = false
  part.CanTouch = false
  part.CanQuery = false
  part.CastShadow = false
  part.Material = Enum.Material.SmoothPlastic
  part.Color = Color3.fromRGB(5, 62, 86)
  part.Reflectance = 0
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
  self:_DestroyHorizon()
  self:_BuildFallback()
end

function OceanRenderer:_BuildHorizon()
  self:_DestroyHorizon()
  local range = math.min(self.profile.horizonRange or DEFAULT_HORIZON_RANGE, DEFAULT_HORIZON_RANGE)
  local tileSize = math.min(self.profile.horizonTileSize or HORIZON_TILE_MAX_SIZE, HORIZON_TILE_MAX_SIZE)
  local finalExtent = 0
  for _, ring in ipairs(self.rings) do
    finalExtent = math.max(finalExtent, ring.outerHalf * ring.spacing)
  end
  local innerExtent = math.min(math.max(finalExtent, 0), range - 1)
  local seaLevel = self.waveField:GetState().seaLevel

  local function addTile(xMin: number, xMax: number, zMin: number, zMax: number)
    local width = xMax - xMin
    local depth = zMax - zMin
    if width <= 0.01 or depth <= 0.01 then return end
    if #self.horizonTiles >= MAX_HORIZON_OBJECTS then
      error(string.format("horizon object budget exceeded: %d", MAX_HORIZON_OBJECTS))
    end
    local part = Instance.new("Part")
    part.Name = string.format("OceanHorizon_%d", #self.horizonTiles + 1)
    part.Anchored = true
    part.CanCollide = false
    part.CanTouch = false
    part.CanQuery = false
    part.CastShadow = false
    part.Material = Enum.Material.SmoothPlastic
    part.MaterialVariant = materialVariantName()
    part.Color = Color3.fromRGB(5, 62, 86)
    part.Reflectance = 0
    part.Transparency = 0
    part.Size = Vector3.new(width, 0.25, depth)
    part.Position = Vector3.new((xMin + xMax) * 0.5, seaLevel, (zMin + zMax) * 0.5)
    part.Parent = self.runtime
    table.insert(self.horizonTiles, {
      part = part,
      mesh = nil,
      static = true,
      center = Vector2.new((xMin + xMax) * 0.5, (zMin + zMax) * 0.5),
      width = width,
      depth = depth,
      origin = Vector2.new(math.huge, math.huge),
      generation = self.generation,
      failed = false,
    })
  end

  local fullX = makeIntervals(-range, range, tileSize)
  local middleZ = makeIntervals(-innerExtent, innerExtent, tileSize)
  local northZ = makeIntervals(innerExtent, range, tileSize)
  local southZ = makeIntervals(-range, -innerExtent, tileSize)
  local eastX = makeIntervals(innerExtent, range, tileSize)
  local westX = makeIntervals(-range, -innerExtent, tileSize)

  for _, xInterval in ipairs(fullX) do
    for _, zInterval in ipairs(northZ) do
      addTile(xInterval[1], xInterval[2], zInterval[1], zInterval[2])
    end
    for _, zInterval in ipairs(southZ) do
      addTile(xInterval[1], xInterval[2], zInterval[1], zInterval[2])
    end
  end
  for _, xInterval in ipairs(eastX) do
    for _, zInterval in ipairs(middleZ) do
      addTile(xInterval[1], xInterval[2], zInterval[1], zInterval[2])
    end
  end
  for _, xInterval in ipairs(westX) do
    for _, zInterval in ipairs(middleZ) do
      addTile(xInterval[1], xInterval[2], zInterval[1], zInterval[2])
    end
  end

  self.stats.horizonTileCount = #self.horizonTiles
  self.runtime:SetAttribute("OceanHorizonMeshFallback", false)
  self.runtime:SetAttribute("OceanHorizonCoverage", "four-band-annulus")
  self.runtime:SetAttribute("OceanHorizonObjectCount", #self.horizonTiles)
end

function OceanRenderer:_Sample(worldXZ: Vector2, serverTime: number, componentCap: number)
  return self.waveField:SampleLagrangian(worldXZ, serverTime, {
    inverseIterations = 2,
    includeEvents = true,
    componentCap = componentCap,
    foamMultiplier = 1,
  })
end

function OceanRenderer:_UpdateRing(ring, serverTime: number, cameraPosition: Vector3)
  if ring.generation ~= self.generation or ring.frozen then return end
  local baseSpacing = self.topologySpacing or ring.spacing
  local snapped = Vector2.new(
    math.floor(cameraPosition.X / baseSpacing + 0.5) * baseSpacing,
    math.floor(cameraPosition.Z / baseSpacing + 0.5) * baseSpacing
  )
  local state = self.waveField:GetState()
  local seaLevel = state.seaLevel
  local function fail(reason: any)
    self.stats.ringFailureCount += 1
    recordRingFailure(ring, self.runtime, reason)
  end
  if snapped ~= ring.origin then
    ring.origin = snapped
    ring.part.CFrame = CFrame.new(snapped.X, seaLevel, snapped.Y)
    local uvStart = os.clock()
    for index, label in ipairs(ring.labels) do
      local worldLabel = snapped + label
      local ok, reason = pcall(function() ring.mesh:SetUV(ring.uvs[index], worldUV(worldLabel)) end)
      if not ok and self.runtime:GetAttribute("OceanUVError") == nil then
        local message = tostring(reason)
        self.runtime:SetAttribute("OceanUVError", message)
        warn("OceanRenderer | world UV update failed | " .. message)
      end
    end
    self.stats.lastUVUpdateMs += (os.clock() - uvStart) * 1000
  end
  local outerExtent = math.max(ring.outerHalf * ring.spacing, 1)
  for index, localLabel in ipairs(ring.labels) do
    local worldLabel = ring.origin + localLabel
    local full = self:_Sample(worldLabel, serverTime, ring.componentCap)
    local shared = ring.componentCap == ring.sharedComponentCap
      and full
      or self:_Sample(worldLabel, serverTime, ring.sharedComponentCap)
    local edge = math.max(math.abs(localLabel.X), math.abs(localLabel.Y)) / outerExtent
    local residualWeight = edge > 0.68 and 1 - smoothstep((edge - 0.68) / 0.32) or 1
    local baseWorld = Vector3.new(worldLabel.X, seaLevel, worldLabel.Y)
    local sharedDisplacement = shared.position - baseWorld
    local fullDisplacement = full.position - baseWorld
    local displacement = sharedDisplacement:Lerp(fullDisplacement, residualWeight)
    if not isFiniteVector3(displacement) or displacement.Magnitude > DEFAULT_VERTICAL_BOUNDS * 2 then
      fail(string.format("invalid displacement index=%d", index))
      return
    end
    ring.positions[index] = Vector3.new(localLabel.X, 0, localLabel.Y) + displacement
    if not isFiniteVector3(ring.positions[index]) then
      fail(string.format("invalid position index=%d", index))
      return
    end
    if ring.updateNormals then
      local normal = shared.normal:Lerp(full.normal, residualWeight)
      if not isSafeNormal(normal) then
        fail(string.format("invalid normal index=%d", index))
        return
      end
      ring.normalValues[index] = normal.Unit
    end
  end
  if #ring.positions ~= #ring.vertices or #ring.normalValues ~= #ring.normals then
    fail("attribute array length mismatch")
    return
  end

  local mesh = ring.mesh
  local start = os.clock()
  local vertexOk, vertexReason = pcall(function()
    debug.profilebegin("Ocean/VertexCommit")
    if ring.batchAvailable then
      local batchOk, batchReason = pcall(function()
        mesh:BatchSetValues(ring.vertices, ring.positions)
      end)
      if not batchOk then
        ring.batchAvailable = false
        self.stats.batchAvailable = false
        if not ring.batchWarned then
          ring.batchWarned = true
          warn("OceanRenderer | BatchSetValues position failed | " .. tostring(batchReason))
        end
      end
    end
    if not ring.batchAvailable then
      for index, vertexId in ipairs(ring.vertices) do
        mesh:SetPosition(vertexId, ring.positions[index])
      end
    end
  end)
  pcall(debug.profileend)
  if not vertexOk then
    fail("vertex commit failed: " .. tostring(vertexReason))
    self.stats.lastUpdateMs += (os.clock() - start) * 1000
    return
  end

  if ring.updateNormals then
    local normalOk, normalReason = pcall(function()
      debug.profilebegin("Ocean/Normals")
      if ring.batchAvailable then
        local batchOk, batchReason = pcall(function()
          mesh:BatchSetValues(ring.normals, ring.normalValues)
        end)
        if not batchOk then
          ring.batchAvailable = false
          self.stats.batchAvailable = false
          if not ring.batchWarned then
            ring.batchWarned = true
            warn("OceanRenderer | BatchSetValues normal failed | " .. tostring(batchReason))
          end
        end
      end
      if not ring.batchAvailable then
        for index, normalId in ipairs(ring.normals) do
          mesh:SetNormal(normalId, ring.normalValues[index])
        end
      end
    end)
    pcall(debug.profileend)
    if not normalOk then
      fail("normal commit failed: " .. tostring(normalReason))
      self.stats.lastUpdateMs += (os.clock() - start) * 1000
      return
    end
  end
  ring.invalidFrames = 0
  ring.failureCount = 0
  ring.lastCommittedServerTime = serverTime
  self.stats.lastUpdateMs += (os.clock() - start) * 1000
end

function OceanRenderer:_UpdateHorizonTile(tile, serverTime: number)
  if tile.generation ~= self.generation or tile.failed then return end
  local seaLevel = self.waveField:GetState().seaLevel
  local anchor = self.horizonAnchor
  if tile.origin ~= anchor then
    tile.origin = anchor
    tile.part.Position = Vector3.new(anchor.X + tile.center.X, seaLevel, anchor.Y + tile.center.Y)
  end
end

function OceanRenderer:_UpdateSeamStats()
  local maxPosition = 0
  local maxNormal = 0
  local sampleCount = 0
  local function committedAt(ring, world: Vector2)
    local localLabel = world - ring.origin
    local index = ring.labelIndex and ring.labelIndex[keyOf(localLabel.X, localLabel.Y)]
    if not index then return nil, nil end
    return ring.part.Position + ring.positions[index], ring.normalValues[index]
  end
  for level = 1, #self.rings - 1 do
    local fine = self.rings[level]
    local coarse = self.rings[level + 1]
    local boundary = fine.outerHalf * fine.spacing
    local sampleCountOnEdge = math.floor(boundary / coarse.spacing + 0.001)
    for sampleIndex = -sampleCountOnEdge, sampleCountOnEdge do
      local offset = sampleIndex * coarse.spacing
      local points = {
        Vector2.new(-boundary, offset),
        Vector2.new(boundary, offset),
        Vector2.new(offset, -boundary),
        Vector2.new(offset, boundary),
      }
      for _, point in ipairs(points) do
        local world = fine.origin + point
        local finePosition, fineNormal = committedAt(fine, world)
        local coarsePosition, coarseNormal = committedAt(coarse, world)
        if finePosition and coarsePosition and fineNormal and coarseNormal then
          sampleCount += 1
          maxPosition = math.max(maxPosition, (finePosition - coarsePosition).Magnitude)
          maxNormal = math.max(maxNormal, math.deg(math.acos(math.clamp(fineNormal:Dot(coarseNormal), -1, 1))))
        end
      end
    end
  end
  self.stats.seamPositionError = maxPosition
  self.stats.seamNormalError = maxNormal
  self.stats.seamSampleCount = sampleCount
  self.stats.topologyStatus = sampleCount > 0 and "committed-geometry" or "awaiting-geometry"
end

function OceanRenderer:_Build()
  self.generation += 1
  self.topologySpacing = self.profile.spacing
  self:_DestroyDebugSeams()
  self:_DestroyRings()
  self:_DestroyHorizon()
  if self.fallback then
    self.fallback:Destroy()
    self.fallback = nil
  end
  self.stats.fallback = false
  self.stats.horizonFailed = false
  self.stats.ringFailureCount = 0
  self.stats.meshGeneration = self.generation
  self.stats.requestedRingCount = math.min(self.profile.ringCount, MAX_NEAR_RINGS)
  self.runtime:SetAttribute("OceanRendererNearMeshBudget", MAX_NEAR_RINGS)
  self.runtime:SetAttribute("OceanRendererVertexBudget", MAX_INITIAL_VERTICES)
  self.runtime:SetAttribute("OceanRendererHorizonBudget", MAX_HORIZON_OBJECTS)
  local buildStarted = os.clock()
  local nearOk, nearReason = pcall(function()
    for level = 0, self.stats.requestedRingCount - 1 do
      local extent = self.profile.spacing * 2 ^ level * (self.profile.resolution - 1)
      if extent > MAX_EDITABLE_EXTENT then break end
      self:_BuildRing(level)
      if self.stats.vertexCount > MAX_INITIAL_VERTICES then
        error(string.format("near vertex budget exceeded: %d", MAX_INITIAL_VERTICES))
      end
    end
    if #self.rings == 0 then error("no near rings were created") end
  end)
  if not nearOk then
    local message = tostring(nearReason)
    self.runtime:SetAttribute("OceanRendererBuildError", message)
    self:_UseFallback(message)
  else
    self.runtime:SetAttribute("OceanRendererBuildError", nil)
    local horizonOk, horizonReason = pcall(function() self:_BuildHorizon() end)
    if not horizonOk then
      self:_DestroyHorizon()
      self.stats.horizonFailed = true
      self.runtime:SetAttribute("OceanHorizonBuildError", tostring(horizonReason))
      self.runtime:SetAttribute("OceanHorizonFailed", true)
      warn("OceanRenderer | horizon disabled: " .. tostring(horizonReason))
    else
      self.runtime:SetAttribute("OceanHorizonBuildError", nil)
      self.runtime:SetAttribute("OceanHorizonFailed", false)
    end
  end
  self.runtime:SetAttribute("OceanRendererBuildMs", (os.clock() - buildStarted) * 1000)
  self.stats.ringCount = #self.rings
  self:_PublishStats()
  self:_UpdateDebugSeams()
end

function OceanRenderer:SetQuality(profileName: string)
  if profileName == "Fallback" then
    return {topologyChanged = false, rejected = true, reason = "fallback is initialization-only"}
  end
  local nextProfile = QualityProfiles.Get(profileName)
  if not nextProfile or nextProfile.resolution == 0 then
    return {topologyChanged = false, rejected = true, reason = "unknown quality profile"}
  end
  if self.qualityName == profileName then
    return {topologyChanged = false, unchanged = true}
  end
  self.qualityName = profileName
  self.profile = nextProfile
  if self.running then
    local fullCap = self.waveField:GetGameplayComponentCap()
    for _, ring in ipairs(self.rings) do
      ring.cadence = 1 / math.max(nextProfile.nearCadence / 2 ^ ring.level, 3)
      ring.componentCap = ring.level == 0 and fullCap or math.min(nextProfile.waveCap, fullCap)
      ring.sharedComponentCap = ring.level + 1 < #self.rings
        and math.min(nextProfile.waveCap, fullCap)
        or math.min(6, fullCap)
      ring.updateNormals = ring.level <= nextProfile.normalRings
    end
  else
    self.topologySpacing = nextProfile.spacing
  end
  self.runtime:SetAttribute("OceanQualityTopologyChanged", false)
  return {topologyChanged = false}
end

function OceanRenderer:SetBaseVisible(visible: boolean)
  self.baseVisible = visible
  for _, ring in ipairs(self.rings) do ring.part.Transparency = visible and 0 or 1 end
  for _, tile in ipairs(self.horizonTiles) do tile.part.Transparency = visible and 0 or 1 end
  if self.fallback then self.fallback.Transparency = visible and 0.05 or 1 end
end

function OceanRenderer:SetVisible(visible: boolean)
  self.visible = visible
  self:SetBaseVisible(visible)
end

function OceanRenderer:_Update(dt: number)
  if not self.running then return end
  local camera = Workspace.CurrentCamera
  if not camera then return end
  local start = os.clock()
  self.stats.lastUpdateMs = 0
  self.stats.lastUVUpdateMs = 0
  self.serverTime = self.waveField:StepClock(dt)
  if not self.stats.fallback then
    for _, ring in ipairs(self.rings) do
      ring.accumulator += dt
      if ring.accumulator >= ring.cadence then
        ring.accumulator %= ring.cadence
        self:_UpdateRing(ring, self.serverTime, camera.CFrame.Position)
      end
    end
    local horizonSpacing = math.max(self.topologySpacing or self.profile.spacing, HORIZON_REBASE_STUDS)
    self.horizonAnchor = Vector2.new(
      math.floor(camera.CFrame.Position.X / horizonSpacing + 0.5) * horizonSpacing,
      math.floor(camera.CFrame.Position.Z / horizonSpacing + 0.5) * horizonSpacing
    )
    self:_UpdateDebugSeams()
    self.horizonAccumulator += dt
    if self.horizonAccumulator >= 0.5 then
      self.horizonAccumulator = 0
      for _, tile in ipairs(self.horizonTiles) do
        self:_UpdateHorizonTile(tile, self.serverTime)
      end
    end
    local frozenCount = 0
    for _, ring in ipairs(self.rings) do
      if ring.frozen then frozenCount += 1 end
    end
    self.runtime:SetAttribute("OceanFrozenRingCount", frozenCount)
    for _, tile in ipairs(self.horizonTiles) do
      if tile.failed then
        self.stats.horizonFailed = true
        self.runtime:SetAttribute("OceanHorizonFailed", true)
      end
    end
    self.seamTimer += dt
    if self.seamTimer >= 0.5 then
      self.seamTimer = 0
      self:_UpdateSeamStats()
    end
  else
    if self.fallback then
      self.fallback.Position = Vector3.new(camera.CFrame.Position.X, self.waveField:GetState().seaLevel, camera.CFrame.Position.Z)
    end
  end
  self.stats.lastOceanMs = (os.clock() - start) * 1000
  self.stats.lastFrameMs = dt * 1000
  self:_PublishStats()
end

function OceanRenderer:Start()
  if self.running then return end
  self.running = true
  self:_Build()
  self.connection = RunService.RenderStepped:Connect(function(dt) self:_Update(dt) end)
end

function OceanRenderer:Stop()
  self.generation += 1
  self:_DestroyDebugSeams()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  self.running = false
  self:_DestroyRings()
  self:_DestroyHorizon()
  if self.fallback then self.fallback:Destroy() self.fallback = nil end
end

function OceanRenderer:GetStats()
  return self.stats
end

return OceanRenderer
