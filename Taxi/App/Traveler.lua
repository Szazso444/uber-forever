local _, ns = ...

-- Traveler: asking a stand for a ride and taking it, as methods and handlers on
-- the Engine. The traveler requests a seat, joins the driver's group, is shown
-- the Summon Guard's verdict when a summon is offered, notices the arrival,
-- and rates and tips at the end.
--
-- My copy of a ride is filed under me .. "#" .. standId and keeps a copy of
-- the stand as it was when I asked (ride.stand, R6): if the stand leaves the
-- board, the guard still compares the summon with the place I agreed to.
--
-- The guard decides whether a Hardcore traveler accepts a summon, so its facts
-- are gathered to fail closed: real booleans for standChanged, trustIsNew and
-- warlockInGroup, a list for crewInCombat, and nil (never 0, false or "") for
-- anything the game can't tell (R20, R21).
--
-- The Engine drops the player's own messages, so my own RIDE_START and
-- ARRIVED are recorded in my witness here (R40); otherwise my own death would
-- never be reported.
--
-- Pure Lua: no WoW API (this file is also loaded in-game for /taxi sim).
local Engine, Config, Names, Util = ns.Engine, ns.Config, ns.Names, ns.Util
local Board, Ride, SummonGuard, Ratings, Money = ns.Board, ns.Ride, ns.SummonGuard, ns.Ratings, ns.Money

