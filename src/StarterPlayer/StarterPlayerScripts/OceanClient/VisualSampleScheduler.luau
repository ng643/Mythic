--!strict

local VisualSampleScheduler = {}
VisualSampleScheduler.__index = VisualSampleScheduler

local function quantize(value: number, step: number): number
  return math.floor(value / step + 0.5) * step
end

function VisualSampleScheduler.new(waveField)
  return setmetatable({waveField = waveField, bucket = -1, cache = {}, samples = 0, hits = 0}, VisualSampleScheduler)
end

function VisualSampleScheduler:_Begin(serverTime: number)
  local bucket = math.floor(serverTime * 30)
  if bucket ~= self.bucket then
    self.bucket = bucket
    table.clear(self.cache)
    self.samples = 0
    self.hits = 0
  end
end

function VisualSampleScheduler:Sample(worldXZ: Vector2, serverTime: number, options)
  self:_Begin(serverTime)
  local x = quantize(worldXZ.X, 0.5)
  local z = quantize(worldXZ.Y, 0.5)
  local inverseIterations = options and options.inverseIterations or 3
  local componentCap = options and options.componentCap or self.waveField:GetGameplayComponentCap()
  local includeEvents = options == nil or options.includeEvents ~= false
  local key = string.format("%.1f:%.1f:%d:%d:%s", x, z, inverseIterations, componentCap, tostring(includeEvents))
  local cached = self.cache[key]
  if cached then
    self.hits += 1
    return cached
  end
  local sample = self.waveField:SampleWorldXZ(Vector2.new(x, z), serverTime, options)
  self.cache[key] = sample
  self.samples += 1
  return sample
end

function VisualSampleScheduler:GetDiagnostics()
  return {samples = self.samples, hits = self.hits, bucket = self.bucket}
end

return VisualSampleScheduler
