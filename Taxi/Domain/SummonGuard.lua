local _, ns = ...

-- Summon Guard. When a summon is offered, the traveler's addon gathers facts
-- from the traveler's own client and asks this module for a verdict:
-- GREEN (nothing wrong), YELLOW (be careful) or RED (do not accept), plus one
-- plain-English line per check. It never accepts a summon itself.
--
-- A false GREEN can get a Hardcore character killed, so every check fails
-- closed: a missing, blank, NaN or otherwise unusable fact counts as a
-- failure, never as a pass.
local M = {}

local L = ns.L

local RANK = { GREEN = 0, YELLOW = 1, RED = 2 }

-- True only for a real, finite number (not nil, not NaN, not +-infinity).
local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- A string with its ends trimmed, or nil when x is not a string or is blank.
local function clean(x)
  local s = ns.Util.trim(x)
  if s == nil or s == "" then
    return nil
  end
  return s
end

-- A name or place ready to show in a line; "unknown" when there is none.
local function shown(x)
  return clean(x) or L.GUARD_UNKNOWN
end

-- One entry of the verdict. `level` is the level a failure of this check
-- causes, whether or not it failed this time; `text` is the line to show.
local function item(id, ok, level, text)
  return { id = id, ok = ok, level = level, text = text }
end

-- The place the stand agreed on, as the player would read it.
local function agreedPlace(f)
  return clean(f.standZoneLocal) or clean(f.standZone) or clean(f.standSubzone)
end

local function checkSummoner(f)
  local ok = ns.Names.same(f.summoner, f.agreedWarlock)
  if ok then
    return item("summoner", true, "RED", L.fmt("GUARD_SUMMONER_OK", shown(f.summoner)))
  end
  return item("summoner", false, "RED", L.fmt("GUARD_SUMMONER_BAD", shown(f.summoner), shown(f.agreedWarlock)))
end

-- The summon names a destination area in the player's own language, so it is
-- compared with the stand's zone and its subzone. The zone is the player's own
-- name for the stand's map (standZoneLocal); the zone text the stand's message
-- carried (standZone) is the sender's word and counts only when the player's
-- client has no name for that map (R65). Exact match after trimming; a nil
-- candidate is never equal to a real area.
local function checkArea(f)
  local area = clean(f.areaName)
  local zone = clean(f.standZoneLocal) or clean(f.standZone)
  local ok = area ~= nil and (area == zone or area == clean(f.standSubzone))
  if ok then
    return item("area", true, "RED", L.fmt("GUARD_AREA_OK", area))
  end
  return item("area", false, "RED", L.fmt("GUARD_AREA_BAD", shown(f.areaName), shown(agreedPlace(f))))
end

local function checkPosition(f)
  local distance = f.warlockDistance
  local ok = f.warlockInGroup == true
    and f.warlockMapID ~= nil
    and f.warlockMapID == f.standMapID
    and finite(distance)
    and distance >= 0
    and distance <= ns.Config.GUARD_YARDS
  return item("position", ok, "RED", ok and L.GUARD_POS_OK or L.GUARD_POS_BAD)
end

-- Fails for anyone in combat, and also when the crew list itself is missing.
local function checkCombat(f)
  local crew = f.crewInCombat
  if type(crew) == "table" and next(crew) == nil then
    return item("combat", true, "RED", L.GUARD_COMBAT_OK)
  end
  local names = {}
  if type(crew) == "table" then
    for _, name in ipairs(crew) do
      names[#names + 1] = shown(name)
    end
  end
  if #names == 0 then
    names[1] = L.GUARD_UNKNOWN
  end
  return item("combat", false, "RED", L.fmt("GUARD_COMBAT_BAD", table.concat(names, ", ")))
end

-- A zone with no level data (zoneMin nil) passes. A zone with a minimum
-- needs a known player level at or above it.
local function checkLevel(f)
  local zoneMin, level = f.zoneMin, f.playerLevel
  if zoneMin == nil then
    return item("level", true, "YELLOW", L.GUARD_LEVEL_OK)
  end
  if not (finite(zoneMin) and finite(level)) then
    return item("level", false, "YELLOW", L.GUARD_LEVEL_UNKNOWN)
  end
  if level >= zoneMin then
    return item("level", true, "YELLOW", L.GUARD_LEVEL_OK)
  end
  return item("level", false, "YELLOW", L.fmt("GUARD_LEVEL_BAD", zoneMin, level))
end

local function checkChanged(f)
  local ok = f.standChanged == false
  return item("changed", ok, "YELLOW", ok and L.GUARD_CHANGED_OK or L.GUARD_CHANGED_BAD)
end

-- Warns for a new warlock, a low score, or either fact being unknown.
local function checkTrust(f)
  local ok = f.trustIsNew == false
    and finite(f.trustScore)
    and f.trustScore >= ns.Config.GUARD_LOW_TRUST
  return item("trust", ok, "YELLOW", ok and L.GUARD_TRUST_OK or L.GUARD_TRUST_BAD)
end

-- Facts f (built by App/Traveler.lua from the game adapter):
--   hasRide, agreedWarlock, summoner, areaName, standZone, standSubzone,
--   standZoneLocal, warlockInGroup, warlockMapID, standMapID, warlockDistance,
--   crewInCombat (list of names), zoneMin, playerLevel, standChanged,
--   trustScore, trustIsNew
-- Returns { level = "GREEN" | "YELLOW" | "RED", checks = { {id, ok, level, text} } }.
-- The level is the worst level among the failed checks, GREEN when none failed.
function M.evaluate(f)
  if type(f) ~= "table" then
    f = {}
  end

  -- Not a Taxi ride: nothing to compare the summon against, so warn and stop.
  if not f.hasRide then
    local text = L.fmt("GUARD_NO_RIDE", shown(f.summoner), shown(f.areaName))
    return { level = "YELLOW", checks = { item("noride", false, "YELLOW", text) } }
  end

  local checks = {
    checkSummoner(f),
    checkArea(f),
    checkPosition(f),
    checkCombat(f),
    checkLevel(f),
    checkChanged(f),
    checkTrust(f),
  }

  local level = "GREEN"
  for _, c in ipairs(checks) do
    if not c.ok and RANK[c.level] > RANK[level] then
      level = c.level
    end
  end
  return { level = level, checks = checks }
end

ns.SummonGuard = M
