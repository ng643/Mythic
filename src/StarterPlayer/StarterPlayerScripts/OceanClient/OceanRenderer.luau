--!strict

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(game.ReplicatedStorage.Ocean.Shared.OceanConfig)
local QualityProfiles = require(game.ReplicatedStorage.Ocean.Shared.QualityProfiles)

local OceanRenderer = {}
OceanRenderer.__index = OceanRenderer

local TWO_PI = math.pi * 2
local DEFAULT_VERTICAL_BOUNDS = 64

local function applyWaterSurfaceAppearance(part: MeshPart)
  local slot = game.ReplicatedStorage.Ocean.Assets.WaterAppearances:FindFirstChild("OceanWaterPBR")
  local function asset(name: string, fallback: string): string
    local value = slot and slot:GetAttribute(name)
    return type(value) == "string" and value or fallback
  end
  local appearance = part:FindFirstChild("OceanSurfaceAppearance")
  if not appearance then
    appearance = Instance.new("SurfaceAppearance")
    appearance.Name = "OceanSurfaceAppearance"
    appearance.Parent = part
  end
  pcall(function()
    appearance.ColorMap = asset("ColorMap", "rbxassetid://128922037556159")
    appearance.NormalMap = asset("NormalMap", "rbxassetid://101286961773967")
    appearance.RoughnessMap = asset("RoughnessMap", "rbxassetid://111100454366205")
    appearance.MetalnessMap = asset("MetalnessMap", "rbxassetid://126230944196062")
    appearance.AlphaMode = Enum.AlphaMode.Opaque
  end)
end

local function setOceanPartProperties(part: MeshPart)
  part.Anchored = true
  part.CanCollide = false
  part.CanTouch = false
  part.CanQuery = false
  part.CastShadow = false
  part.Massless = true
  part.DoubleSided = true
  part.Material = Enum.Material.SmoothPlastic
  part.MaterialVariant = "OceanWater"
  part.Color = Color3.fromRGB(5, 62, 86)
  part.Reflectance = 0
  part.Transparency = 0
  applyWaterSurfaceAppearance(part)
end

local function cellIncluded(level: number, i: number, j: number, innerHalf: number): boolean
  if level == 0 then
    return true
  end
  -- Donut cells are disjoint; the inner edge is aligned to the previous
  -- ring's outer edge and the outer edge morphs to mean sea level.
  return math.max(math.abs(i), math.abs(j)) >= innerHalf
end

function OceanRenderer.new(waveField)
  local runtime = Workspace:FindFirstChild("OceanRuntime")
  if not runtime then
    runtime = Instance.new("Folder")
    runtime.Name = "OceanRuntime"
    runtime.Parent = Workspace
  end
  return setmetatable({
    waveField = waveField,
    runtime = runtime,
    qualityName = "High",
    profile = QualityProfiles.Get("High"),
    rings = {},
    running = false,
    visible = true,
    baseVisible = true,
    farVisible = true,
    connection = nil,
    fallback = nil,
    farPlane = nil,
    stats = {vertexCount = 0, triangleCount = 0, lastFrameMs = 0, lastOceanMs = 0, lastUpdateMs = 0, ringCount = 0, fallback = false, batchAvailable = false},
    serverTime = 0,
  }, OceanRenderer)
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

