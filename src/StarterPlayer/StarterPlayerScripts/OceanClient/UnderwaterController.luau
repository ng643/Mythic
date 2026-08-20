--!strict

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UnderwaterController = {}
UnderwaterController.__index = UnderwaterController

function UnderwaterController.new(waveField, runtime)
  return setmetatable({waveField = waveField, runtime = runtime, underwater = false, connection = nil, effect = nil, enteredAt = 0}, UnderwaterController)
end

function UnderwaterController:_SetUnderwater(value: boolean, now: number)
  if self.underwater == value then return end
  self.underwater = value
  self.enteredAt = now
  if self.effect then
    self.effect.Enabled = value
  end
end

function UnderwaterController:Start()
  if self.connection then return end
  local effect = Lighting:FindFirstChild("OceanUnderwaterColor")
  if not effect then
    effect = Instance.new("ColorCorrectionEffect")
    effect.Name = "OceanUnderwaterColor"
    effect.TintColor = Color3.fromRGB(95, 172, 184)
    effect.Saturation = -0.22
    effect.Contrast = -0.08
    effect.Brightness = -0.04
    effect.Enabled = false
    effect.Parent = Lighting
  end
  self.effect = effect
  self.connection = RunService.RenderStepped:Connect(function()
    if self.runtime and self.runtime:GetAttribute("OceanUnderwaterEnabled") ~= true then
      self:_SetUnderwater(false, self.waveField:GetSynchronizedTime())
      return
    end
    local camera = Workspace.CurrentCamera
    if not camera then return end
    debug.profilebegin("Ocean/Underwater")
    local serverTime = self.waveField:GetSynchronizedTime()
    local sample = self.waveField:SampleForGameplayWorldXZ(Vector2.new(camera.CFrame.Position.X, camera.CFrame.Position.Z), serverTime, {inverseIterations = 3})
    local y = camera.CFrame.Position.Y
    debug.profileend()
    local nextUnderwater = self.underwater and y < sample.height + 0.55 or y < sample.height - 0.35
    self:_SetUnderwater(nextUnderwater, serverTime)
  end)
end

function UnderwaterController:Stop()
  if self.connection then
    self.connection:Disconnect()
    self.connection = nil
  end
  if self.effect then
    self.effect.Enabled = false
  end
end

function UnderwaterController:IsUnderwater(): boolean
  return self.underwater
end

return UnderwaterController
