--!strict

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local Workspace = game:GetService("Workspace")

local UnderwaterController = {}
UnderwaterController.__index = UnderwaterController

local SAMPLE_INTERVAL = 1 / 20
local CROSSFADE_SECONDS = 0.25

function UnderwaterController.new(waveField, runtime, scheduler)
  return setmetatable({
    waveField = waveField,
    runtime = runtime,
    scheduler = scheduler,
    underwater = false,
    targetAlpha = 0,
    alpha = 0,
    connection = nil,
    effect = nil,
    sampleAccumulator = SAMPLE_INTERVAL,
    lastSample = nil,
    sampleAge = math.huge,
  }, UnderwaterController)
end

function UnderwaterController:_SetTarget(value: boolean)
  self.underwater = value
  self.targetAlpha = value and 1 or 0
end

function UnderwaterController:_UpdateEffect(dt: number)
  local rate = math.clamp(dt / CROSSFADE_SECONDS, 0, 1)
  self.alpha += (self.targetAlpha - self.alpha) * rate
  if not self.effect then return end
  self.effect.Enabled = self.alpha > 0.01
  self.effect.TintColor = Color3.new(1, 1, 1):Lerp(Color3.fromRGB(95, 172, 184), self.alpha)
  self.effect.Saturation = -0.22 * self.alpha
  self.effect.Contrast = -0.08 * self.alpha
  self.effect.Brightness = -0.04 * self.alpha
end

function UnderwaterController:Start()
  if self.connection then return end
  local effect = Lighting:FindFirstChild("OceanUnderwaterColor")
  if not effect then
    effect = Instance.new("ColorCorrectionEffect")
    effect.Name = "OceanUnderwaterColor"
    effect.Parent = Lighting
  end
  effect.Enabled = false
  self.effect = effect
  self.connection = RunService.RenderStepped:Connect(function(dt)
    self:_UpdateEffect(math.clamp(dt, 0, 0.05))
    if self.runtime and self.runtime:GetAttribute("OceanUnderwaterEnabled") ~= true then
      self:_SetTarget(false)
      return
    end
    local camera = Workspace.CurrentCamera
    if not camera then return end
    self.sampleAccumulator += math.clamp(dt, 0, 0.05)
    self.sampleAge += math.clamp(dt, 0, 0.05)
    if self.sampleAccumulator < SAMPLE_INTERVAL and self.lastSample then return end
    self.sampleAccumulator %= SAMPLE_INTERVAL
    debug.profilebegin("Ocean/Underwater")
    local serverTime = self.waveField:GetSynchronizedTime()
    local position = camera.CFrame.Position
    local sample = self.scheduler
      and self.scheduler:Sample(Vector2.new(position.X, position.Z), serverTime, {inverseIterations = 3, includeEvents = false})
      or self.waveField:SampleForGameplayWorldXZ(Vector2.new(position.X, position.Z), serverTime, {inverseIterations = 3, includeEvents = false})
    debug.profileend()
    self.lastSample = sample
    self.sampleAge = 0
    local nextUnderwater = self.underwater
      and position.Y < sample.height + 0.55
      or position.Y < sample.height - 0.35
    self:_SetTarget(nextUnderwater)
  end)
end

function UnderwaterController:Stop()
  if self.connection then
    self.connection:Disconnect()
    self.connection = nil
  end
  self:_SetTarget(false)
  self.alpha = 0
  if self.effect then self.effect.Enabled = false end
end

function UnderwaterController:Invalidate()
  self.lastSample = nil
  self.sampleAge = math.huge
  self.sampleAccumulator = SAMPLE_INTERVAL
end

function UnderwaterController:IsUnderwater(): boolean
  return self.underwater
end

return UnderwaterController
