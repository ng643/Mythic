--!strict

local Config = require(script.Parent.OceanConfig)
local OceanClock = require(script.Parent.OceanClock)
local OceanTypes = require(script.Parent.OceanTypes)
local WaveMath = require(script.Parent.WaveMath)

type Clock = typeof(OceanClock.new())

local WaveField = {}
WaveField.__index = WaveField

type Field = typeof(setmetatable({} :: {
  state: OceanTypes.OceanState,
  clock: Clock,
}, WaveField))

local function smoothstep(value: number): number
  local t = math.clamp(value, 0, 1)
  return t * t * (3 - 2 * t)
end

function WaveField.new(initialState: OceanTypes.OceanState, clock: Clock?): Field
  return setmetatable({
    state = initialState,
    clock = clock or OceanClock.new(initialState.epochServerTime),
  }, WaveField)
end

function WaveField:SetState(state: OceanTypes.OceanState)
  self.state = state
end

function WaveField:GetState(): OceanTypes.OceanState
  return self.state
end

function WaveField:GetSynchronizedTime(): number
  return self.clock:Now()
end

function WaveField:StepClock(dt: number): number
  return self.clock:Resync(dt)
end

function WaveField:_BlendAlpha(serverTime: number): number
  local state = self.state
  if state.bankBlendDuration <= 0 then
    return 0
  end
  local normalized = (serverTime - state.bankBlendStart) / state.bankBlendDuration
  local curve = smoothstep(normalized)
  return state.bankBlendTarget >= 0.5 and curve or 1 - curve
end

function WaveField:SampleLagrangian(baseXZ: Vector2, serverTime: number, options: OceanTypes.SampleOptions?): OceanTypes.WaveSample
  local state = self.state
  local alpha = self:_BlendAlpha(serverTime)
  local first = WaveMath.EvaluateLabel(baseXZ, serverTime - state.epochServerTime, state.bankA, state.seaLevel, state.foamThreshold, options, state.disturbances, serverTime)
  if alpha <= 1e-4 or #state.bankB == 0 then
    return first
  end
  local second = WaveMath.EvaluateLabel(baseXZ, serverTime - state.epochServerTime, state.bankB, state.seaLevel, state.foamThreshold, options, state.disturbances, serverTime)
  return WaveMath.BlendSamples(first, second, alpha)
end

function WaveField:SampleWorldXZ(worldXZ: Vector2, serverTime: number, options: OceanTypes.SampleOptions?): OceanTypes.WaveSample
  local iterations = options and options.inverseIterations or 2
  iterations = math.clamp(iterations, 1, 4)
  local label = worldXZ
  local sample = self:SampleLagrangian(label, serverTime, options)
  for _ = 1, iterations do
    local displacement = Vector2.new(sample.position.X - label.X, sample.position.Z - label.Y)
    label = worldXZ - displacement
    sample = self:SampleLagrangian(label, serverTime, options)
  end
  local residualVector = Vector2.new(sample.position.X - worldXZ.X, sample.position.Z - worldXZ.Y)
  sample.inverseResidual = residualVector.Magnitude
  return sample
end

function WaveField:GetGameplayComponentCap(): number
  return math.max(#self.state.bankA, #self.state.bankB)
end

function WaveField:SampleForGameplayWorldXZ(worldXZ: Vector2, serverTime: number, options: OceanTypes.SampleOptions?): OceanTypes.WaveSample
  local requestedIterations = options and options.inverseIterations or 3
  local gameplayOptions: OceanTypes.SampleOptions = {
    inverseIterations = math.max(requestedIterations, 3),
    includeEvents = options == nil or options.includeEvents ~= false,
    componentCap = self:GetGameplayComponentCap(),
    zoneAmplitude = options and options.zoneAmplitude,
    foamMultiplier = options and options.foamMultiplier,
  }
  return self:SampleWorldXZ(worldXZ, serverTime, gameplayOptions)
end

function WaveField:SampleHeight(worldXZ: Vector2, serverTime: number): number
  return self:SampleForGameplayWorldXZ(worldXZ, serverTime).height
end

function WaveField:SampleBatch(worldXZs: {Vector2}, serverTime: number, options: OceanTypes.SampleOptions?): {OceanTypes.WaveSample}
  local results = table.create(#worldXZs)
  for index, worldXZ in ipairs(worldXZs) do
    results[index] = self:SampleWorldXZ(worldXZ, serverTime, options)
  end
  return results
end

function WaveField:ValidateSample(sample: OceanTypes.WaveSample): boolean
  return sample.position.X == sample.position.X
    and sample.position.Y == sample.position.Y
    and sample.position.Z == sample.position.Z
    and sample.normal.Magnitude > 0.999
    and sample.normal.Magnitude < 1.001
    and sample.inverseResidual < 0.25
end

local _ = Config
return WaveField
