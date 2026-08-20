--!strict

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local SHIP_NAME = "OceanDemoRaft"
local SPAWN_POINT_NAME = "ShipSpawnPoint"

local function getSpawnCFrame(): CFrame?
  local ship = Workspace:FindFirstChild(SHIP_NAME)
  if not ship or not ship:IsA("Model") then
    return nil
  end

  local point = ship:FindFirstChild(SPAWN_POINT_NAME, true)
  if point and point:IsA("Attachment") then
    return point.WorldCFrame
  end

  local root = ship:FindFirstChild("HullRoot", true)
  if root and root:IsA("BasePart") then
    return root.CFrame * CFrame.new(0, 2.5, 0)
  end

  return nil
end

local function placeCharacterOnShip(character: Model)
  local root = character:WaitForChild("HumanoidRootPart", 10)
  if not root or not root:IsA("BasePart") then
    return
  end

  local spawnCFrame = getSpawnCFrame()
  if not spawnCFrame then
    warn("ShipSpawnService | OceanDemoRaft spawn point unavailable")
    return
  end

  character:PivotTo(spawnCFrame)
  root.AssemblyLinearVelocity = Vector3.zero
  root.AssemblyAngularVelocity = Vector3.zero
end

local function onCharacterAdded(character: Model)
  task.defer(function()
    local ok, reason = pcall(placeCharacterOnShip, character)
    if not ok then
      warn("ShipSpawnService | character placement failed | " .. tostring(reason))
    end
  end)
end

local function onPlayerAdded(player: Player)
  player.CharacterAdded:Connect(onCharacterAdded)
  if player.Character then
    onCharacterAdded(player.Character)
  end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do
  onPlayerAdded(player)
end
