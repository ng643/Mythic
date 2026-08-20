--!strict

local RenderEvaluator = {}
local TWO_PI = math.pi * 2

local function safeUnit(x: number, y: number, z: number): Vector3
  local magnitude = math.sqrt(x * x + y * y + z * z)
  if magnitude < 1e-5 or magnitude ~= magnitude then
    return Vector3.yAxis
  end
  return Vector3.new(x / magnitude, y / magnitude, z / magnitude)
end

function RenderEvaluator.Prepare(components, serverTime: number, componentCap: number)
  local count = math.min(componentCap, #components)
  local plans = table.create(count)
  for index = 1, count do
    local component = components[index]
    plans[index] = {
      dx = component.direction.X,
      dz = component.direction.Y,
      amplitude = component.amplitude,
      horizontalAmplitude = component.horizontalAmplitude,
      waveNumber = component.waveNumber,
      angularFrequency = component.angularFrequency,
      phase = component.phase - component.angularFrequency * serverTime,
    }
  end
  return plans
end

local function evaluatePlan(baseX: number, baseZ: number, seaLevel: number, plan, residualWeight: number, sharedCount: number)
  local positionX = baseX
  local positionY = seaLevel
  local positionZ = baseZ
  local tangentXX = 1
  local tangentXY = 0
  local tangentXZ = 0
  local tangentZX = 0
  local tangentZY = 0
  local tangentZZ = 1

  for index = 1, #plan do
    local component = plan[index]
    local weight = index <= sharedCount and 1 or residualWeight
    if weight > 0 then
      local dx = component.dx
      local dz = component.dz
      local theta = component.waveNumber * (dx * baseX + dz * baseZ) + component.phase
      theta %= TWO_PI
      local sinTheta = math.sin(theta)
      local cosTheta = math.cos(theta)
      local amplitude = component.amplitude * weight
      local horizontalAmplitude = component.horizontalAmplitude * weight
      local ak = amplitude * component.waveNumber
      local bk = horizontalAmplitude * component.waveNumber
      positionX += horizontalAmplitude * dx * cosTheta
      positionY += amplitude * sinTheta
      positionZ += horizontalAmplitude * dz * cosTheta
      tangentXX += -bk * dx * dx * sinTheta
      tangentXY += ak * dx * cosTheta
      tangentXZ += -bk * dx * dz * sinTheta
      tangentZX += -bk * dx * dz * sinTheta
      tangentZY += ak * dz * cosTheta
      tangentZZ += -bk * dz * dz * sinTheta
    end
  end

  local normalX = tangentZY * tangentXZ - tangentZZ * tangentXY
  local normalY = tangentZZ * tangentXX - tangentZX * tangentXZ
  local normalZ = tangentZX * tangentXY - tangentZY * tangentXX
  return positionX, positionY, positionZ, safeUnit(normalX, normalY, normalZ)
end

function RenderEvaluator.Evaluate(
  baseX: number,
  baseZ: number,
  seaLevel: number,
  planA,
  planB,
  blendAlpha: number,
  sharedCount: number,
  residualWeight: number
): (Vector3, Vector3)
  local ax, ay, az, anormal = evaluatePlan(baseX, baseZ, seaLevel, planA, residualWeight, sharedCount)
  if blendAlpha <= 0 or planB == nil then
    return Vector3.new(ax, ay, az), anormal
  end
  local bx, by, bz, bnormal = evaluatePlan(baseX, baseZ, seaLevel, planB, residualWeight, sharedCount)
  local t = math.clamp(blendAlpha, 0, 1)
  return Vector3.new(ax + (bx - ax) * t, ay + (by - ay) * t, az + (bz - az) * t), anormal:Lerp(bnormal, t).Unit
end

return RenderEvaluator
