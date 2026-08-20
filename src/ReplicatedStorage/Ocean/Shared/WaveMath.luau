--!strict

local Config = require(script.Parent.OceanConfig)
local OceanTypes = require(script.Parent.OceanTypes)

local WaveMath = {}
local TWO_PI = math.pi * 2

local function saturate(value: number): number
  return math.clamp(value, 0, 1)
end

local function safeUnit(value: Vector3): Vector3
  if value.Magnitude < 1e-5 then
    return Vector3.yAxis
  end
  return value.Unit
end

local function temporalEnvelope(tau: number, duration: number): number
  local normalized = math.clamp(tau / math.max(duration, 1e-4), 0, 1)
  if normalized < 0.18 then
    local x = normalized / 0.18
    return x * x * (3 - 2 * x)
  elseif normalized > 0.78 then
    local x = (1 - normalized) / 0.22
    return math.max(0, x * x * (3 - 2 * x))
  end
  return 1
end

local function evaluateEvent(event: OceanTypes.WaveEvent, worldXZ: Vector2, serverTime: number, waveGravity: number): (number, Vector2, Vector2)
  local tau = serverTime - event.startServerTime
  if tau < 0 or tau > event.duration then
    return 0, Vector2.zero, Vector2.zero
  end
  local direction = event.direction.Magnitude > 1e-5 and event.direction.Unit or Vector2.xAxis
  local perpendicular = Vector2.new(-direction.Y, direction.X)
  local waveNumber = TWO_PI / math.max(event.wavelength, 1)
  local angularFrequency = math.sqrt(waveGravity * waveNumber)
  local envelope = temporalEnvelope(tau, event.duration)
  local center = event.originXZ + direction * (0.5 * math.sqrt(waveGravity / waveNumber) * tau)
  local relative = worldXZ - center
  local along = relative:Dot(direction)
  local across = relative:Dot(perpendicular)
  local length = math.max(event.length, 1)
  local width = math.max(event.width, 1)
  local gaussian = math.exp(-0.5 * ((along / length) ^ 2 + (across / width) ^ 2)) * envelope
  local phase = waveNumber * along - angularFrequency * tau + event.phase
  phase %= TWO_PI
  local sinPhase = math.sin(phase)
  local cosPhase = math.cos(phase)
  local height = event.amplitude * gaussian * cosPhase
  local dAlong = event.amplitude * gaussian * (-waveNumber * sinPhase - along / (length * length) * cosPhase)
  local dAcross = event.amplitude * gaussian * (-across / (width * width) * cosPhase)
  local gradient = direction * dAlong + perpendicular * dAcross
  local velocity = Vector2.new(direction.X, direction.Y) * (event.amplitude * gaussian * angularFrequency * sinPhase)
  if event.kind == "Radial" or event.kind == "Impact" then
    local radial = relative
    local radius = math.max(radial.Magnitude, 1e-4)
    local radialDir = radial / radius
    local radialPhase = waveNumber * radius - angularFrequency * tau + event.phase
    radialPhase %= TWO_PI
    local radialGaussian = math.exp(-0.5 * (radius / length) ^ 2) * envelope
    height = event.amplitude * radialGaussian * math.sin(radialPhase)
    gradient = radialDir * (event.amplitude * radialGaussian * (waveNumber * math.cos(radialPhase) - radius / (length * length) * math.sin(radialPhase)))
    velocity = radialDir * (-event.amplitude * radialGaussian * angularFrequency * math.cos(radialPhase))
  end
  return height, gradient, velocity
end

