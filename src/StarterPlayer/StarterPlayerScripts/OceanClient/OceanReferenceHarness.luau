--!strict

local AssetService = game:GetService("AssetService")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local Harness = {}
Harness.__index = Harness

local GRID_SIDE = 50
local SPACING = 8
local HALF = (GRID_SIDE - 1) * 0.5
local SEA_LEVEL = 0
local TWO_PI = math.pi * 2
local TROUGH = Color3.fromRGB(8, 44, 58)
local MID = Color3.fromRGB(17, 84, 101)
local CREST = Color3.fromRGB(82, 154, 168)

local waves = {
  {direction = Vector2.new(1, 1).Unit, wavelength = 97.5, steepness = 0.30, phase = 0},
  {direction = Vector2.new(0, 1), wavelength = 93.75, steepness = 0.20, phase = 1.4},
}
for _, wave in ipairs(waves) do
  wave.waveNumber = TWO_PI / wave.wavelength
  wave.amplitude = wave.steepness / wave.waveNumber
  wave.horizontalAmplitude = wave.amplitude
  wave.angularFrequency = math.sqrt(35.04 * wave.waveNumber)
end

local function colorRamp(height: number): Color3
  local t = math.clamp((height + 5) / 10, 0, 1)
  return t < 0.5 and TROUGH:Lerp(MID, t * 2) or MID:Lerp(CREST, (t - 0.5) * 2)
end

local function evaluate(worldXZ: Vector2, timeSeconds: number): (Vector3, Vector3)
  local position = Vector3.new(worldXZ.X, SEA_LEVEL, worldXZ.Y)
  local tangentX = Vector3.new(1, 0, 0)
  local tangentZ = Vector3.new(0, 0, 1)
  for _, wave in ipairs(waves) do
    local theta = wave.waveNumber * wave.direction:Dot(worldXZ) - wave.angularFrequency * timeSeconds + wave.phase
    theta %= TWO_PI
    local sinTheta = math.sin(theta)
    local cosTheta = math.cos(theta)
    local dx, dz = wave.direction.X, wave.direction.Y
    local ak = wave.amplitude * wave.waveNumber
    local bk = wave.horizontalAmplitude * wave.waveNumber
    position += Vector3.new(wave.horizontalAmplitude * dx * cosTheta, wave.amplitude * sinTheta, wave.horizontalAmplitude * dz * cosTheta)
    tangentX += Vector3.new(-bk * dx * dx * sinTheta, ak * dx * cosTheta, -bk * dx * dz * sinTheta)
    tangentZ += Vector3.new(-bk * dx * dz * sinTheta, ak * dz * cosTheta, -bk * dz * dz * sinTheta)
  end
  return position, (tangentZ:Cross(tangentX)).Unit
end

local function isOceanPart(child: Instance): boolean
  return child:IsA("MeshPart")
    or (child:IsA("BasePart") and (child.Name == "OceanFallbackSurface" or string.sub(child.Name, 1, 13) == "OceanHorizon_"))
end

function Harness.new(waveField, runtime)
  return setmetatable({
    waveField = waveField,
    runtime = runtime,
    part = nil,
    mesh = nil,
    vertices = {},
    normals = {},
    colors = {},
    labels = {},
    positions = {},
    colorValues = {},
    origin = Vector2.new(math.huge, math.huge),
    mode = "Candidate Production",
    connection = nil,
    debug = {},
  }, Harness)
end

