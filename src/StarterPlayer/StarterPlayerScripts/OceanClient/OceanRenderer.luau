--!strict

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Config = require(game.ReplicatedStorage.Ocean.Shared.OceanConfig)
local QualityProfiles = require(game.ReplicatedStorage.Ocean.Shared.QualityProfiles)

local OceanRenderer = {}
OceanRenderer.__index = OceanRenderer

local TWO_PI = math.pi * 2
local MAX_VERTICAL_BOUNDS = 32

local function setOceanPartProperties(part: MeshPart)
  part.Anchored = true
  part.CanCollide = false
  part.CanTouch = false
  part.CanQuery = false
  part.CastShadow = false
  part.Massless = true
  part.DoubleSided = true
  part.Material = Enum.Material.SmoothPlastic
  part.Color = Color3.fromRGB(5, 62, 86)
  part.Reflectance = 0.08
  part.Transparency = 0.04
end

local function cellIncluded(level: number, i: number, j: number, innerHalf: number): boolean
  if level == 0 then
    return true
  end
  -- One-cell overlap is the conservative stitch band for this prototype.
  return math.max(math.abs(i), math.abs(j)) >= math.max(innerHalf - 1, 0)
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
    connection = nil,
    fallback = nil,
    farPlane = nil,
    stats = {vertexCount = 0, triangleCount = 0, lastFrameMs = 0, lastUpdateMs = 0, ringCount = 0, fallback = false},
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
    local index = #vertices + 1
    vertexMap[mapKey] = index
    vertices[index] = id
    normals[index] = normalId
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
        local faceTwo = mesh:AddTriangle(vertices[c], vertices[b], vertices[d])
        mesh:SetFaceNormals(faceTwo, {normals[c], normals[b], normals[d]})
        triangleCount += 2
      end
    end
  end

  -- Unreferenced vertices keep the MeshPart bounds valid for moving crests.
  mesh:AddVertex(Vector3.new(0, -MAX_VERTICAL_BOUNDS, 0))
  mesh:AddVertex(Vector3.new(0, MAX_VERTICAL_BOUNDS, 0))
  local part = AssetService:CreateMeshPartAsync(Content.fromObject(mesh))
  part.Name = string.format("OceanClipmap_L%d", level)
  setOceanPartProperties(part)
  part.Parent = self.runtime
  local ring = {
    level = level,
    mesh = mesh,
    part = part,
    vertices = vertices,
    normals = normals,
    labels = labels,
    positions = positions,
    normalValues = normalValues,
    spacing = spacing,
    origin = Vector2.new(math.huge, math.huge),
    accumulator = 0,
    cadence = 1 / math.max(profile.nearCadence / 2 ^ level, 3),
    -- Keep long-wave samples identical across ring boundaries; short-wave filtering
    -- can be introduced only with a measured morph band.
    componentCap = 14,
    updateNormals = level <= profile.normalRings,
    triangleCount = triangleCount,
    batchAvailable = false,
    failed = false,
  }
  self.stats.vertexCount += #vertices
  self.stats.triangleCount += triangleCount
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
  part.Reflectance = 0.05
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
  part.Color = Color3.fromRGB(5, 62, 86)
  part.Reflectance = 0.04
  part.Size = Vector3.new(2048, 0.25, 2048)
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
    local maxExtent = 1900
    local ringLimit = self.runtime:GetAttribute("OceanExperimentalClipmaps") == true and self.profile.ringCount or 1
    for level = 0, ringLimit - 1 do
      local levelExtent = self.profile.spacing * 2 ^ level * (self.profile.resolution - 1)
      if levelExtent > maxExtent then
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

function OceanRenderer:SetVisible(visible: boolean)
  self.visible = visible
  for _, ring in ipairs(self.rings) do
    ring.part.Transparency = visible and 0.04 or 1
  end
  if self.fallback then
    self.fallback.Transparency = visible and 0.05 or 1
  end
  if self.farPlane then
    self.farPlane.Transparency = visible and 0 or 1
  end
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
  local sampleOptions = {
    inverseIterations = 1,
    includeEvents = true,
    componentCap = ring.componentCap,
    foamMultiplier = 1,
  }
  for index, localLabel in ipairs(ring.labels) do
    local worldLabel = origin + localLabel
    local sample = self.waveField:SampleLagrangian(worldLabel, serverTime, sampleOptions)
    ring.positions[index] = sample.position - Vector3.new(origin.X, self.waveField:GetState().seaLevel, origin.Y)
    if ring.updateNormals then
      ring.normalValues[index] = sample.normal
    end
  end
  local mesh = ring.mesh
  local start = os.clock()
  local ok = pcall(function()
    for index, vertexId in ipairs(ring.vertices) do
      mesh:SetPosition(vertexId, ring.positions[index])
    end
    if ring.updateNormals then
      for index, normalId in ipairs(ring.normals) do
        mesh:SetNormal(normalId, ring.normalValues[index])
      end
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
    self.farPlane.Position = Vector3.new(camera.CFrame.Position.X, self.waveField:GetState().seaLevel - MAX_VERTICAL_BOUNDS * 0.5, camera.CFrame.Position.Z)
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
      self.fallback.Position = Vector3.new(camera.CFrame.Position.X, self.waveField:GetState().seaLevel - 0.15, camera.CFrame.Position.Z)
    end
  end
  self.stats.lastFrameMs = (os.clock() - start) * 1000
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