local MAX_RESENDS = 2 -- a request goes out at most three times
-- A group member counts as the stand's crew for the combat check when they are
-- this close to the landing spot (or can't be placed at all).
local CREW_YARDS = 100

-- Where the stand is; a moved stand differs in one of these (as Board).
local PLACE_FIELDS = { "mapID", "wx", "wy", "zone", "subzone" }

-- True only for a real, finite number (not nil, not NaN, not +-infinity).
local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function isMine(e, ride)
  return ride ~= nil and Names.same(ride.traveler, e.me)
end

local function keyFor(e, standId)
  return Names.normalize(e.me) .. "#" .. tostring(standId)
end

-- My ride (as its traveler) with this ride id, or nil.
local function rideById(e, rideId)
  if type(rideId) ~= "string" then
    return nil
  end
  for _, ride in pairs(e.rides) do
    if ride.rideId == rideId and isMine(e, ride) then
      return ride
    end
  end
  return nil
end

-- The stand as the ride sees it: the live board view when there is one, else
-- the copy taken when I asked (R6).
local function standOf(e, ride)
  return Board.get(e.board, ride.standId) or ride.stand
end

local function offers(view, dest)
  for _, key in ipairs(view.portals or {}) do
    if key == dest then
      return true
    end
  end
  return false
end

local function portalMap(dest)
  for _, portal in ipairs(Config.PORTALS) do
    if portal.key == dest then
      return portal.mapID
    end
  end
  return nil
end

local function changed(e, ride)
  e:emit("RIDE_CHANGED", ride)
end

-- Requesting --------------------------------------------------------------------------

-- Resends the REQUEST each RETRY_TIMEOUT that passes without an answer, up to
-- MAX_RESENDS times; after that the ride is cancelled.
local function awaitAnswer(e, ride, fields, resent)
  e.clock:after(Config.RETRY_TIMEOUT, function()
    if e.stopped or e.rides[ride.key] ~= ride or ride.state ~= "requested" then
      return
    end
    e:safely("request retry", function()
      if resent < MAX_RESENDS then
        e:send("REQUEST", fields, "WHISPER", ride.driver)
        awaitAnswer(e, ride, fields, resent + 1)
      else
        Ride.apply(ride, "CANCEL", e.clock:now())
        changed(e, ride)
      end
    end)
  end)
end

-- Asks the stand on my board for a ride, offering `offer` copper (default 0);
-- a portal ride names its destination, one of the stand's portals. Returns the
-- ride, or nil and "disabled", "dead", "unknown_stand", "bad_offer",
-- "bad_dest" or "pending" (a ride on this stand is under way).
Engine.requestRide = Engine.action(function(e, standId, offer, dest)
  local view = type(standId) == "string" and Board.get(e.board, standId) or nil
  if view == nil then
    return nil, "unknown_stand"
  end
  offer = offer == nil and 0 or offer
  if not (finite(offer) and offer >= 0 and offer == math.floor(offer)) then
    return nil, "bad_offer"
  end
  local kind = view.kind == "mage" and "portal" or "summon"
  if kind == "portal" then
    if not offers(view, dest) then
      return nil, "bad_dest"
    end
  else
    dest = nil
  end
  local key = keyFor(e, standId)
  local old = e.rides[key]
  if old ~= nil and not Ride.isFinal(old) then
    return nil, "pending"
  end
  local ride = Ride.new{
    kind = kind, driver = Names.normalize(view.owner), traveler = Names.normalize(e.me), standId = standId,
    offer = offer, dest = dest, now = e.clock:now(),
  }
  ride.key = key
  ride.stand = Util.copy(view)
  e.rides[key] = ride
  local fields = { standId = standId, offer = offer, level = e.game:level(), dest = dest }
  e:send("REQUEST", fields, "WHISPER", view.owner)
  awaitAnswer(e, ride, fields, 0)
  changed(e, ride)
  return ride
end)

-- The driver is in my group: the ride is under way. A summon ride announces
-- itself (RIDE_START) and goes into my own witness.
local function joined(e, ride, now)
  Ride.apply(ride, "JOINED", now)
  if ride.kind == "summon" then
    e:send("RIDE_START", { rideId = ride.rideId, warlock = ride.driver }, "CHANNEL")
    e.witness:rideStarted(ride.rideId, e.me, ride.driver, now, e.me)
  end
end

-- The driver accepted, with a ride id naming the two of us. A player already
-- in another group is told to leave it, or the invite can't reach them.
Engine.handlers.ACCEPT = function(e, msg, sender)
  local ride = e.rides[keyFor(e, msg.standId)]
  if not isMine(e, ride) or ride.state ~= "requested" or not Names.same(ride.driver, sender) then
    return
  end
  local driver, traveler = Ride.parseId(msg.rideId)
  if not (Names.same(driver, sender) and Names.same(traveler, e.me)) then
    return
  end
  local now = e.clock:now()
  Ride.apply(ride, "ACCEPT", now, { rideId = msg.rideId })
  if e:inGroup(ride.driver) then
    joined(e, ride, now)
  elseif e.game:groupSize() > 0 then
    e:status("STATUS_LEAVE_GROUP")
  end
  changed(e, ride)
end

-- The driver said no: to the request, or to an accepted ride (the invite was
-- never taken).
Engine.handlers.DECLINE = function(e, msg, sender)
  local ride = e.rides[keyFor(e, msg.standId)]
  if not isMine(e, ride) or not Names.same(ride.driver, sender) then
    return
  end
  local event = (ride.state == "requested" and "DECLINE") or (ride.state == "accepted" and "CANCEL") or nil
  if event and Ride.apply(ride, event, e.clock:now()) then
    changed(e, ride)
  end
end

-- Group changes: joining the driver's group starts the ride; the driver
-- leaving it before I arrived cancels it (spec §6.5).
local AWAITING = { grouped = true, summoning = true, portal = true }

Engine.gameHandlers.GROUP_CHANGED = function(e)
  local now = e.clock:now()
  for _, ride in pairs(e.rides) do
    if isMine(e, ride) then
      local here = e:inGroup(ride.driver)
      if ride.state == "accepted" and here then
        joined(e, ride, now)
        changed(e, ride)
      elseif AWAITING[ride.state] and not here then
        Ride.apply(ride, "CANCEL", now)
        changed(e, ride)
      end
    end
  end
end

-- The Summon Guard ----------------------------------------------------------------------

-- How far a ride has come before a summon; the furthest one with this driver
-- is the one the summon is for.
local BEFORE_SUMMON = { requested = 1, accepted = 2, grouped = 3, summoning = 4 }

local function summonRide(e, summoner)
  local best
  for _, ride in pairs(e.rides) do
    local rank = BEFORE_SUMMON[ride.state]
    if rank and ride.kind == "summon" and isMine(e, ride) and Names.same(ride.driver, summoner) then
      local bestRank = best and BEFORE_SUMMON[best.state]
      if best == nil or rank > bestRank or (rank == bestRank and ride.times.requested > best.times.requested) then
        best = ride
      end
    end
  end
  return best
end

-- Whether a group member counts as the stand's crew: anyone within CREW_YARDS
-- of the stand, or whom the game can't place (an unknown counts against a
-- summon, never for it). Someone fighting in another zone is no danger here.
local function nearStand(game, unit, stand)
  local wx, wy, mapID = game:unitPos(unit)
  if not (finite(wx) and finite(wy)) or mapID == nil then
    return true
  end
  return mapID == stand.mapID and finite(stand.wx) and finite(stand.wy)
    and Util.distance(wx, wy, stand.wx, stand.wy) <= CREW_YARDS
end

