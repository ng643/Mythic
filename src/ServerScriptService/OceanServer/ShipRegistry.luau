--!strict

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local ShipRegistry = {}
ShipRegistry.__index = ShipRegistry

function ShipRegistry.new()
  local self = setmetatable({ships = {}, addedConnection = nil, removedConnection = nil}, ShipRegistry)
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

function ShipRegistry:_ApplyOwnership(entry)
  local desiredOwner: Player? = nil
  if entry.policy == "Driver" then
    local seat = entry.model:FindFirstChild("DriverSeat", true)
    local occupant = seat and seat:IsA("Seat") and seat.Occupant
    desiredOwner = occupant and Players:GetPlayerFromCharacter(occupant.Parent) or nil
  end
  if desiredOwner == entry.networkOwner then return end
  for _, descendant in ipairs(entry.model:GetDescendants()) do
    if descendant:IsA("BasePart") then
      pcall(function() descendant:SetNetworkOwner(desiredOwner) end)
    end
  end
  entry.networkOwner = desiredOwner
end

function ShipRegistry:UpdateOwnership()
  for _, entry in pairs(self.ships) do
    if entry.model.Parent then self:_ApplyOwnership(entry) end
  end
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
  if root.AssemblyMass <= 0 or root.AssemblyMass == math.huge then
    warn("OceanShip rejected: zero or invalid assembly mass " .. model:GetFullName())
    return false
  end
  for _, descendant in ipairs(model:GetDescendants()) do
    if descendant:IsA("BasePart") and descendant.Anchored then
      warn("OceanShip rejected: anchored part inside mechanism " .. descendant:GetFullName())
      return false
    end
  end
  local pointsFolder = model:FindFirstChild("BuoyancyPoints")
  if not pointsFolder or not pointsFolder:IsA("Folder") then
    warn("OceanShip rejected: missing BuoyancyPoints " .. model:GetFullName())
    return false
  end
  local points = {}
  -- Attachments must live under a BasePart for WorldPosition; the folder is
  -- the schema marker while descendants are collected from the whole model.
  for _, child in ipairs(model:GetDescendants()) do
    if child:IsA("Attachment") and child:GetAttribute("OceanBuoyancyPoint") == true then
      if not child.Parent or not child.Parent:IsA("BasePart") then
        warn("OceanShip rejected: buoyancy attachment must parent a BasePart " .. child:GetFullName())
        return false
      end
      table.insert(points, child)
    end
  end
  if #points < 4 or #points > 24 then
    warn("OceanShip rejected: buoyancy point count must be 4..24 " .. model:GetFullName())
    return false
  end
  table.sort(points, function(a, b) return a.Name < b.Name end)
  local totalWeight = 0
  for _, point in ipairs(points) do
    local weight = point:GetAttribute("Weight")
    if weight ~= nil and (type(weight) ~= "number" or weight <= 0 or weight ~= weight or weight == math.huge) then
      warn("OceanShip rejected: invalid buoyancy weight " .. point:GetFullName())
      return false
    end
    totalWeight += weight or 1
  end
  if totalWeight <= 0 or totalWeight ~= totalWeight then
    warn("OceanShip rejected: buoyancy weights have no finite mass " .. model:GetFullName())
    return false
  end
  for _, point in ipairs(points) do
    point:SetAttribute("Weight", (point:GetAttribute("Weight") or 1) / totalWeight)
  end
  local policy = model:GetAttribute("OceanNetworkOwnership") or "Server"
  if policy ~= "Driver" and policy ~= "Server" then
    warn("OceanShip using Server ownership for invalid policy " .. model:GetFullName())
    policy = "Server"
  end
  self.ships[model] = {model = model, root = root, points = points, policy = policy, networkOwner = nil}
  self:_ApplyOwnership(self.ships[model])
  return true
end

function ShipRegistry:Unregister(instance: Instance)
  if instance:IsA("Model") then
    self.ships[instance] = nil
  end
end

function ShipRegistry:GetEntries(): {any}
  local entries = {}
  for _, entry in pairs(self.ships) do
    table.insert(entries, entry)
  end
  return entries
end

function ShipRegistry:Destroy()
  if self.addedConnection then self.addedConnection:Disconnect() end
  if self.removedConnection then self.removedConnection:Disconnect() end
  table.clear(self.ships)
end

return ShipRegistry
