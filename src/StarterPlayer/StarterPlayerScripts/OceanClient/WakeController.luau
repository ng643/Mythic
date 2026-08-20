--!strict

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")

local WakeController = {}
WakeController.__index = WakeController

local function setTrailTexture(trail: Trail)
  pcall(function()
    trail.Texture = "rbxasset://textures/particles/sparkles_main.dds"
  end)
end

local function makeTrail(holder: Part, firstOffset: Vector3, secondOffset: Vector3, name: string): Trail
  local first = Instance.new("Attachment")
  first.Name = name .. "_A"
  first.Position = firstOffset
  first.Parent = holder
  local second = Instance.new("Attachment")
  second.Name = name .. "_B"
  second.Position = secondOffset
  second.Parent = holder
  local trail = Instance.new("Trail")
  trail.Name = name
  trail.Attachment0 = first
  trail.Attachment1 = second
  trail.Enabled = false
  trail.Lifetime = 1.25
  trail.MinLength = 0.2
  trail.MaxLength = 80
  trail.FaceCamera = true
  trail.Color = ColorSequence.new(Color3.fromRGB(194, 231, 229))
  trail.Transparency = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.18), NumberSequenceKeypoint.new(0.75, 0.52), NumberSequenceKeypoint.new(1, 1)})
  trail.WidthScale = NumberSequence.new({NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(0.2, 1), NumberSequenceKeypoint.new(1, 0.05)})
  trail.LightEmission = 0.05
  setTrailTexture(trail)
  trail.Parent = holder
  return trail
end

function WakeController.new(runtime)
  return setmetatable({runtime = runtime, tracks = {}, connection = nil, added = nil, removed = nil}, WakeController)
end

function WakeController:_Track(model: Instance)
  if not model:IsA("Model") or self.tracks[model] then return end
  local root = model.PrimaryPart or model:FindFirstChild("HullRoot", true)
  if not root or not root:IsA("BasePart") then return end
  local holder = Instance.new("Part")
  holder.Name = "WakeSurfaceEmitter_" .. model.Name
  holder.Anchored = true
  holder.CanCollide = false
  holder.CanTouch = false
  holder.CanQuery = false
  holder.CastShadow = false
  holder.Transparency = 1
  holder.Size = Vector3.new(0.1, 0.1, 0.1)
  holder.Parent = self.runtime
  local port = makeTrail(holder, Vector3.new(-2.4, -0.8, 4.5), Vector3.new(-0.1, -0.85, 10), "PortWake")
  local starboard = makeTrail(holder, Vector3.new(2.4, -0.8, 4.5), Vector3.new(0.1, -0.85, 10), "StarboardWake")
  self.tracks[model] = {root = root, holder = holder, trails = {port, starboard}}
end

function WakeController:_Untrack(model: Instance)
  local track = self.tracks[model]
  if not track then return end
  track.holder:Destroy()
  self.tracks[model] = nil
end

function WakeController:Start()
  if self.connection then return end
  local function rescanTaggedShips()
    for _, model in ipairs(CollectionService:GetTagged("OceanShip")) do self:_Track(model) end
  end
  rescanTaggedShips()
  task.spawn(function()
    for _ = 1, 12 do
      task.wait(0.25)
      rescanTaggedShips()
    end
  end)
  self.added = CollectionService:GetInstanceAddedSignal("OceanShip"):Connect(function(model) self:_Track(model) end)
  self.removed = CollectionService:GetInstanceRemovedSignal("OceanShip"):Connect(function(model) self:_Untrack(model) end)
  self.connection = RunService.RenderStepped:Connect(function()
    debug.profilebegin("Ocean/Wakes")
    local enabled = self.runtime:GetAttribute("OceanDebugWakes") ~= false
    for model, track in pairs(self.tracks) do
      local root = track.root
      if not enabled then
        for _, trail in ipairs(track.trails) do trail.Enabled = false end
      elseif not root.Parent then
        self:_Untrack(model)
      else
        track.holder.CFrame = root.CFrame
        local localVelocity = root.CFrame:VectorToObjectSpace(root.AssemblyLinearVelocity)
        local forwardSpeed = math.max(0, -localVelocity.Z)
        local alpha = math.clamp((forwardSpeed - 2) / 35, 0, 1)
        for _, trail in ipairs(track.trails) do
          trail.Enabled = alpha > 0.03
        end
      end
    end
    debug.profileend()
  end)
end

function WakeController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  if self.added then self.added:Disconnect() self.added = nil end
  if self.removed then self.removed:Disconnect() self.removed = nil end
  for model in pairs(self.tracks) do self:_Untrack(model) end
end

return WakeController
