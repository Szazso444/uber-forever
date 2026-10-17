local _, ns = ...

-- Money helpers. All amounts are whole copper: 100c = 1s, 100s = 1g.
local M = {}

local COPPER_PER_SILVER = 100
local COPPER_PER_GOLD = 10000

-- One part (gold, silver or copper) is valid when it is a missing value (zero)
-- or a non-negative whole number. NaN fails the >= test.
local function validPart(v)
  return type(v) == "number" and v >= 0 and v == math.floor(v)
end

-- Gold, silver and copper to copper. Missing parts count as zero. Returns nil
-- for a negative, fractional, non-numeric or oversized part, and for 0g 0s 0c.
function M.fromParts(g, s, c)
  g, s, c = g or 0, s or 0, c or 0
  if not (validPart(g) and validPart(s) and validPart(c)) then
    return nil
  end
  local total = g * COPPER_PER_GOLD + s * COPPER_PER_SILVER + c
  if total == 0 or total >= math.huge then
    return nil
  end
  return total
end

-- Copper to text such as "1g 50s", "50s", "1g" or "25s 50c": non-zero units
-- only, largest first. Display only, so junk input shows "0c" instead of
-- raising an error in the UI.
function M.format(copper)
  if type(copper) ~= "number" or not (copper >= 0 and copper < math.huge) then
    return "0c"
  end
  copper = math.floor(copper)
  local gold = math.floor(copper / COPPER_PER_GOLD)
  local silver = math.floor(copper % COPPER_PER_GOLD / COPPER_PER_SILVER)
  local rest = copper % COPPER_PER_SILVER
  local parts = {}
  if gold > 0 then
    parts[#parts + 1] = gold .. "g"
  end
  if silver > 0 then
    parts[#parts + 1] = silver .. "s"
  end
  if rest > 0 then
    parts[#parts + 1] = rest .. "c"
  end
  if #parts == 0 then
    return "0c"
  end
  return table.concat(parts, " ")
end

-- A tip must be a positive whole number of copper that the player can pay.
-- Returns true, or nil plus a reason: "zero" (nothing to pay, including any
-- invalid amount) or "too_much" (more than playerMoney).
function M.validateTip(copper, playerMoney)
  if not validPart(copper) or copper == 0 then
    return nil, "zero"
  end
  if copper > (type(playerMoney) == "number" and playerMoney or 0) then
    return nil, "too_much"
  end
  return true
end

ns.Money = M
