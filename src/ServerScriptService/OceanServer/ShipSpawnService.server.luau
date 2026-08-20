--!strict

local Players = game:GetService("Players")
local Workspace = game:GetService("Workspace")

local SHIP_NAME = "OceanDemoRaft"
local SPAWN_POINT_NAME = "ShipSpawnPoint"

local function finite(value: number): boolean
  return value == value and value > -math.huge and value < math.huge
end

local function finiteVector(value: Vector3): boolean
  return finite(value.X) and finite(value.Y) and finite(value.Z)
end

local function getSpawnCFrame(): CFrame?
  local ship = Workspace:FindFirstChild(SHIP_NAME)
  if not ship or not ship:IsA("Model") then return nil end
  local root = ship:FindFirstChild("HullRoot", true)
  if not root or not root:IsA("BasePart") then return nil end

  local point = ship:FindFirstChild(SPAWN_POINT_NAME, true)
  local spawnCFrame: CFrame
  if point and point:IsA("Attachment") and point.Parent and point.Parent:IsA("BasePart") then
    if point.Parent.AssemblyRootPart and point.Parent.AssemblyRootPart ~= root then return nil end
    spawnCFrame = point.WorldCFrame
  else
    spawnCFrame = root.CFrame * CFrame.new(0, 2.5, 0)
  end

  local position = spawnCFrame.Position
  if not finiteVector(position) then return nil end
  local up = spawnCFrame.UpVector
  if not finiteVector(up) or up:Dot(Vector3.yAxis) < 0.25 then
    spawnCFrame = CFrame.lookAt(position, position + Vector3.zAxis, Vector3.yAxis)
  end
  return spawnCFrame
end

local function placeCharacterOnShip(character: Model): boolean
  local root = character:WaitForChild("HumanoidRootPart", 10)
  if not root or not root:IsA("BasePart") then return false end
  local spawnCFrame = getSpawnCFrame()
  if not spawnCFrame then return false end

  character:PivotTo(spawnCFrame)
  root.AssemblyLinearVelocity = Vector3.zero
  root.AssemblyAngularVelocity = Vector3.zero
  local assemblyRoot = root.AssemblyRootPart
  if assemblyRoot and not assemblyRoot:IsDescendantOf(character) then
    warn("ShipSpawnService | spawn joined an external assembly")
    return false
  end
  return true
end

local function onCharacterAdded(character: Model)
  task.spawn(function()
    for attempt = 1, 12 do
      if not character.Parent then return end
      local ok, placed = pcall(placeCharacterOnShip, character)
      if ok and placed then return end
      task.wait(0.25)
    end
    warn("ShipSpawnService | failed to place character on OceanDemoRaft")
  end)
end

local function onPlayerAdded(player: Player)
  player.CharacterAdded:Connect(onCharacterAdded)
  if player.Character then onCharacterAdded(player.Character) end
end

Players.PlayerAdded:Connect(onPlayerAdded)
for _, player in ipairs(Players:GetPlayers()) do onPlayerAdded(player) end
