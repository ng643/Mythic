--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Ocean.Shared
local Config = require(Shared.OceanConfig)
local Presets = require(Shared.OceanPresets)
local Spectrum = require(Shared.SpectrumGenerator)
local WaveField = require(Shared.WaveField)

local Tests = {}

local function finite(value: number): boolean
  return value == value and value > -math.huge and value < math.huge
end

function Tests.Run(): {passed: boolean, checks: {[string]: boolean}, details: {[string]: number}}
  local epoch = workspace:GetServerTimeNow()
  local preset = Presets.Get("Trade Sea")
  local state = Spectrum.BuildState(preset, 20260820, epoch)
  state.bankB = Spectrum.Generate(Presets.Get("Gale"), 20260821)
  state.bankBlendStart = epoch + 10
  state.bankBlendDuration = 20
  state.bankBlendTarget = 1
  local field = WaveField.new(state)
  local checks = {}
  local maxResidual = 0
  local minNormalError = 0
  local deterministic = true
  local valid = true
  for _, position in ipairs({Vector2.new(0, 0), Vector2.new(37.25, -19.5), Vector2.new(2048, 1024), Vector2.new(-8192, 4096)}) do
    local a = field:SampleWorldXZ(position, epoch + 4.5, {inverseIterations = 3, componentCap = 14})
    local b = field:SampleWorldXZ(position, epoch + 4.5, {inverseIterations = 3, componentCap = 14})
    deterministic = deterministic and a.position == b.position and a.height == b.height
    maxResidual = math.max(maxResidual, a.inverseResidual)
    minNormalError = math.max(minNormalError, math.abs(a.normal.Magnitude - 1))
    valid = valid and finite(a.height) and finite(a.position.X) and finite(a.position.Z) and finite(a.foam)
  end
  local steepness = 0
  for _, component in ipairs(state.bankA) do
    steepness += component.waveNumber * math.abs(component.horizontalAmplitude)
  end
  local transitionSample = field:SampleWorldXZ(Vector2.new(20, 20), epoch + 9.9, {inverseIterations = 3})
  local transitionSampleNext = field:SampleWorldXZ(Vector2.new(20, 20), epoch + 10.1, {inverseIterations = 3})
  local continuity = (transitionSample.position - transitionSampleNext.position).Magnitude < 4
  checks.deterministic = deterministic
  checks.finite = valid
  checks.normal = minNormalError <= 0.001
  checks.residual = maxResidual < 0.1
  checks.steepness = steepness <= Config.MaxAggregateSteepness + 0.001
  checks.transitionContinuity = continuity
  local passed = true
  for _, check in pairs(checks) do passed = passed and check end
  return {
    passed = passed,
    checks = checks,
    details = {maxResidual = maxResidual, maxNormalError = minNormalError, steepness = steepness},
  }
end

return Tests