function OceanRenderer:_BuildRing(level: number)
  local profile = self.profile
  local baseSpacing = profile.spacing
  local spacing = baseSpacing * 2 ^ level
  local outerHalf = math.floor((profile.resolution - 1) * 0.5)
  local innerHalf = level == 0 and -1 or math.max(1, math.floor(outerHalf * 0.5 + 0.5))
  local mesh = AssetService:CreateEditableMesh()
  local vertexMap: {[string]: number} = {}
  local vertices: {number} = {}
  local normals: {number} = {}
  local uvs: {number} = {}
  local labels: {Vector2} = {}
  local positions: {Vector3} = {}
  local normalValues: {Vector3} = {}
  local function key(i: number, j: number): string
    return tostring(i) .. ":" .. tostring(j)
  end
  local function getVertex(i: number, j: number): number
    local mapKey = key(i, j)
    local existing = vertexMap[mapKey]
    if existing then
      return existing
    end
    local label = Vector2.new(i * spacing, j * spacing)
    local id = mesh:AddVertex(Vector3.new(label.X, 0, label.Y))
    local normalId = mesh:AddNormal(Vector3.yAxis)
    local uvId = mesh:AddUV(Vector2.new(label.X / 10, label.Y / 10))
    local index = #vertices + 1
    vertexMap[mapKey] = index
    vertices[index] = id
    normals[index] = normalId
    uvs[index] = uvId
    labels[index] = label
    positions[index] = Vector3.new(label.X, 0, label.Y)
    normalValues[index] = Vector3.yAxis
    return index
  end

  local triangleCount = 0
  for j = -outerHalf, outerHalf - 1 do
    for i = -outerHalf, outerHalf - 1 do
      if cellIncluded(level, i, j, innerHalf) then
        local a = getVertex(i, j)
        local b = getVertex(i, j + 1)
        local c = getVertex(i + 1, j)
        local d = getVertex(i + 1, j + 1)
        local faceOne = mesh:AddTriangle(vertices[a], vertices[b], vertices[c])
        mesh:SetFaceNormals(faceOne, {normals[a], normals[b], normals[c]})
        pcall(function() mesh:SetFaceUVs(faceOne, {uvs[a], uvs[b], uvs[c]}) end)
        local faceTwo = mesh:AddTriangle(vertices[c], vertices[b], vertices[d])
        mesh:SetFaceNormals(faceTwo, {normals[c], normals[b], normals[d]})
        pcall(function() mesh:SetFaceUVs(faceTwo, {uvs[c], uvs[b], uvs[d]}) end)
        triangleCount += 2
      end
    end
  end

  -- Bounds are derived from the active bank instead of a paper-thin mesh.
  local verticalBound = DEFAULT_VERTICAL_BOUNDS
  local state = self.waveField:GetState()
  local componentBound = 0
  for _, component in ipairs(state.bankA) do componentBound += math.abs(component.amplitude) end
  for _, component in ipairs(state.bankB) do componentBound = math.max(componentBound, math.abs(component.amplitude)) end
  verticalBound = math.clamp(math.max(verticalBound, componentBound * 2 + 8), 16, 96)
  local function addSkirtEdge(i1: number, j1: number, i2: number, j2: number)
    local upperA = getVertex(i1, j1)
    local upperB = getVertex(i2, j2)
    local lowerA = mesh:AddVertex(Vector3.new(i1 * spacing, -verticalBound, j1 * spacing))
    local lowerB = mesh:AddVertex(Vector3.new(i2 * spacing, -verticalBound, j2 * spacing))
    mesh:AddTriangle(vertices[upperA], vertices[upperB], lowerA)
    mesh:AddTriangle(vertices[upperB], lowerB, lowerA)
    triangleCount += 2
  end
  local function addSkirtLoop(minIndex: number, maxIndex: number)
    for i = minIndex, maxIndex - 1 do addSkirtEdge(i, minIndex, i + 1, minIndex) end
    for j = minIndex, maxIndex - 1 do addSkirtEdge(maxIndex, j, maxIndex, j + 1) end
    for i = maxIndex, minIndex + 1, -1 do addSkirtEdge(i, maxIndex, i - 1, maxIndex) end
    for j = maxIndex, minIndex + 1, -1 do addSkirtEdge(minIndex, j, minIndex, j - 1) end
  end
  addSkirtLoop(-outerHalf, outerHalf)
  if level > 0 then addSkirtLoop(-innerHalf, innerHalf) end
  mesh:AddVertex(Vector3.new(0, -verticalBound, 0))
  mesh:AddVertex(Vector3.new(0, verticalBound, 0))
  local batchAvailable = false
  pcall(function() batchAvailable = type(mesh.BatchSetValues) == "function" end)
  local part = AssetService:CreateMeshPartAsync(Content.fromObject(mesh))
  part.Name = string.format("OceanClipmap_L%d", level)
  setOceanPartProperties(part)
  part.DoubleSided = level == 0
  part.Parent = self.runtime
  local ring = {
    level = level,
    mesh = mesh,
    part = part,
    vertices = vertices,
    normals = normals,
    uvs = uvs,
    labels = labels,
    positions = positions,
    normalValues = normalValues,
    spacing = spacing,
    origin = Vector2.new(math.huge, math.huge),
    accumulator = 0,
    cadence = 1 / math.max(profile.nearCadence / 2 ^ level, 3),
    -- LOD0 is the gameplay-authoritative full bank; outer rings use the
    -- profile cap with the bank's semantic long-wave ordering.
    componentCap = level == 0 and self.waveField:GetGameplayComponentCap() or math.min(profile.waveCap, self.waveField:GetGameplayComponentCap()),
    updateNormals = level <= profile.normalRings,
    triangleCount = triangleCount,
    batchAvailable = batchAvailable,
    failed = false,
  }
  self.stats.vertexCount += #vertices
  self.stats.triangleCount += triangleCount
  self.stats.batchAvailable = self.stats.batchAvailable or batchAvailable
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
  part.MaterialVariant = "OceanWater"
  part.Color = Color3.fromRGB(5, 62, 86)
  part.Reflectance = 0
  part.Size = Vector3.new(8192, 0.25, 8192)
  part.Position = Vector3.new(0, 0, 0)
  part.Transparency = 0.05
  part.Parent = self.runtime
  self.fallback = part
  self.stats.fallback = true