local function deriveFoamSignals(
  position: Vector3,
  seaLevel: number,
  normal: Vector3,
  velocity: Vector3,
  jacobian: number,
  foamThreshold: number
)
  local crestHeight = math.max(position.Y - seaLevel, 0)
  local crestFactor = saturate((crestHeight - Config.FoamHeightStart) * Config.FoamHeightGain)
  local upwardMotion = math.max(velocity.Y, 0)
  local horizontalSpeed = Vector2.new(velocity.X, velocity.Z).Magnitude
  local crestMotion = saturate(
    (upwardMotion * Config.FoamUpwardMotionWeight + horizontalSpeed * Config.FoamForwardMotionWeight)
      * Config.FoamMotionGain
  )
  local slope = saturate((1 - math.clamp(normal.Y, 0, 1)) * Config.FoamSlopeGain)
  local compression = saturate((1 - jacobian - foamThreshold) * Config.FoamJacobianGain)
  local foamIntensity = Config.FoamIntensityFromThreshold(foamThreshold)
  local crestEligibility = saturate(
    crestFactor * Config.FoamCrestHeightWeight + crestMotion * Config.FoamCrestMotionWeight
  )
  -- This is a deterministic spatial/temporal hysteresis signal. It is zero
  -- in troughs, but remains nonzero across the descending shoulder after a
  -- crest, avoiding a one-sample whitecap flicker.
  local persistence = saturate(
    (crestFactor * Config.FoamPersistenceCrestWeight
      + compression * Config.FoamPersistenceCompressionWeight
      + crestMotion * Config.FoamPersistenceMotionWeight)
      * crestEligibility
  )
  local foamCore = saturate(
    compression * Config.FoamCompressionWeight
      + slope * Config.FoamSlopeWeight
      + crestMotion * Config.FoamMotionWeight
  )
  local foamGate = saturate(crestEligibility * (0.82 + foamIntensity * 0.18) + persistence * 0.12)
  local foam = saturate(
    (foamCore * foamGate + persistence * Config.FoamPersistenceWeight)
      * (0.35 + foamIntensity * 0.9)
  )
  return crestHeight, crestMotion, slope, compression, persistence, foamIntensity, foam
end

