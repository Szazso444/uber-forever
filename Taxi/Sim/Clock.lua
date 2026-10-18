local _, ns = ...

-- A simulated clock. Time moves only when advance() is called, and timers run
-- as time passes, so a simulation is deterministic and needs no real waiting.
-- Pure Lua: no WoW API (this file is also loaded in-game for /taxi sim).
--   local clock = ns.Clock.new(1000)
--   clock:after(5, function() ... end)
--   clock:advance(10)   -- the timer runs, with clock:now() == 1005
local M = {}

local Clock = {}
Clock.__index = Clock

-- `start` is the first value of now(), 0 when omitted.
function M.new(start)
  return setmetatable({
    current = start or 0,
    timers = {}, -- ordered by due time; equal times keep scheduling order
  }, Clock)
end

function Clock:now()
  return self.current
end

-- Runs fn once, `seconds` from now. Timers due at the same moment run in the
-- order they were scheduled.
function Clock:after(seconds, fn)
  if type(seconds) ~= "number" or seconds < 0 then
    error("Clock:after needs seconds >= 0", 2)
  end
  local timer = { at = self.current + seconds, fn = fn }
  local timers = self.timers
  local index = #timers + 1
  while index > 1 and timers[index - 1].at > timer.at do
    index = index - 1
  end
  table.insert(timers, index, timer)
end

-- Moves time forward and runs every timer that falls due, in time order. While
-- a timer runs, now() is its own due time. A timer scheduled by another timer
-- runs in the same advance if it is due before the advance ends.
function Clock:advance(seconds)
  if type(seconds) ~= "number" or seconds < 0 then
    error("Clock:advance needs seconds >= 0", 2)
  end
  local target = self.current + seconds
  local timers = self.timers
  while timers[1] and timers[1].at <= target do
    local timer = table.remove(timers, 1)
    if timer.at > self.current then
      self.current = timer.at
    end
    timer.fn()
  end
  self.current = target
end

ns.Clock = M
