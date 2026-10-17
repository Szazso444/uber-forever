local _, ns = ...

-- Player-facing strings (English). Later tasks add their keys to this table.
-- ns.L[key] reads a string; a missing key falls back to the key itself so a
-- gap shows up on screen instead of raising an error in a UI handler.
-- ns.L.fmt(key, ...) is string.format(ns.L[key], ...).
local M = {}

-- Summon Guard (Domain/SummonGuard.lua): one line per check.
M.GUARD_NO_RIDE = "Not a Taxi ride: %s → %s"
M.GUARD_UNKNOWN = "unknown" -- stands in for a name or place the guard could not read
M.GUARD_SUMMONER_OK = "Summoner: %s"
M.GUARD_SUMMONER_BAD = "Summoner: %s (agreed: %s)"
M.GUARD_AREA_OK = "Destination: %s"
M.GUARD_AREA_BAD = "Destination: %s (agreed: %s)"
M.GUARD_POS_OK = "Warlock is at the stand"
M.GUARD_POS_BAD = "Warlock is not at the agreed spot"
M.GUARD_COMBAT_OK = "Nobody in combat"
M.GUARD_COMBAT_BAD = "In combat: %s"
M.GUARD_LEVEL_OK = "Zone level is fine"
M.GUARD_LEVEL_BAD = "Zone is level %d+, you are %d"
M.GUARD_LEVEL_UNKNOWN = "Can't tell if this zone suits your level"
M.GUARD_CHANGED_OK = "Stand hasn't moved"
M.GUARD_CHANGED_BAD = "Stand moved after you requested"
M.GUARD_TRUST_OK = "Trust rating OK"
M.GUARD_TRUST_BAD = "Low or new Trust rating"

-- Engine status lines (App/Engine.lua), shown with STATUS events.
M.STATUS_CHANNEL_FULL = "Taxi needs a free chat channel. Leave one (e.g. /leave 5) and /reload."
M.STATUS_LOCKDOWN = "Paused (instance)"
M.STATUS_UPDATE = "A newer Taxi version is in use. Please update."

function M.fmt(key, ...)
  return string.format(M[key], ...)
end

setmetatable(M, {
  __index = function(_, key)
    return key
  end,
})

ns.L = M