end

function OceanRenderer:_BuildFarPlane()
  if self.farPlane then return end
  local part = Instance.new("Part")
  part.Name = "OceanFarPlane"
  part.Anchored = true
  part.CanCollide = false
  part.CanTouch = false
  part.CanQuery = false
  part.CastShadow = false
  part.Material = Enum.Material.SmoothPlastic
  part.MaterialVariant = "OceanWater"
  part.Color = Color3.fromRGB(5, 62, 86)
  part.Reflectance = 0
  part.Size = Vector3.new(8192, 0.25, 8192)
  part.Transparency = 0
  part.Parent = self.runtime
  self.farPlane = part
end

function OceanRenderer:_UseFallback(reason: string)
  if not self.stats.fallback then
    warn("OceanRenderer | falling back to static surface: " .. reason)
  end
  self:_DestroyRings()
  if self.farPlane then
    self.farPlane:Destroy()
    self.farPlane = nil
  end
  self:_BuildFallback()
end

function OceanRenderer:_Build()
  self:_DestroyRings()
  if self.fallback then
    self.fallback:Destroy()
    self.fallback = nil
  end
  if self.farPlane then
    self.farPlane:Destroy()
    self.farPlane = nil
  end
  self.stats.fallback = false
  local ok, reason = pcall(function()
    local ringLimit = self.runtime:GetAttribute("OceanExperimentalClipmaps") == false and 1 or self.profile.ringCount
    -- EditableMesh MeshPart extents are capped by the engine; stop before
    -- allocation failure and keep the already-built inner rings.
    local maxEditableExtent = 1900
    for level = 0, ringLimit - 1 do
      local levelExtent = self.profile.spacing * 2 ^ level * (self.profile.resolution - 1)
      if levelExtent > maxEditableExtent then
        break
      end
      self:_BuildRing(level)
    end
  end)
  if not ok then
    self:_UseFallback(tostring(reason))
  elseif not self.stats.fallback then
    self:_BuildFarPlane()
  end
  self:SetBaseVisible(self.baseVisible)
  self:SetFarVisible(self.farVisible)
  self.stats.ringCount = #self.rings
end

function OceanRenderer:SetQuality(profileName: string)
  if profileName == "Fallback" then
    self.qualityName = profileName
    self.profile = QualityProfiles.Get(profileName)
    self:_UseFallback("quality override")
    return
  end
  local nextProfile = QualityProfiles.Get(profileName)
  if not nextProfile or nextProfile.resolution == 0 then
    return
  end
  self.qualityName = profileName
  self.profile = nextProfile
  if self.running then
    self:_Build()
  end
end

function OceanRenderer:SetBaseVisible(visible: boolean)
  self.baseVisible = visible
  for _, ring in ipairs(self.rings) do
    ring.part.Transparency = visible and 0.04 or 1
  end
  if self.fallback then
    self.fallback.Transparency = visible and 0.05 or 1
  end
end

function OceanRenderer:SetFarVisible(visible: boolean)
  self.farVisible = visible
  if self.farPlane then
    self.farPlane.Transparency = visible and 0 or 1
  end
end

function OceanRenderer:SetVisible(visible: boolean)
  self.visible = visible
  self:SetBaseVisible(visible)
  self:SetFarVisible(visible)
end