-- The names of the group members in combat at the stand: the agreed warlock
-- wherever they are, and everyone else near the stand. A member whose combat
-- state is unknown counts as in combat.
local function crewInCombat(e, stand, driver)
  local game, out = e.game, {}
  for _, name in ipairs(game:groupNames() or {}) do
    local unit = not Names.same(name, e.me) and game:unitFor(name) or nil
    if unit ~= nil and (Names.same(name, driver) or nearStand(game, unit, stand))
      and game:unitInCombat(unit) ~= false then
      out[#out + 1] = name
    end
  end
  return out
end

-- True when the stand may not be where I agreed: it left the board, it moved
-- after my request was accepted (the board's changedAt), or its place differs
-- from the copy taken when I asked.
local function standMoved(e, ride)
  local view = Board.get(e.board, ride.standId)
  if view == nil then
    return true
  end
  local since = ride.times.accepted or ride.times.requested
  if not (finite(view.changedAt) and finite(since)) or view.changedAt > since then
    return true
  end
  for _, field in ipairs(PLACE_FIELDS) do
    if view[field] ~= ride.stand[field] then
      return true
    end
  end
  return false
end

-- The guard's facts, from my own client only (SummonGuard.evaluate).
local function guardFacts(e, summon, ride)
  local game = e.game
  local f = {
    hasRide = ride ~= nil,
    summoner = summon and summon.summoner or nil,
    areaName = summon and summon.areaName or nil,
  }
  if ride == nil then
    return f
  end
  local stand = standOf(e, ride)
  f.agreedWarlock = ride.driver
  f.standZone, f.standSubzone, f.standMapID = stand.zone, stand.subzone, stand.mapID
  f.standZoneLocal = stand.mapID ~= nil and game:mapName(stand.mapID) or nil
  f.warlockInGroup = e:inGroup(ride.driver)
  if f.warlockInGroup then
    local wx, wy, mapID = game:unitPos(game:unitFor(ride.driver))
    f.warlockMapID = mapID
    if finite(wx) and finite(wy) and finite(stand.wx) and finite(stand.wy) then
      f.warlockDistance = Util.distance(wx, wy, stand.wx, stand.wy)
    end
  end
  f.crewInCombat = crewInCombat(e, stand, ride.driver)
  if stand.mapID ~= nil then
    f.zoneMin = game:zoneLevels(stand.mapID) -- the zone's lowest level
  end
  f.playerLevel = game:level()
  f.standChanged = standMoved(e, ride)
  local trust = e:summary(ride.driver, "trust")
  f.trustScore = trust.score
  f.trustIsNew = trust.isNew ~= false
  return f
end

-- A summon is offered: the guard compares it with my ride from that warlock,
-- if I have one. It never accepts anything.
Engine.gameHandlers.SUMMON_OFFERED = function(e)
  local summon = e.game:summonFacts()
  if type(summon) ~= "table" then
    summon = nil
  end
  local ride = summon and summonRide(e, summon.summoner) or nil
  local verdict = SummonGuard.evaluate(guardFacts(e, summon, ride))
  if ride ~= nil and ride.state == "grouped" then
    Ride.apply(ride, "SUMMON_OFFERED", e.clock:now())
    changed(e, ride)
  end
  e:emit("GUARD_VERDICT", verdict, ride)
end

-- Declines the summon on screen (the guard panel's button). Always allowed:
-- turning a summon down is never refused.
function Engine:cancelSummon()
  self.game:cancelSummon()
  return true
end

-- The summon went away without bringing me: wait for another, once.
Engine.gameHandlers.SUMMON_GONE = function(e)
  for _, ride in pairs(e.rides) do
    if isMine(e, ride) and ride.state == "summoning" then
      Ride.apply(ride, "SUMMON_FAILED", e.clock:now())
      changed(e, ride)
    end
  end
end

-- Portals ----------------------------------------------------------------------------------

-- My mage opened the portal to my destination.
Engine.handlers.PORTAL_UP = function(e, msg, sender)
  for _, ride in pairs(e.rides) do
    if isMine(e, ride) and ride.kind == "portal" and ride.state == "grouped" and ride.dest == msg.dest
      and Names.same(ride.driver, sender) then
      Ride.apply(ride, "PORTAL_UP", e.clock:now())
      changed(e, ride)
      e:emit("PORTAL_UP", msg.dest)
    end
  end
end

-- Arrival ------------------------------------------------------------------------------------

-- Whether I have arrived at where `loc` puts me. A summon ride arrives within
-- GUARD_YARDS of the stand on its map, once a summon was offered (the popup's
-- SUMMON_GONE may come before the landing is seen, so a ride it sent back to
-- grouped still counts). A portal ride arrives on its destination's map.
local function arrivedAt(e, ride, loc)
  if ride.kind == "summon" then
    if not (ride.state == "summoning" or (ride.state == "grouped" and ride.times.summoning ~= nil)) then
      return false
    end
    local stand = standOf(e, ride)
    return loc.mapID ~= nil and loc.mapID == stand.mapID
      and finite(loc.wx) and finite(loc.wy) and finite(stand.wx) and finite(stand.wy)
      and Util.distance(loc.wx, loc.wy, stand.wx, stand.wy) <= Config.GUARD_YARDS
  end
  local mapID = portalMap(ride.dest)
  return ride.state == "portal" and mapID ~= nil and loc.mapID == mapID
end

-- I arrived: the ride says so, ARRIVED goes out (it opens the death window on
-- every client that heard the start), and my own witness and receipts get it.
local function arrive(e, ride)
  local now = e.clock:now()
  if ride.state == "grouped" then
    Ride.apply(ride, "SUMMON_OFFERED", now)
  end
  Ride.apply(ride, "ARRIVED", now)
  e:send("ARRIVED", { rideId = ride.rideId, warlock = ride.driver }, "CHANNEL")
  e.witness:arrived(ride.rideId, e.me, now, e.me)
  if Ratings.addReceipt(e.db, ride.driver, ride.rideId, now, now) then
    e.dirty = true
  end
  changed(e, ride)
  e:emit("ARRIVED", ride)
end

Engine.gameHandlers.MOVED = function(e)
  local loc = e.game:location()
  if type(loc) ~= "table" then
    return
  end
  for _, ride in pairs(e.rides) do
    if isMine(e, ride) and arrivedAt(e, ride, loc) then
      arrive(e, ride)
    end
  end
end

-- After the ride ------------------------------------------------------------------------------

-- Rates the ride (summon rides only) and opens the trade for a tip. Every
-- check comes first, so nothing happens unless all of it can. stars: 1 to 5,
-- or nil for no rating; tip: copper, or nil for no tip. Returns true and
-- whether the tip could be put in the trade window (nil without a tip), or
-- nil and "unknown_ride", "not_arrived", "no_rating_for_portals",
-- "bad_stars", "zero" / "too_much" (Money.validateTip), "no_trade" or a
-- Ratings reason.
Engine.submitArrival = Engine.action(function(e, rideId, stars, tip)
  local ride = rideById(e, rideId)
  if ride == nil then
    return nil, "unknown_ride"
  end
  if ride.state ~= "arrived" and ride.state ~= "done" then
    return nil, "not_arrived"
  end
  local now = e.clock:now()
  local rating
  if stars ~= nil then
    if ride.kind ~= "summon" then
      return nil, "no_rating_for_portals"
    end
    if not (finite(stars) and stars == math.floor(stars) and stars >= 1 and stars <= 5) then
      return nil, "bad_stars"
    end
    rating = {
      kind = "trust", rater = Names.normalize(e.me), target = ride.driver, stars = stars,
      id = ride.rideId, ts = math.floor(now),
    }
  end
  if tip ~= nil then
    local ok, why = Money.validateTip(tip, e.game:money())
    if not ok then
      return nil, why
    end
  end
  if rating ~= nil then
    local ok, why = Ratings.give(e.db, rating, now)
    if not ok then
      return nil, why
    end
    e.dirty = true
    e:send("RATING", rating, "CHANNEL")
  end
  if tip == nil then
    return true
  end
  if not e.game:openTrade(ride.driver) then
    return nil, "no_trade"
  end
  return true, e.game:trySetTradeMoney(tip) == true
end)

-- The latest of my arrived rides with this driver.
local function arrivedWith(e, driver)
  local best
  for _, ride in pairs(e.rides) do
    if ride.state == "arrived" and isMine(e, ride) and Names.same(ride.driver, driver)
      and (best == nil or ride.times.arrived > best.times.arrived) then
      best = ride
    end
  end
  return best
end

-- A finished trade with my driver after arriving: what left my bags is the
-- tip, reported to the group as TIP. The ride is done.
Engine.gameHandlers.TRADE_DONE = function(e, partner, gave)
  if not (finite(gave) and gave > 0) then
    return
  end
  local ride = arrivedWith(e, partner)
  if ride == nil then
    return
  end
  e:send("TIP", { rideId = ride.rideId, amount = gave }, e:groupDist())
  Ride.apply(ride, "FINISHED", e.clock:now())
  changed(e, ride)
end

-- Leaves the group (the arrival window's button). Always allowed.
function Engine:leaveGroup()
  self.game:leaveGroup()
  return true
end

-- The arrival window's "Stay and click": signs up to the same stand at the
-- share it offers. Returns what applyClicker returns, or nil and
-- "unknown_ride" for a ride of mine that hasn't arrived.
Engine.stayAndClick = Engine.action(function(e, rideId)
  local ride = rideById(e, rideId)
  if ride == nil or (ride.state ~= "arrived" and ride.state ~= "done") then
    return nil, "unknown_ride"
  end
  return e:applyClicker(ride.standId, standOf(e, ride).clickerPct)
end)
