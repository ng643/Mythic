--!strict

local CollectionService = game:GetService("CollectionService")
local PhysicsService = game:GetService("PhysicsService")

local ShipRegistry = {}
ShipRegistry.__index = ShipRegistry

local SHIP_COLLISION_GROUP = "OceanShip"
local SEATED_COLLISION_GROUP = "OceanSeatedOccupant"

local function finite(value: number): boolean
  return value == value and value > -math.huge and value < math.huge
end

local function ensureCollisionGroups()
  pcall(function()
    PhysicsService:RegisterCollisionGroup(SHIP_COLLISION_GROUP)
  end)
  pcall(function()
    PhysicsService:RegisterCollisionGroup(SEATED_COLLISION_GROUP)
  end)
  pcall(function()
    PhysicsService:CollisionGroupSetCollidable(SHIP_COLLISION_GROUP, SEATED_COLLISION_GROUP, false)
  end)
end

local function isSeat(instance: Instance): boolean
  return instance:IsA("VehicleSeat") or instance:IsA("Seat")
end

local function findDriverSeat(model: Model): Seat?
  local named = model:FindFirstChild("DriverSeat", true)
  if named and isSeat(named) then
    return named :: Seat
  end

  for _, descendant in ipairs(model:GetDescendants()) do
    if isSeat(descendant) and descendant:GetAttribute("OceanDriverSeat") == true then
      return descendant :: Seat
    end
  end

  for _, descendant in ipairs(model:GetDescendants()) do
    if descendant:IsA("VehicleSeat") then
      return descendant :: Seat
    end
  end

  for _, descendant in ipairs(model:GetDescendants()) do
    if descendant:IsA("Seat") then
      return descendant :: Seat
    end
  end

  return nil
end

function ShipRegistry.new()
  ensureCollisionGroups()
  local self = setmetatable({
    ships = {},
    addedConnection = nil,
    removedConnection = nil,
  }, ShipRegistry)

  self.addedConnection = CollectionService:GetInstanceAddedSignal("OceanShip"):Connect(function(instance)
    self:Register(instance)
  end)
  self.removedConnection = CollectionService:GetInstanceRemovedSignal("OceanShip"):Connect(function(instance)
    self:Unregister(instance)
  end)

  for _, instance in ipairs(CollectionService:GetTagged("OceanShip")) do
    self:Register(instance)
  end

  return self
end

function ShipRegistry:_RestoreOccupantCollision(entry)
  if entry.occupantDescendantConnection then
    entry.occupantDescendantConnection:Disconnect()
    entry.occupantDescendantConnection = nil
  end
  for part, previousGroup in pairs(entry.occupantParts) do
    if part.Parent then
      pcall(function()
        part.CollisionGroup = previousGroup
      end)
    end
  end
  table.clear(entry.occupantParts)
  entry.occupant = nil
end

function ShipRegistry:_SetOccupantCollision(entry, humanoid)
  self:_RestoreOccupantCollision(entry)
  if not humanoid or not humanoid.Parent then return end
  local character = humanoid.Parent
  if not character:IsA("Model") then return end

  local function setPart(part: BasePart)
    if not entry.occupantParts[part] then
      entry.occupantParts[part] = part.CollisionGroup
    end
    pcall(function()
      part.CollisionGroup = SEATED_COLLISION_GROUP
    end)
  end

  for _, descendant in ipairs(character:GetDescendants()) do
    if descendant:IsA("BasePart") then
      setPart(descendant)
    end
  end
  entry.occupantDescendantConnection = character.DescendantAdded:Connect(function(descendant)
    if descendant:IsA("BasePart") then
      setPart(descendant)
    end
  end)
  entry.occupant = humanoid
end