function Harness:_Build()
  if self.part then return end
  local mesh = AssetService:CreateEditableMesh()
  local function indexOf(x: number, z: number): number
    return math.floor((z + HALF) * GRID_SIDE + (x + HALF)) + 1
  end
  for z = 0, GRID_SIDE - 1 do
    for x = 0, GRID_SIDE - 1 do
      local label = Vector2.new((x - HALF) * SPACING, (z - HALF) * SPACING)
      local index = indexOf(label.X / SPACING, label.Y / SPACING)
      self.labels[index] = label
      self.vertices[index] = mesh:AddVertex(Vector3.new(label.X, SEA_LEVEL, label.Y))
      self.normals[index] = mesh:AddNormal(Vector3.yAxis)
      self.colors[index] = mesh:AddColor(MID, 1)
      self.positions[index] = Vector3.new(label.X, SEA_LEVEL, label.Y)
      self.colorValues[index] = MID
    end
  end
  for z = 0, GRID_SIDE - 2 do
    for x = 0, GRID_SIDE - 2 do
      local a = z * GRID_SIDE + x + 1
      local b = a + GRID_SIDE
      local c = a + 1
      local d = b + 1
      local faceA = mesh:AddTriangle(self.vertices[a], self.vertices[b], self.vertices[c])
      mesh:SetFaceNormals(faceA, {self.normals[a], self.normals[b], self.normals[c]})
      mesh:SetFaceColors(faceA, {self.colors[a], self.colors[b], self.colors[c]})
      local faceB = mesh:AddTriangle(self.vertices[c], self.vertices[b], self.vertices[d])
      mesh:SetFaceNormals(faceB, {self.normals[c], self.normals[b], self.normals[d]})
      mesh:SetFaceColors(faceB, {self.colors[c], self.colors[b], self.colors[d]})
    end
  end
  mesh:AddVertex(Vector3.new(0, -16, 0))
  mesh:AddVertex(Vector3.new(0, 16, 0))
  local part = AssetService:CreateMeshPartAsync(Content.fromObject(mesh))
  part.Name = "OceanReferenceGeometry_50x50"
  part.Anchored = true
  part.CanCollide = false
  part.CanTouch = false
  part.CanQuery = false
  part.CastShadow = false
  part.DoubleSided = true
  part.Material = Enum.Material.Glass
  part.Reflectance = 0.12
  part.Transparency = 1
  part.Parent = self.runtime
  self.mesh = mesh
  self.part = part
end

function Harness:SetMode(mode: string)
  if mode ~= "Reference Geometry" and mode ~= "Candidate Production" then
    return false, "unknown harness mode; Current Main removed because it aliases production"
  end
  self.mode = mode
  if self.part then self.part.Transparency = mode == "Reference Geometry" and 0 or 1 end
  for _, child in ipairs(self.runtime:GetChildren()) do
    if isOceanPart(child) then
      child.LocalTransparencyModifier = mode == "Reference Geometry" and 1 or 0
    end
  end
  self.runtime:SetAttribute("OceanHarnessMode", mode)
  return true
end

function Harness:SetDebug(name: string, enabled: boolean)
  self.debug[name] = enabled
  self.runtime:SetAttribute("OceanHarnessDebug_" .. name, enabled)
end

function Harness:_Update(serverTime: number)
  if not self.part or not self.mesh then return end
  local camera = Workspace.CurrentCamera
  if not camera then return end
  local anchor = Vector2.new(
    math.floor(camera.CFrame.Position.X / SPACING + 0.5) * SPACING,
    math.floor(camera.CFrame.Position.Z / SPACING + 0.5) * SPACING
  )
  if anchor ~= self.origin then
    self.origin = anchor
    self.part.CFrame = CFrame.new(anchor.X, SEA_LEVEL, anchor.Y)
  end
  local timeSeconds = serverTime
  for index, label in ipairs(self.labels) do
    local world = anchor + label
    local position, normal = evaluate(world, timeSeconds)
    local displacement = position - Vector3.new(world.X, SEA_LEVEL, world.Y)
    self.positions[index] = Vector3.new(label.X, SEA_LEVEL, label.Y) + displacement
    self.colorValues[index] = colorRamp(displacement.Y)
    self.mesh:SetPosition(self.vertices[index], self.positions[index])
    self.mesh:SetNormal(self.normals[index], normal)
    self.mesh:SetColor(self.colors[index], self.colorValues[index])
  end
end

function Harness:Start()
  if not RunService:IsStudio() or self.connection then return end
  self:_Build()
  self:SetMode(self.mode)
  self.connection = RunService.RenderStepped:Connect(function()
    self:_Update(self.waveField:GetSynchronizedTime())
  end)
end

function Harness:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  if self.part then self.part:Destroy() self.part = nil end
  if self.mesh then self.mesh:Destroy() self.mesh = nil end
end

function Harness:SetMaterialCandidate(candidate: string)
  if candidate ~= "PBR" and candidate ~= "Glass" then return false, "unknown material candidate" end
  self.runtime:SetAttribute("OceanMaterialCandidate", candidate)
  return true
end

return Harness
