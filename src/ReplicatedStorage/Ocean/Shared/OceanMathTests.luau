--!strict

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Shared = ReplicatedStorage.Ocean.Shared
local Config = require(Shared.OceanConfig)
local Presets = require(Shared.OceanPresets)
local Spectrum = require(Shared.SpectrumGenerator)
local WaveMath = require(Shared.WaveMath)
local WaveField = require(Shared.WaveField)

local Tests = {}

local orderedPresets = {"Glass Harbour", "Calm Open Sea", "Trade Sea", "Gale", "Mythic Storm"}
local steepnessRanges = {
  ["Glass Harbour"] = {0.18, 0.28},
  ["Calm Open Sea"] = {0.20, 0.30},
  ["Trade Sea"] = {0.32, 0.42},
  Gale = {0.40, 0.50},
  ["Mythic Storm"] = {0.48, 0.58},
}

local function finite(value: number): boolean
  return value == value and value > -math.huge and value < math.huge
end

local function compareBanks(a: {{direction: Vector2, amplitude: number, wavelength: number, horizontalAmplitude: number, phase: number}}, b: {{direction: Vector2, amplitude: number, wavelength: number, horizontalAmplitude: number, phase: number}}): boolean
  if #a ~= #b then return false end
  for index, first in ipairs(a) do
    local second = b[index]
    if first.direction ~= second.direction
      or first.amplitude ~= second.amplitude
      or first.wavelength ~= second.wavelength
      or first.horizontalAmplitude ~= second.horizontalAmplitude
      or first.phase ~= second.phase then
      return false
    end
  end
  return true
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
  local checks: {[string]: boolean} = {}
  local maxResidual = 0
  local maxAgreement = 0
  local maxNormalError = 0
  local deterministic = true
  local valid = true
  local troughFoamMax = 0

  for _, position in ipairs({Vector2.new(0, 0), Vector2.new(37.25, -19.5), Vector2.new(2048, 1024), Vector2.new(-8192, 4096)}) do
    local options = {inverseIterations = 3, componentCap = field:GetGameplayComponentCap()}
    local a: any = field:SampleWorldXZ(position, epoch + 4.5, options)
    local b: any = field:SampleWorldXZ(position, epoch + 4.5, options)
    local gameplay: any = field:SampleForGameplayWorldXZ(position, epoch + 4.5)
    deterministic = deterministic
      and a.position == b.position
      and a.height == b.height
      and a.foam == b.foam
      and a.crestMotion == b.crestMotion
    maxResidual = math.max(maxResidual, a.inverseResidual)
    maxAgreement = math.max(maxAgreement, (a.position - gameplay.position).Magnitude, math.abs(a.height - gameplay.height))
    maxNormalError = math.max(maxNormalError, math.abs(a.normal.Magnitude - 1))
    valid = valid
      and finite(a.height)
      and finite(a.position.X)
      and finite(a.position.Z)
      and finite(a.foam)
      and finite(a.crestHeight)
      and finite(a.crestMotion)
      and finite(a.slope)
      and finite(a.compression)
      and finite(a.foamPersistence)
      and gameplay.height == gameplay.height
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

  local spectrumHs = true
  local spectrumSteepness = true
  local spectrumJacobian = true
  local spectrumFoam = true
  local spectrumDeterministic = true
  local spectrumBands = true
  local foamMonotonic = true
  local previousFoamMean = -math.huge
  local previousFoamP90 = -math.huge
  local measuredHs = 0
  local measuredSteepness = 0
  local minimumJacobian = math.huge
  local maximumFoamP99 = 0
  local minimumFoamP50 = math.huge

  for _, name in ipairs(orderedPresets) do
    local currentPreset = Presets.Get(name)
    local bank = Spectrum.Generate(currentPreset, 20260820)
    local repeatBank = Spectrum.Generate(currentPreset, 20260820)
    spectrumDeterministic = spectrumDeterministic and compareBanks(bank, repeatBank)
    local targetHs = currentPreset.significantWaveHeightMeters * Config.MetersToStuds
    local summary = Spectrum.Summarize(bank, targetHs, Config.TargetAggregateSteepness(currentPreset))
    local diagnostics = WaveMath.MeasureDiagnostics(
      bank,
      Config.DefaultSeaLevel,
      Config.FoamThresholdForPreset(currentPreset),
      20260820
    )
    local range = steepnessRanges[name]
    local tailCount = 0
    for _, component in ipairs(bank) do
      if component.wavelength >= 20 and component.wavelength <= 160 then
        tailCount += 1
    end
    end
    measuredHs = math.max(measuredHs, summary.significantHeight)
    measuredSteepness = math.max(measuredSteepness, summary.aggregateSteepness)
    minimumJacobian = math.min(minimumJacobian, diagnostics.jacobianMin)
    maximumFoamP99 = math.max(maximumFoamP99, diagnostics.foamP99)
    minimumFoamP50 = math.min(minimumFoamP50, diagnostics.foamP50)
    spectrumHs = spectrumHs and summary.hsErrorRatio <= 0.05
    spectrumSteepness = spectrumSteepness
      and summary.aggregateSteepness >= range[1]
      and summary.aggregateSteepness <= range[2]
      and summary.aggregateSteepness <= Config.MaxAggregateSteepness
    spectrumJacobian = spectrumJacobian
      and diagnostics.jacobianMin > 0
      and diagnostics.jacobianP01 > 0
    spectrumFoam = spectrumFoam
      and diagnostics.foamP50 >= 0
      and diagnostics.foamP99 <= 1
    spectrumBands = spectrumBands and #bank >= 4 and #bank <= 6 and tailCount >= 1
    foamMonotonic = foamMonotonic
      and diagnostics.foamMean + 0.01 >= previousFoamMean
      and diagnostics.foamP90 + 0.01 >= previousFoamP90
    previousFoamMean = diagnostics.foamMean
    previousFoamP90 = diagnostics.foamP90

    -- A low crest cannot produce broad trough foam. The signal remains
    -- deterministic because it is derived entirely from the synchronized
    -- components and phase.
    for ix = -3, 3 do
      for iz = -3, 3 do
        local sample: any = WaveMath.EvaluateLabel(
          Vector2.new(ix * 47.5, iz * 47.5),
          1.73,
          bank,
          Config.DefaultSeaLevel,
          Config.FoamThresholdForPreset(currentPreset),
          {includeEvents = false}
        )
        if sample.crestHeight <= Config.FoamHeightStart * 0.25 then
          troughFoamMax = math.max(troughFoamMax, sample.foam)
        end
      end
    end
  end

  local transitionSample: any = field:SampleWorldXZ(Vector2.new(20, 20), epoch + 9.9, {inverseIterations = 3})
  local transitionSampleNext: any = field:SampleWorldXZ(Vector2.new(20, 20), epoch + 10.1, {inverseIterations = 3})
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
    lifecycle = promoted[1].wavelength == service:GetState().bankA[1].wavelength
      and destination[1].wavelength == promoted[1].wavelength
  end

  local steepness = 0
  for _, component in ipairs(state.bankA) do
    steepness += component.waveNumber * math.abs(component.horizontalAmplitude)
  end
  checks.deterministic = deterministic
  checks.spectrumDeterminism = spectrumDeterministic
  checks.finite = valid
  checks.normal = maxNormalError <= 0.001
  checks.residual = maxResidual < 0.1
  checks.steepness = steepness <= Config.MaxAggregateSteepness + 0.001
  checks.spectrumHs = spectrumHs
  checks.spectrumSteepness = spectrumSteepness
  checks.jacobianPositive = spectrumJacobian
  checks.foamFiniteAndBounded = spectrumFoam
  checks.foamMonotonic = foamMonotonic
  checks.foamAvoidsTroughs = troughFoamMax < 0.35
  checks.spectrumBands = spectrumBands
  checks.transitionContinuity = continuity
  checks.spectrumPeak = peakError < 0.01
  checks.spectrumSwell = swellError < 0.01
  checks.distinctWavelengths = distinctCount >= 4
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
      measuredHsMax = measuredHs,
      measuredSteepnessMax = measuredSteepness,
      minimumJacobian = minimumJacobian,
      maximumFoamP99 = maximumFoamP99,
      minimumFoamP50 = minimumFoamP50,
      troughFoamMax = troughFoamMax,
      peakError = peakError,
      swellError = swellError,
      distinctWavelengths = distinctCount,
      expectedPeak = expectedPeak,
      expectedSwell = expectedSwell,
    },
  }
end

return Tests