function WaveMath.EvaluateLabel(
  baseXZ: Vector2,
  serverTime: number,
  components: {OceanTypes.WaveComponent},
  seaLevel: number,
  foamThreshold: number,
  options: OceanTypes.SampleOptions?,
  events: {OceanTypes.WaveEvent}?,
  eventServerTime: number?
): OceanTypes.WaveSample
  local position = Vector3.new(baseXZ.X, seaLevel, baseXZ.Y)
  local tangentX = Vector3.new(1, 0, 0)
  local tangentZ = Vector3.new(0, 0, 1)
  local velocity = Vector3.zero
  local componentCap = options and options.componentCap or #components
  local zoneAmplitude = options and options.zoneAmplitude or 1
  local count = math.min(componentCap, #components)
  for index = 1, count do
    local component = components[index]
    local theta = component.waveNumber * component.direction:Dot(baseXZ) - component.angularFrequency * serverTime + component.phase
    theta %= TWO_PI
    local sinTheta = math.sin(theta)
    local cosTheta = math.cos(theta)
    local dx = component.direction.X
    local dz = component.direction.Y
    local amplitude = component.amplitude * zoneAmplitude
    local horizontalAmplitude = component.horizontalAmplitude * zoneAmplitude
    local ak = amplitude * component.waveNumber
    local bk = horizontalAmplitude * component.waveNumber
    position += Vector3.new(horizontalAmplitude * dx * cosTheta, amplitude * sinTheta, horizontalAmplitude * dz * cosTheta)
    tangentX += Vector3.new(-bk * dx * dx * sinTheta, ak * dx * cosTheta, -bk * dx * dz * sinTheta)
    tangentZ += Vector3.new(-bk * dx * dz * sinTheta, ak * dz * cosTheta, -bk * dz * dz * sinTheta)
    velocity += Vector3.new(horizontalAmplitude * dx * component.angularFrequency * sinTheta, -amplitude * component.angularFrequency * cosTheta, horizontalAmplitude * dz * component.angularFrequency * sinTheta)
  end

  if options == nil or options.includeEvents ~= false then
    local eventCount = 0
    for _, event in ipairs(events or {}) do
      if eventCount >= Config.MaxEventsPerSample then break end
      local eventHeight, gradient, horizontalVelocity = evaluateEvent(event, baseXZ, eventServerTime or serverTime, Config.WaveGravity)
      if eventHeight ~= 0 or gradient.Magnitude > 0 then
        position += Vector3.new(0, eventHeight, 0)
        tangentX += Vector3.new(0, gradient.X, 0)
        tangentZ += Vector3.new(0, gradient.Y, 0)
        velocity += Vector3.new(horizontalVelocity.X, 0, horizontalVelocity.Y)
        eventCount += 1
      end
    end
  end

  local normal = safeUnit(tangentZ:Cross(tangentX))
  local jacobian = tangentX.X * tangentZ.Z - tangentX.Z * tangentZ.X
  local crestHeight, crestMotion, slope, compression, persistence, foamIntensity, foam = deriveFoamSignals(
    position,
    seaLevel,
    normal,
    velocity,
    jacobian,
    foamThreshold
  )
  local foamMultiplier = options and options.foamMultiplier or 1
  foam = saturate(foam * foamMultiplier)
  local sample: any = {
    position = position,
    height = position.Y,
    normal = normal,
    velocity = velocity,
    foam = foam,
    jacobian = jacobian,
    inverseResidual = 0,
    crestHeight = crestHeight,
    crestMotion = crestMotion,
    slope = slope,
    compression = compression,
    foamPersistence = persistence,
    foamIntensity = foamIntensity,
  }
  return sample
end

function WaveMath.BlendSamples(a: OceanTypes.WaveSample, b: OceanTypes.WaveSample, alpha: number): OceanTypes.WaveSample
  local t = math.clamp(alpha, 0, 1)
  local normal = safeUnit(a.normal:Lerp(b.normal, t))
  local aa: any = a
  local bb: any = b
  local function blendField(name: string): number
    return (aa[name] or 0) + ((bb[name] or 0) - (aa[name] or 0)) * t
  end
  local sample: any = {
    position = a.position:Lerp(b.position, t),
    height = a.height + (b.height - a.height) * t,
    normal = normal,
    velocity = a.velocity:Lerp(b.velocity, t),
    foam = a.foam + (b.foam - a.foam) * t,
    jacobian = a.jacobian + (b.jacobian - a.jacobian) * t,
    inverseResidual = a.inverseResidual + (b.inverseResidual - a.inverseResidual) * t,
    crestHeight = blendField("crestHeight"),
    crestMotion = blendField("crestMotion"),
    slope = blendField("slope"),
    compression = blendField("compression"),
    foamPersistence = blendField("foamPersistence"),
    foamIntensity = blendField("foamIntensity"),
  }
  return sample
end

local function percentile(values: {number}, fraction: number): number
  if #values == 0 then return 0 end
  table.sort(values)
  local index = math.clamp(math.ceil(#values * fraction), 1, #values)
  return values[index]
end

function WaveMath.MeasureDiagnostics(
  components: {OceanTypes.WaveComponent},
  seaLevel: number,
  foamThreshold: number,
  sampleSeed: number?
): {[string]: number}
  local jacobians = {}
  local foams = {}
  local slopes = {}
  local crestHeights = {}
  local foamSum = 0
  local seed = math.floor(sampleSeed or 0)
  local offsetX = (seed % 53) * 1.73
  local offsetZ = (seed % 47) * 1.37
  local times = {0, 1.17, 2.43, 3.71}
  for timeIndex, sampleTime in ipairs(times) do
    for ix = -4, 4 do
      for iz = -4, 4 do
        local label = Vector2.new(
          ix * 73.25 + offsetX + timeIndex * 11.5,
          iz * 61.75 + offsetZ - timeIndex * 7.25
        )
        local sample: any = WaveMath.EvaluateLabel(
          label,
          sampleTime,
          components,
          seaLevel,
          foamThreshold,
          {includeEvents = false}
        )
        table.insert(jacobians, sample.jacobian)
        table.insert(foams, sample.foam)
        table.insert(slopes, sample.slope)
        table.insert(crestHeights, sample.crestHeight)
        foamSum += sample.foam
      end
    end
  end
  table.sort(jacobians)
  return {
    sampleCount = #foams,
    jacobianMin = jacobians[1] or 0,
    jacobianP01 = percentile(jacobians, 0.01),
    jacobianP05 = percentile(jacobians, 0.05),
    jacobianP50 = percentile(jacobians, 0.50),
    jacobianP95 = percentile(jacobians, 0.95),
    slopeP50 = percentile(slopes, 0.50),
    slopeP90 = percentile(slopes, 0.90),
    slopeP95 = percentile(slopes, 0.95),
    crestHeightP50 = percentile(crestHeights, 0.50),
    crestHeightP90 = percentile(crestHeights, 0.90),
    crestHeightP95 = percentile(crestHeights, 0.95),
    foamMean = foamSum / math.max(#foams, 1),
    foamP50 = percentile(foams, 0.50),
    foamP90 = percentile(foams, 0.90),
    foamP95 = percentile(foams, 0.95),
    foamP99 = percentile(foams, 0.99),
    foamMax = percentile(foams, 1),
  }
end

return WaveMath
