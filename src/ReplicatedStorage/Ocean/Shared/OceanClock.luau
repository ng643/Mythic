--!strict

local Workspace = game:GetService("Workspace")

local OceanClock = {}
OceanClock.__index = OceanClock

type Clock = typeof(setmetatable({} :: {
  offset: number,
  targetOffset: number,
  epoch: number,
  resyncTimer: number,
}, OceanClock))

function OceanClock.new(epoch: number?): Clock
  local serverNow = Workspace:GetServerTimeNow()
  local localNow = os.clock()
  local resolvedEpoch = epoch or serverNow
  return setmetatable({
    offset = serverNow - localNow,
    targetOffset = serverNow - localNow,
    epoch = resolvedEpoch,
    resyncTimer = 0,
  }, OceanClock)
end

function OceanClock:Now(): number
  return os.clock() + self.offset
end

function OceanClock:GetEpoch(): number
  return self.epoch
end

function OceanClock:Resync(dt: number): number
  self.resyncTimer += math.max(dt, 0)
  if self.resyncTimer >= 15 then
    self.resyncTimer = 0
    self.targetOffset = Workspace:GetServerTimeNow() - os.clock()
  end
  local alpha = 1 - math.exp(-math.max(dt, 0) * 0.35)
  self.offset += (self.targetOffset - self.offset) * alpha
  return self:Now()
end

function OceanClock:SecondsSinceEpoch(): number
  return self:Now() - self.epoch
end

return OceanClock
