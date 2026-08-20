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
  local jacobian = 1
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

  local eventVelocity = Vector2.zero
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
        eventVelocity += horizontalVelocity
        eventCount += 1
      end
    end
  end

  local normal = safeUnit(tangentZ:Cross(tangentX))
  jacobian = tangentX.X * tangentZ.Z - tangentX.Z * tangentZ.X
  local slope = 1 - math.clamp(normal.Y, 0, 1)
  local compression = saturate((foamThreshold - jacobian) * Config.FoamJacobianGain)
  local elevation = saturate((position.Y - seaLevel - Config.FoamHeightStart) * Config.FoamHeightGain)
  local foam = saturate(compression * 0.7 + slope * 0.35 + elevation * 0.45)
  local foamMultiplier = options and options.foamMultiplier or 1
  foam = saturate(foam * foamMultiplier)
  local _ = eventVelocity
  return {
    position = position,
    height = position.Y,
    normal = normal,
    velocity = velocity,
    foam = foam,
    jacobian = jacobian,
    inverseResidual = 0,
  }
end

function WaveMath.BlendSamples(a: OceanTypes.WaveSample, b: OceanTypes.WaveSample, alpha: number): OceanTypes.WaveSample
  local t = math.clamp(alpha, 0, 1)
  local normal = safeUnit(a.normal:Lerp(b.normal, t))
  return {
    position = a.position:Lerp(b.position, t),
    height = a.height + (b.height - a.height) * t,
    normal = normal,
    velocity = a.velocity:Lerp(b.velocity, t),
    foam = a.foam + (b.foam - a.foam) * t,
    jacobian = a.jacobian + (b.jacobian - a.jacobian) * t,
    inverseResidual = a.inverseResidual + (b.inverseResidual - a.inverseResidual) * t,
  }
end

return WaveMath