function OceanRenderer:_UpdateRing(ring, serverTime: number, cameraPosition: Vector3)
  local spacing = ring.spacing
  -- All levels share a finest-grid anchor. Independent snapping would move
  -- nested boundaries to different world coordinates and expose cracks.
  local anchorSpacing = self.profile.spacing
  local snapped = Vector2.new(
    math.floor(cameraPosition.X / anchorSpacing + 0.5) * anchorSpacing,
    math.floor(cameraPosition.Z / anchorSpacing + 0.5) * anchorSpacing
  )
  if snapped ~= ring.origin then
    ring.origin = snapped
    ring.part.CFrame = CFrame.new(snapped.X, self.waveField:GetState().seaLevel, snapped.Y)
  end
  local origin = ring.origin
  local seaLevel = self.waveField:GetState().seaLevel
  local outerExtent = math.max((self.profile.resolution - 1) * 0.5 * spacing, 1)
  local sampleOptions = {
    inverseIterations = 1,
    includeEvents = true,
    componentCap = ring.componentCap,
    foamMultiplier = 1,
  }
  debug.profilebegin("Ocean/WaveEvaluate")
  for index, localLabel in ipairs(ring.labels) do
    local worldLabel = origin + localLabel
    local sample = self.waveField:SampleLagrangian(worldLabel, serverTime, sampleOptions)
    local edge = math.max(math.abs(localLabel.X), math.abs(localLabel.Y)) / outerExtent
    local morph = 1
    if edge > 0.72 then
      local t = math.clamp((edge - 0.72) / 0.28, 0, 1)
      morph = 1 - t * t * (3 - 2 * t)
    end
    local baseWorld = Vector3.new(worldLabel.X, seaLevel, worldLabel.Y)
    local displacement = sample.position - baseWorld
    ring.positions[index] = Vector3.new(localLabel.X, 0, localLabel.Y) + displacement * morph
    if ring.updateNormals then
      ring.normalValues[index] = sample.normal:Lerp(Vector3.yAxis, 1 - morph).Unit
    end
  end
  debug.profileend()
  local mesh = ring.mesh
  local start = os.clock()
  local ok = pcall(function()
    debug.profilebegin("Ocean/VertexCommit")
    if ring.batchAvailable then
      local batchOk = pcall(function()
        mesh:BatchSetValues(Enum.MeshAttribute.Position, ring.vertices, ring.positions)
      end)
      if not batchOk then ring.batchAvailable = false end
    end
    if not ring.batchAvailable then
      for index, vertexId in ipairs(ring.vertices) do
        mesh:SetPosition(vertexId, ring.positions[index])
      end
    end
    debug.profileend()
    if ring.updateNormals then
      debug.profilebegin("Ocean/Normals")
      if ring.batchAvailable then
        local batchNormalOk = pcall(function()
          mesh:BatchSetValues(Enum.MeshAttribute.Normal, ring.normals, ring.normalValues)
        end)
        if not batchNormalOk then ring.batchAvailable = false end
      end
      if not ring.batchAvailable then
        for index, normalId in ipairs(ring.normals) do
          mesh:SetNormal(normalId, ring.normalValues[index])
        end
      end
      debug.profileend()
    end
  end)
  if not ok then
    ring.failed = true
  end
  self.stats.lastUpdateMs += (os.clock() - start) * 1000
end

function OceanRenderer:_Update(dt: number)
  if not self.running then return end
  local camera = Workspace.CurrentCamera
  if not camera then return end
  local start = os.clock()
  self.stats.lastUpdateMs = 0
  self.serverTime = self.waveField:StepClock(dt)
  if self.farPlane then
    self.farPlane.Position = Vector3.new(camera.CFrame.Position.X, self.waveField:GetState().seaLevel, camera.CFrame.Position.Z)
  end
  if not self.stats.fallback then
    for _, ring in ipairs(self.rings) do
      ring.accumulator += dt
      if ring.accumulator >= ring.cadence then
        ring.accumulator %= ring.cadence
        self:_UpdateRing(ring, self.serverTime, camera.CFrame.Position)
      end
    end
    for _, ring in ipairs(self.rings) do
      if ring.failed then
        self:_UseFallback("runtime mesh mutation failure")
        break
      end
    end
  else
    if self.fallback then
      self.fallback.Position = Vector3.new(camera.CFrame.Position.X, self.waveField:GetState().seaLevel, camera.CFrame.Position.Z)
    end
  end
  self.stats.lastOceanMs = (os.clock() - start) * 1000
  self.stats.lastFrameMs = dt * 1000
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
  if self.connection then
    self.connection:Disconnect()
    self.connection = nil
  end
  self.running = false
  self:_DestroyRings()
  if self.fallback then
    self.fallback:Destroy()
    self.fallback = nil
  end
  if self.farPlane then
    self.farPlane:Destroy()
    self.farPlane = nil
  end
end

function OceanRenderer:GetStats()
  return self.stats
end

local _ = TWO_PI
local _config = Config
return OceanRenderer
