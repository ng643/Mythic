--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local SwimmingController = {}
SwimmingController.__index = SwimmingController

function SwimmingController.new(waveField)
  return setmetatable({waveField = waveField, connection = nil, force = nil, attachment = nil, swimming = false}, SwimmingController)
end

function SwimmingController:_EnsureForce(root: BasePart): VectorForce
  if self.force and self.force.Parent == root then return self.force end
  local attachment = root:FindFirstChild("OceanSwimAttachment")
  if not attachment then
    attachment = Instance.new("Attachment")
    attachment.Name = "OceanSwimAttachment"
    attachment.Parent = root
  end
  local force = root:FindFirstChild("OceanSwimForce")
  if not force or not force:IsA("VectorForce") then
    force = Instance.new("VectorForce")
    force.Name = "OceanSwimForce"
    force.Attachment0 = attachment
    force.RelativeTo = Enum.ActuatorRelativeTo.World
    force.ApplyAtCenterOfMass = true
    force.Parent = root
  end
  self.attachment = attachment
  self.force = force
  return force
end

function SwimmingController:Start()
  if self.connection then return end
  self.connection = RunService.RenderStepped:Connect(function(dt)
    local player = Players.LocalPlayer
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if not humanoid or not root or not root:IsA("BasePart") then return end
    local now = self.waveField:GetSynchronizedTime()
    local sample = self.waveField:SampleWorldXZ(Vector2.new(root.Position.X, root.Position.Z), now, {inverseIterations = 2, componentCap = 8})
    local submerged = root.Position.Y < sample.height - 0.45
    local force = self:_EnsureForce(root)
    if submerged then
      local mass = root.AssemblyMass
      local relative = root.AssemblyLinearVelocity - sample.velocity
      force.Force = Vector3.yAxis * mass * Workspace.Gravity * 0.92 - relative * mass * 1.4
      force.Enabled = true
      if humanoid:GetState() ~= Enum.HumanoidStateType.Swimming then
        humanoid:ChangeState(Enum.HumanoidStateType.Swimming)
      end
    else
      force.Enabled = false
    end
    self.swimming = submerged
  end)
end

function SwimmingController:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  if self.force then self.force.Enabled = false end
  self.swimming = false
end

function SwimmingController:IsSwimming(): boolean
  return self.swimming
end

return SwimmingController
