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
  local maxAgreement = 0
  local maxNormalError = 0
  local deterministic = true
  local valid = true
  for _, position in ipairs({Vector2.new(0, 0), Vector2.new(37.25, -19.5), Vector2.new(2048, 1024), Vector2.new(-8192, 4096)}) do
    local options = {inverseIterations = 3, componentCap = field:GetGameplayComponentCap()}
    local a = field:SampleWorldXZ(position, epoch + 4.5, options)
    local b = field:SampleWorldXZ(position, epoch + 4.5, options)
    local gameplay = field:SampleForGameplayWorldXZ(position, epoch + 4.5)
    deterministic = deterministic and a.position == b.position and a.height == b.height
    maxResidual = math.max(maxResidual, a.inverseResidual)
    maxAgreement = math.max(maxAgreement, (a.position - gameplay.position).Magnitude, math.abs(a.height - gameplay.height))
    maxNormalError = math.max(maxNormalError, math.abs(a.normal.Magnitude - 1))
    valid = valid and finite(a.height) and finite(a.position.X) and finite(a.position.Z) and finite(a.foam) and finite(gameplay.height)
  end

  local expectedPeak = Config.WaveGravity * preset.peakPeriodSeconds ^ 2 / (math.pi * 2)
  local expectedSwell = Config.WaveGravity * preset.swellPeriodSeconds ^ 2 / (math.pi * 2)
  local peakError = math.huge
  local swellError = math.huge
  local distinct = {}
  for _, component in ipairs(state.bankA) do
    peakError = math.min(peakError, math.abs(component.wavelength - expectedPeak))
    swellError = math.min(swellError, math.abs(component.wavelength - expectedSwell))
    distinct[string.format("%.2f", component.wavelength)] = true
  end
  local distinctCount = 0
  for _ in pairs(distinct) do distinctCount += 1 end

  local steepness = 0
  for _, component in ipairs(state.bankA) do
    steepness += component.waveNumber * math.abs(component.horizontalAmplitude)
  end
  local transitionSample = field:SampleWorldXZ(Vector2.new(20, 20), epoch + 9.9, {inverseIterations = 3})
  local transitionSampleNext = field:SampleWorldXZ(Vector2.new(20, 20), epoch + 10.1, {inverseIterations = 3})
  local continuity = (transitionSample.position - transitionSampleNext.position).Magnitude < 4

  local lifecycle = true
  local serverFolder = game:FindFirstChild("ServerScriptService")
  local stateModule = serverFolder and serverFolder:FindFirstChild("OceanServer") and serverFolder.OceanServer:FindFirstChild("OceanStateService")
  if stateModule then
    local service = require(stateModule).new()
    service:TransitionTo("Gale", 5)
    local destination = service:GetState().bankB
    service.state.bankBlendStart = workspace:GetServerTimeNow() - 6
    service:GetState()
    local promoted = service:GetState().bankA
    service:TransitionTo("Mythic Storm", 5)
    lifecycle = promoted[1].wavelength == service:GetState().bankA[1].wavelength and destination[1].wavelength == promoted[1].wavelength
  end

  checks.deterministic = deterministic
  checks.finite = valid
  checks.normal = maxNormalError <= 0.001
  checks.residual = maxResidual < 0.1
  checks.steepness = steepness <= Config.MaxAggregateSteepness + 0.001
  checks.transitionContinuity = continuity
  checks.spectrumPeak = peakError < 0.01
  checks.spectrumSwell = swellError < 0.01
  checks.distinctWavelengths = distinctCount >= 10
  checks.gameplayAgreement = maxAgreement <= 0.05
  checks.transitionLifecycle = lifecycle
  local passed = true
  for _, check in pairs(checks) do passed = passed and check end
  return {
    passed = passed,
    checks = checks,
    details = {
      maxResidual = maxResidual,
      maxNormalError = maxNormalError,
      maxAgreement = maxAgreement,
      steepness = steepness,
      peakError = peakError,
      swellError = swellError,
      distinctWavelengths = distinctCount,
      expectedPeak = expectedPeak,
      expectedSwell = expectedSwell,
    },
  }
end

return Tests
