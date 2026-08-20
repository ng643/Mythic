--!strict

local RunService = game:GetService("RunService")

local OceanQualityController = {}
OceanQualityController.__index = OceanQualityController

local order = {"Ultra", "High", "Medium", "Low", "Fallback"}
local indexByName = {Ultra = 1, High = 2, Medium = 3, Low = 4, Fallback = 5}

function OceanQualityController.new(renderer, runtime)
  return setmetatable({
    renderer = renderer,
    runtime = runtime,
    ema = 0,
    overBudgetTime = 0,
    underBudgetTime = 0,
    cooldown = 0,
    connection = nil,
    override = nil,
  }, OceanQualityController)
end

function OceanQualityController:_Set(name: string)
  self.renderer:SetQuality(name)
  self.runtime:SetAttribute("OceanQuality", name)
  self.cooldown = 10
  self.overBudgetTime = 0
  self.underBudgetTime = 0
end

function OceanQualityController:SetOverride(name: string?)
  self.override = name
  if name then
    self:_Set(name)
  end
end

function OceanQualityController:Start()
  if self.connection then return end
  self.connection = RunService.RenderStepped:Connect(function(dt)
    local attributeOverride = self.runtime:GetAttribute("OceanQualityOverride")
    if type(attributeOverride) == "string" and indexByName[attributeOverride] then
      if self.runtime:GetAttribute("OceanQuality") ~= attributeOverride then
        self:_Set(attributeOverride)
      end
      return
    end
    if self.override or self.runtime:GetAttribute("OceanAdaptiveQuality") ~= true then
      return
    end
    local stats = self.renderer:GetStats()
    local frameMs = stats.lastFrameMs
    self.ema = self.ema == 0 and frameMs or self.ema + (frameMs - self.ema) * (1 - math.exp(-dt * 1.5))
    self.cooldown = math.max(0, self.cooldown - dt)
    if self.ema > 23 then
      self.overBudgetTime += dt
      self.underBudgetTime = 0
    elseif self.ema < 15 then
      self.underBudgetTime += dt
      self.overBudgetTime = 0
    else
      self.overBudgetTime = 0
      self.underBudgetTime = 0
    end
    local current = self.runtime:GetAttribute("OceanQuality") or "Medium"
    local currentIndex = indexByName[current] or 3
    if self.cooldown <= 0 and self.overBudgetTime >= 2 and currentIndex < #order then
      self:_Set(order[currentIndex + 1])
    elseif self.cooldown <= 0 and self.underBudgetTime >= 12 and currentIndex > 1 then
      self:_Set(order[currentIndex - 1])
    end
  end)
end

function OceanQualityController:Stop()
  if self.connection then
    self.connection:Disconnect()
    self.connection = nil
  end
end

return OceanQualityController
