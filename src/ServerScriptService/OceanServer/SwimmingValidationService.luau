--!strict

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local SwimmingValidationService = {}
SwimmingValidationService.__index = SwimmingValidationService

function SwimmingValidationService.new(waveField)
  return setmetatable({
    waveField = waveField,
    connection = nil,
    accumulator = 0,
    lastWarn = {},
  }, SwimmingValidationService)
end

function SwimmingValidationService:_Step()
  local now = self.waveField:GetSynchronizedTime()
  for _, player in ipairs(Players:GetPlayers()) do
    local character = player.Character
    local humanoid = character and character:FindFirstChildOfClass("Humanoid")
    local root = character and character:FindFirstChild("HumanoidRootPart")
    if humanoid and root and root:IsA("BasePart") and humanoid.Health > 0 and humanoid.SeatPart == nil then
      local sample = self.waveField:SampleForGameplayWorldXZ(
        Vector2.new(root.Position.X, root.Position.Z),
        now,
        {inverseIterations = 3, includeEvents = false}
      )
      local relative = root.AssemblyLinearVelocity - sample.velocity
      local speed = relative.Magnitude
      local maxSpeed = math.max(player:GetAttribute("OceanMaxSwimSpeed") or 42, 20)
      if speed > maxSpeed or math.abs(relative.Y) > 72 then
        root.AssemblyLinearVelocity = root.AssemblyLinearVelocity * 0.55
        local last = self.lastWarn[player] or -math.huge
        if now - last > 2 then
          self.lastWarn[player] = now
          warn(string.format("Ocean swimming validation limited %s speed=%.2f vertical=%.2f", player.Name, speed, relative.Y))
        end
      end
    end
  end
end

function SwimmingValidationService:Start()
  if self.connection then return end
  self.connection = RunService.Heartbeat:Connect(function(dt)
    self.accumulator += math.clamp(dt, 0, 0.1)
    if self.accumulator < 0.1 then return end
    self.accumulator = 0
    self:_Step()
  end)
end

function SwimmingValidationService:Stop()
  if self.connection then self.connection:Disconnect() self.connection = nil end
  table.clear(self.lastWarn)
end

return SwimmingValidationService
