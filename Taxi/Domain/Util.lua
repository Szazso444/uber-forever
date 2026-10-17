local _, ns = ...

-- Small pure helpers shared by the domain modules.
local M = {}

-- Straight-line distance between two points.
function M.distance(x1, y1, x2, y2)
  local dx, dy = x2 - x1, y2 - y1
  return math.sqrt(dx * dx + dy * dy)
end

-- Whole days since the epoch for a timestamp in seconds.
function M.day(ts)
  return math.floor(ts / 86400)
end

-- Strip leading and trailing whitespace. Returns nil when s is not a string.
function M.trim(s)
  if type(s) ~= "string" then
    return nil
  end
  return (s:match("^%s*(.-)%s*$"))
end

-- Shallow copy: new table, same values. Metatables are not copied.
function M.copy(t)
  local out = {}
  for k, v in pairs(t) do
    out[k] = v
  end
  return out
end

ns.Util = M
