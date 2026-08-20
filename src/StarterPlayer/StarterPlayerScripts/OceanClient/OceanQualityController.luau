--!strict

local RunService = game:GetService("RunService")

local OceanQualityController = {}
OceanQualityController.__index = OceanQualityController

local order = {"Ultra", "High", "Medium", "Low"}
local indexByName = {Ultra = 1, High = 2, Medium = 3, Low = 4}
local WARMUP_DURATION = 2
local INITIAL_COOLDOWN = 5
local TRANSITION_COOLDOWN = 10

local function topologyChangedFromResult(result: any): boolean
  if type(result) == "table" then
    return result.topologyChanged == true
  end
  return result == true
end

function OceanQualityController.new(renderer, runtime)
  local currentQuality = runtime:GetAttribute("OceanQuality")
  if type(currentQuality) ~= "string" or currentQuality == "" then
    currentQuality = renderer.qualityName
  end
  if type(currentQuality) ~= "string" or currentQuality == "" then
    currentQuality = "Medium"
  end
  return setmetatable({
    renderer = renderer,
    runtime = runtime,
    ema = 0,
    overBudgetTime = 0,
    underBudgetTime = 0,
    warmup = WARMUP_DURATION,
    cooldown = INITIAL_COOLDOWN,
    connection = nil,
    override = nil,
    currentQuality = currentQuality,
  }, OceanQualityController)
end

function OceanQualityController:_CurrentQuality(): string
  local current = self.runtime:GetAttribute("OceanQuality")
  if type(current) == "string" and current ~= "" then
    self.currentQuality = current
  elseif type(self.renderer.qualityName) == "string" and self.renderer.qualityName ~= "" then
    self.currentQuality = self.renderer.qualityName
  end
  return self.currentQuality
end

function OceanQualityController:_PublishChange(oldQuality: string, newQuality: string, reason: string, topologyChanged: boolean)
  self.runtime:SetAttribute("OceanQualityChangeOld", oldQuality)
  self.runtime:SetAttribute("OceanQualityChangeNew", newQuality)
  self.runtime:SetAttribute("OceanQualityChangeReason", reason)
  self.runtime:SetAttribute("OceanQualityChangeTimestamp", os.clock())
  self.runtime:SetAttribute("OceanQualityTopologyChanged", topologyChanged)
end

function OceanQualityController:_Set(name: string, reason: string): boolean
  local oldQuality = self:_CurrentQuality()
  if oldQuality == name then
    return false
  end
  local result = self.renderer:SetQuality(name)
  local topologyChanged = topologyChangedFromResult(result)
  self.currentQuality = name
  self.runtime:SetAttribute("OceanQuality", name)
  self:_PublishChange(oldQuality, name, reason, topologyChanged)
  self.cooldown = TRANSITION_COOLDOWN
  self.overBudgetTime = 0
  self.underBudgetTime = 0
  return true
end

function OceanQualityController:SetOverride(name: string?): (boolean, string?)
  if name == "Fallback" then
    return false, "Fallback quality overrides are not supported"
  end
  if name ~= nil and not indexByName[name] then
    return false, "Unknown quality override: " .. tostring(name)
  end
  self.override = name
  if name then
    self:_Set(name, "explicit override")
  end
  return true
end

function OceanQualityController:Start()
  if self.connection then return end
  self.connection = RunService.RenderStepped:Connect(function(dt)
    local attributeOverride = self.runtime:GetAttribute("OceanQualityOverride")
    if type(attributeOverride) == "string" and indexByName[attributeOverride] then
      if self:_CurrentQuality() ~= attributeOverride then
        self:_Set(attributeOverride, "attribute override")
      end
      return
    end
    if self.override or self.runtime:GetAttribute("OceanAdaptiveQuality") ~= true then
      return
    end
    local stats = self.renderer:GetStats()
    local frameMs = stats.lastFrameMs
    self.ema = self.ema == 0 and frameMs or self.ema + (frameMs - self.ema) * (1 - math.exp(-dt * 1.5))
    if self.warmup > 0 then
      self.warmup = math.max(0, self.warmup - dt)
      self.overBudgetTime = 0
      self.underBudgetTime = 0
      return
    end
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
    local current = self:_CurrentQuality()
    local currentIndex = indexByName[current] or 3
    if self.cooldown <= 0 and self.overBudgetTime >= 2 and currentIndex < #order then
      self:_Set(order[currentIndex + 1], "adaptive over budget")
    elseif self.cooldown <= 0 and self.underBudgetTime >= 12 and currentIndex > 1 then
      self:_Set(order[currentIndex - 1], "adaptive under budget")
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
