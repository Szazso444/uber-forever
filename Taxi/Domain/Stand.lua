local _, ns = ...

-- A provider's taxi stand: a warlock summon stand (the owner plus up to two
-- clickers who share the fare) or a mage portal stand. Pure data and rules; the
-- network side is toFields / fromFields, which match the STAND message.
--
-- Players are full two-part names. Every name is stored tidied
-- (Names.normalize) and matched with Names.same, never by first name alone.
local M = {}

local MAX_CLICKERS = 2

-- The STAND message's fields, the only ones fromFields copies from the wire.
local WIRE_FIELDS = {
  "standId", "kind", "faction", "mapID", "x", "y", "wx", "wy", "zone", "subzone",
  "seatsFree", "clickers", "clickerPct", "portals", "note",
}

-- A name worth storing, or an error: a blank name is a bug in the caller.
local function cleanName(name)
  local clean = ns.Names.normalize(name)
  if clean == nil or clean == "" then
    error("bad player name", 3)
  end
  return clean
end

-- The key under which `name` is stored in s.clickers, or nil.
local function clickerKey(s, name)
  for key in pairs(s.clickers) do
    if ns.Names.same(key, name) then
      return key
    end
  end
end

-- `o`: standId, owner, kind ("lock" or "mage"), faction, mapID, x, y, wx, wy
-- (the world position the move check is measured from), zone, subzone, seats,
-- clickerPct, note, portals (mage only), now.
function M.new(o)
  return {
    standId = o.standId,
    owner = o.owner,
    kind = o.kind,
    faction = o.faction,
    mapID = o.mapID,
    x = o.x,
    y = o.y,
    wx = o.wx,
    wy = o.wy,
    zone = o.zone,
    subzone = o.subzone,
    seats = o.seats or ns.Config.DEFAULT_SEATS,
    clickerPct = o.clickerPct or ns.Config.DEFAULT_CLICKER_PCT,
    note = o.note,
    portals = ns.Util.copy(o.portals or {}),
    createdAt = o.now,
    clickers = {}, -- name -> { pct, joinedAt }
    travelers = {}, -- names, in the order they were seated
    flags = { combat = false, noShards = false },
  }
end

-- Clickers -------------------------------------------------------------------

function M.clickerCount(s)
  local n = 0
  for _ in pairs(s.clickers) do
    n = n + 1
  end
  return n
end

-- The owner's share of the fare: what the clickers leave over.
function M.ownerPct(s)
  local pct = 100
  for _, clicker in pairs(s.clickers) do
    pct = pct - clicker.pct
  end
  return pct
end

local function isShare(pct)
  return type(pct) == "number" and pct == math.floor(pct) and pct >= 1 and pct <= 99
end

-- Seats a clicker at `pct` percent of the fare. Returns true, or nil plus why
-- not: "mage" (portal stands have no clickers), "full" (two already), "bad_pct"
-- (not a whole number from 1 to 99) or "over_share" (the owner would drop below
-- 0%). Adding someone already seated renegotiates their share in place.
function M.addClicker(s, name, pct, now)
  local clean = cleanName(name)
  if s.kind == "mage" then
    return nil, "mage"
  end
  local key = clickerKey(s, clean)
  if key == nil and M.clickerCount(s) >= MAX_CLICKERS then
    return nil, "full"
  end
  if not isShare(pct) then
    return nil, "bad_pct"
  end
  local current = key and s.clickers[key]
  local owner = M.ownerPct(s) + (current and current.pct or 0)
  if pct > owner then
    return nil, "over_share"
  end
  s.clickers[clean] = { pct = pct, joinedAt = current and current.joinedAt or now }
  return true
end

function M.removeClicker(s, name)
  local key = clickerKey(s, name)
  if key ~= nil then
    s.clickers[key] = nil
  end
end

-- Status ---------------------------------------------------------------------

local function anyFlag(s)
  for _, set in pairs(s.flags) do
    if set then
      return true
    end
  end
  return false
end

-- "recruiting" (a warlock stand still short of two clickers), "live",
-- "paused" (a clicker left after it was live, or combat / no shards) or
-- "closed". The only side effect: s.wasLive turns true the first time this
-- computes "live", which is what tells a stand that lost a clicker it is paused
-- and not recruiting. The caller must ask often enough (every heartbeat) for
-- that first live moment not to be missed.
function M.status(s)
  if s.closed then
    return "closed"
  end
  if s.kind == "lock" and M.clickerCount(s) < MAX_CLICKERS then
    return s.wasLive and "paused" or "recruiting"
  end
  if anyFlag(s) then
    return "paused"
  end
  s.wasLive = true
  return "live"
end

-- Travelers ------------------------------------------------------------------

local function travelerIndex(s, name)
  for i, traveler in ipairs(s.travelers) do
    if ns.Names.same(traveler, name) then
      return i
    end
  end
end

function M.seatsFree(s)
  return math.max(0, s.seats - #s.travelers)
end

-- Seats a traveler. Returns true, or nil, "full" when there is no free seat. A
-- traveler already seated keeps the one seat.
function M.addTraveler(s, name)
  local clean = cleanName(name)
  if travelerIndex(s, clean) then
    return true
  end
  if M.seatsFree(s) == 0 then
    return nil, "full"
  end
  s.travelers[#s.travelers + 1] = clean
  return true
end

function M.removeTraveler(s, name)
  local i = travelerIndex(s, name)
  if i ~= nil then
    table.remove(s.travelers, i)
  end
end

-- Group ----------------------------------------------------------------------

-- The owner, the clickers, the seated travelers and `extra` more people (the
-- one asking for a ride, say).
function M.groupSizeWith(s, extra)
  return 1 + M.clickerCount(s) + #s.travelers + (extra or 0)
end

-- A party holds five; a bigger group has to be a raid.
function M.needsRaid(s, extra)
  return M.groupSizeWith(s, extra) > 5
end

-- True when (wx, wy) is farther from the stand than the owner may walk before
-- the stand closes.
function M.movedTooFar(s, wx, wy)
  return ns.Util.distance(s.wx, s.wy, wx, wy) > ns.Config.STAND_MOVE_YARDS
end

-- Wire ------------------------------------------------------------------------

-- The STAND message's fields. The owner is not among them: receivers learn it
-- from the message's sender.
function M.toFields(s)
  return {
    standId = s.standId,
    kind = s.kind,
    faction = s.faction,
    mapID = s.mapID,
    x = s.x,
    y = s.y,
    wx = s.wx,
    wy = s.wy,
    zone = s.zone,
    subzone = s.subzone,
    seatsFree = M.seatsFree(s),
    clickers = M.clickerCount(s),
    clickerPct = s.clickerPct,
    portals = ns.Util.copy(s.portals),
    note = s.note,
  }
end

-- A received stand as the Board keeps it: every STAND field, plus the owner and
-- when it was heard. `sender` is the name the server stamped on the message, so
-- the owner never comes from `f`, whatever it claims.
function M.fromFields(f, sender, now)
  local view = {}
  for _, name in ipairs(WIRE_FIELDS) do
    view[name] = f[name]
  end
  view.portals = type(f.portals) == "table" and ns.Util.copy(f.portals) or {}
  view.owner = sender
  view.seenAt = now
  return view
end

ns.Stand = M