function ShipRegistry:_ApplyOwnership(entry)
  if entry.ownershipChecked then return end
  entry.ownershipChecked = true

  local model = entry.model
  if model:GetAttribute("OceanNetworkOwnership") ~= "Server" then
    warn("OceanShip forcing server ownership for recovery: " .. model:GetFullName())
    model:SetAttribute("OceanNetworkOwnership", "Server")
  end

  local root = entry.root
  local canSetOk, canSet = pcall(function()
    return root:CanSetNetworkOwnership()
  end)
  if not canSetOk or canSet ~= true then
    warn("OceanShip cannot set server ownership on " .. root:GetFullName())
    return
  end

  local ok, reason = pcall(function()
    root:SetNetworkOwner(nil)
  end)
  if not ok then
    warn("OceanShip server ownership failed on " .. root:GetFullName() .. " | " .. tostring(reason))
    return
  end
  entry.networkOwner = nil
end

function ShipRegistry:Register(instance: Instance): boolean
  if not instance:IsA("Model") or self.ships[instance] then
    return false
  end

  local model = instance :: Model
  local root = model.PrimaryPart or model:FindFirstChild("HullRoot", true)
  if not root or not root:IsA("BasePart") then
    warn("OceanShip rejected: missing PrimaryPart/HullRoot " .. model:GetFullName())
    return false
  end
  if root.Anchored then
    warn("OceanShip rejected: HullRoot is anchored " .. model:GetFullName())
    return false
  end

  pcall(function()
    model.PrimaryPart = root
    root.RootPriority = 127
  end)

  local parts = {}
  for _, descendant in ipairs(model:GetDescendants()) do
    if descendant:IsA("BasePart") then
      table.insert(parts, descendant)
      if descendant.Anchored then
        warn("OceanShip rejected: anchored part inside mechanism " .. descendant:GetFullName())
        return false
      end
      pcall(function()
        descendant.CollisionGroup = SHIP_COLLISION_GROUP
      end)
    end
  end
  if root.AssemblyRootPart and root.AssemblyRootPart ~= root then
    warn("OceanShip rejected: HullRoot is not assembly root " .. model:GetFullName())
    return false
  end
  for _, part in ipairs(parts) do
    if part.AssemblyRootPart and part.AssemblyRootPart ~= root then
      warn("OceanShip rejected: disconnected part " .. part:GetFullName())
      return false
    end
  end

  local pointsFolder = model:FindFirstChild("BuoyancyPoints")
  if not pointsFolder or not pointsFolder:IsA("Folder") then
    warn("OceanShip rejected: missing BuoyancyPoints " .. model:GetFullName())
    return false
  end

  local points = {}
  for _, descendant in ipairs(model:GetDescendants()) do
    if descendant:IsA("Attachment") and descendant:GetAttribute("OceanBuoyancyPoint") == true then
      if not descendant.Parent or not descendant.Parent:IsA("BasePart") then
        warn("OceanShip rejected: buoyancy attachment must parent a BasePart " .. descendant:GetFullName())
        return false
      end
      local parentPart = descendant.Parent :: BasePart
      if parentPart.AssemblyRootPart and parentPart.AssemblyRootPart ~= root then
        warn("OceanShip rejected: buoyancy point is outside assembly " .. descendant:GetFullName())
        return false
      end
      local localPosition = root.CFrame:PointToObjectSpace(descendant.WorldPosition)
      local halfSize = root.Size * 0.5 + Vector3.new(0.5, 1.5, 0.5)
      if math.abs(localPosition.X) > halfSize.X or math.abs(localPosition.Z) > halfSize.Z then
        warn("OceanShip rejected: buoyancy point outside hull footprint " .. descendant:GetFullName())
        return false
      end
      table.insert(points, {
        attachment = descendant,
        localPosition = localPosition,
        weight = descendant:GetAttribute("Weight") or 1,
        targetDepth = descendant:GetAttribute("TargetSubmersion"),
        maxForce = descendant:GetAttribute("MaxForce"),
      })
    end
  end
  if #points < 4 or #points > 16 then
    warn("OceanShip rejected: buoyancy point count must be 4..16 " .. model:GetFullName())
    return false
  end

  local totalWeight = 0
  local weightedCenter = Vector3.zero
  for _, point in ipairs(points) do
    if type(point.weight) ~= "number" or not finite(point.weight) or point.weight <= 0 then
      warn("OceanShip rejected: invalid buoyancy weight " .. point.attachment:GetFullName())
      return false
    end
    totalWeight += point.weight
    weightedCenter += point.localPosition * point.weight
  end
  if not finite(totalWeight) or totalWeight <= 0 then
    warn("OceanShip rejected: buoyancy weights have no finite mass " .. model:GetFullName())
    return false
  end
  weightedCenter /= totalWeight
  if math.abs(weightedCenter.X) > 0.5 or math.abs(weightedCenter.Z) > 0.5 then
    warn(string.format(
      "OceanShip rejected: buoyancy moments are asymmetric x=%.3f z=%.3f %s",
      weightedCenter.X,
      weightedCenter.Z,
      model:GetFullName()
    ))
    return false
  end
  table.sort(points, function(a, b)
    return a.attachment.Name < b.attachment.Name
  end)
  for _, point in ipairs(points) do
    point.weight /= totalWeight
    point.attachment:SetAttribute("Weight", point.weight)
  end

  local dryMass = root.AssemblyMass
  if not finite(dryMass) or dryMass <= 0 then
    warn("OceanShip rejected: invalid dry assembly mass " .. model:GetFullName())
    return false
  end

  local marker = model:FindFirstChild("Waterline", true)
  local waterlineLocalY = 0
  if marker and marker:IsA("Attachment") then
    waterlineLocalY = root.CFrame:PointToObjectSpace(marker.WorldPosition).Y
  end
  local targetDraft = math.clamp(model:GetAttribute("EffectiveDraft") or root.Size.Y * 0.5, 0.25, 20)
  local defaultTargetDepth = math.clamp(model:GetAttribute("TargetSubmersion") or targetDraft * 0.9, 0.25, 20)

  for _, point in ipairs(points) do
    point.targetDepth = math.clamp(point.targetDepth or defaultTargetDepth, 0.25, 20)
    point.maxForce = math.max(point.maxForce or dryMass * workspace.Gravity * point.weight * 2.5, 1)
  end

  local seat = findDriverSeat(model)
  local entry = {
    model = model,
    root = root,
    points = points,
    parts = parts,
    dryMass = dryMass,
    dryComLocal = root.CFrame:PointToObjectSpace(root.AssemblyCenterOfMass),
    effectiveMass = dryMass,
    payloadMass = 0,
    targetDraft = targetDraft,
    waterlineLocalY = waterlineLocalY,
    networkOwner = nil,
    ownershipChecked = false,
    forces = nil,
    comAttachment = nil,
    dragForce = nil,
    stabilityTorque = nil,
    occupant = nil,
    occupantParts = {},
    occupantConnection = nil,
    occupantDescendantConnection = nil,
    lastTotalForce = Vector3.zero,
    lastTotalTorque = Vector3.zero,
    lastWetPoints = 0,
    lastInvalidSamples = 0,
  }
  self.ships[model] = entry

  if seat then
    entry.occupantConnection = seat:GetPropertyChangedSignal("Occupant"):Connect(function()
      self:_SetOccupantCollision(entry, seat.Occupant)
    end)
    self:_SetOccupantCollision(entry, seat.Occupant)
  end
  self:_ApplyOwnership(entry)
  return true
end

function ShipRegistry:Unregister(instance: Instance)
  if not instance:IsA("Model") then return end
  local entry = self.ships[instance]
  if not entry then return end
  if entry.occupantConnection then entry.occupantConnection:Disconnect() end
  self:_RestoreOccupantCollision(entry)
  self.ships[instance] = nil
end

function ShipRegistry:GetEntries(): {any}
  local entries = {}
  for _, entry in pairs(self.ships) do
    table.insert(entries, entry)
  end
  return entries
end

function ShipRegistry:UpdateOwnership()
  -- Kept as a compatibility hook. Ownership is intentionally not polled.
end

function ShipRegistry:Destroy()
  if self.addedConnection then self.addedConnection:Disconnect() end
  if self.removedConnection then self.removedConnection:Disconnect() end
  for model in pairs(self.ships) do
    self:Unregister(model)
  end
  table.clear(self.ships)
end

return ShipRegistry
