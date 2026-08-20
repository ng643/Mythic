--!strict

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local WakeController = {}
WakeController.__index = WakeController

function WakeController.new(runtime)
  return setmetatable({runtime = runtime, tracks = {}, connection = nil, added = nil, removed = nil}, WakeController)
end

function WakeController:_Track(model: Instance)
  if not model:IsA("Model") or self.tracks[model] then return end
  local root = model.PrimaryPart or model:FindFirstChild("HullRoot", true)
  if not root or not root:IsA("BasePart") then return end
  local parts = {}
  for index = 1, 2 do
    local trail = Instance.new("Part")
    trail.Name = string.format("WakeTrail_%d", index)
    trail.Anchored = true
    trail.CanCollide = false
    trail.CanTouch = false
    trail.CanQuery = false
    trail.CastShadow = false
    trail.Material = Enum.Material.Neon
    trail.Color = Color3.fromRGB(190, 230, 232)
    trail.Transparency = 1
    trail.Size = Vector3.new(2, 0.03, 8)
    trail.Parent = self.runtime
    table.insert(parts, trail)
  end
  self.tracks[model] = {root = root, parts = parts}
end

function WakeController:_Untrack(model: Instance)
  local track = self.tracks[model]
  if not track then return end
  for _, part in ipairs(track.parts) do part:Destroy() end
  self.tracks[model] = nil
end

function WakeController:Start()
  if self.connection then return end
  local function rescanTaggedShips()
    for _, model in ipairs(CollectionService:GetTagged("OceanShip")) do self:_Track(model) end
  end
  rescanTaggedShips()
  -- Tags can replicate before the model's HullRoot; retry only during startup.
  task.spawn(function()
    for _ = 1, 12 do
      task.wait(0.25)
      rescanTaggedShips()
    end
  end)
  self.added = CollectionService:GetInstanceAddedSignal("OceanShip"):Connect(function(model) self:_Track(model) end)
  self.removed = CollectionService:GetInstanceRemovedSignal("OceanShip"):Connect(function(model) self:_Untrack(model) end)
  self.connection = RunService.RenderStepped:Connect(function()
    for model, track in pairs(self.tracks) do
      local root = track.root
      if not root.Parent then
        self:_Untrack(model)
      else
        local speed = root.AssemblyLinearVelocity.Magnitude
        local alpha = math.clamp((speed - 2) / 35, 0, 1)
        for index, trail in ipairs(track.parts) do
          local side = index == 1 and -1 or 1
          local localOffset = Vector3.new(side * 2.3, -1.0, 5 + alpha * 10)
          trail.CFrame = root.CFrame * CFrame.new(localOffset) * CFrame.Angles(0, math.pi, 0)
          trail.Size = Vector3.new(1.2 + alpha * 4, 0.03, 5 + alpha * 12)
          trail.Transparency = 1 - alpha * 0.7
        end
      end
    end
  end)
end

function WakeController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  if self.added then self.added:Disconnect() self.added = nil end
  if self.removed then self.removed:Disconnect() self.removed = nil end
  for model in pairs(self.tracks) do self:_Untrack(model) end
end

return WakeController
