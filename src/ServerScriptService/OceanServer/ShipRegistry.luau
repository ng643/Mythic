--!strict

local CollectionService = game:GetService("CollectionService")

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
    if child:IsA("Attachment") and child.Name ~= "RootAttachment" then
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
  -- NPC/demo ships stay server-owned; player ships can opt into an explicit
  -- client-ownership policy later after validation is wired.
  for _, descendant in ipairs(model:GetDescendants()) do
    if descendant:IsA("BasePart") then
      pcall(function() descendant:SetNetworkOwner(nil) end)
    end
  end
  self.ships[model] = {model = model, root = root, points = points}
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
