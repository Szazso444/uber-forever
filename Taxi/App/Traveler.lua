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
-- A summon's landing (R43): a move within this many seconds after its popup
-- went away is still its landing, and a move of more than JUMP_YARDS from
-- where it found me (or onto another map) is one.
local LANDING_WINDOW = 30
local JUMP_YARDS = 100

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
  return Board.get(e.board, ride.standId, e.clock:now()) or ride.stand
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
  local view = type(standId) == "string" and Board.get(e.board, standId, e.clock:now()) or nil
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

-- How far a ride has come before a summon. A summon is judged against my
-- furthest ride with its summoner; failing that, against my furthest ride
-- under way (accepted or later), whose driver it then doesn't match: a
-- stranger's summon during a booked ride is RED, not "not a Taxi ride" (R45).
local BEFORE_SUMMON = { requested = 1, accepted = 2, grouped = 3, summoning = 4 }
local UNDER_WAY = 2

local function further(best, ride)
  if best == nil then
    return ride
  end
  local rank, bestRank = BEFORE_SUMMON[ride.state], BEFORE_SUMMON[best.state]
  if rank > bestRank or (rank == bestRank and ride.times.requested > best.times.requested) then
    return ride
  end
  return best
end

local function summonRide(e, summoner)
  local own, other
  for _, ride in pairs(e.rides) do
    local rank = BEFORE_SUMMON[ride.state]
    if rank and ride.kind == "summon" and isMine(e, ride) then
      if Names.same(ride.driver, summoner) then
        own = further(own, ride)
      elseif rank >= UNDER_WAY then
        other = further(other, ride)
      end
    end
  end
  return own or other
end

-- Calls fn(...) in a pcall and returns its first result; an error is logged
-- as Engine:safely logs it, and gives nil.
local function try(e, what, fn, ...)
  local ok, result = pcall(fn, ...)
  if not ok then
    pcall(e.log, tostring(e.me) .. ": " .. what .. ": " .. tostring(result))
    return nil
  end
  return result
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

-- The names of the group members in combat at the stand. The agreed warlock
-- is looked up directly, wherever they are, so a roster that leaves them out
-- or spells them otherwise can't hide them; anyone else counts when near the
-- stand. Whatever can't be told counts as fighting: a combat state the game
-- doesn't give, or a roster name with no unit (listed by that name). No
-- roster at all gives nil, which the guard treats as unsafe.
local function crewInCombat(e, stand, driver)
  local game = e.game
  local roster = game:groupNames()
  if type(roster) ~= "table" then
    return nil
  end
  local out = {}
  local unit = game:unitFor(driver)
  if unit == nil or game:unitInCombat(unit) ~= false then
    out[1] = driver
  end
  for _, name in ipairs(roster) do
    if not Names.same(name, e.me) and not Names.same(name, driver) then
      unit = game:unitFor(name)
      if unit == nil or (nearStand(game, unit, stand) and game:unitInCombat(unit) ~= false) then
        out[#out + 1] = name
      end
    end
  end
  return out
end

-- True when the stand may not be where I agreed: it left the board, it moved
-- after my request was accepted (the board's changedAt), or its place differs
-- from the copy taken when I asked.
local function standMoved(e, ride)
  local view = Board.get(e.board, ride.standId, e.clock:now())
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
  -- A stand that moved is judged by the place I asked for (R46). Otherwise
  -- the live view, which then has that very place anyway.
  local moved = standMoved(e, ride)
  local stand = moved and ride.stand or standOf(e, ride)
  -- The zone the message named, and my own name for the stand's map: the
  -- guard trusts the wire text only when my client has no name for it (R65).
  f.agreedWarlock = ride.driver
  f.standZone, f.standSubzone, f.standMapID = stand.wireZone or stand.zone, stand.subzone, stand.mapID
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
  f.standChanged = moved
  local trust = e:summary(ride.driver, "trust")
  f.trustScore = trust.score
  f.trustIsNew = trust.isNew ~= false
  return f
end

-- The facts when gathering them failed: everything unknown (crewInCombat
-- too), so the guard can only say RED, or YELLOW for no Taxi ride at all.
local function unknownFacts(summon, ride)
  return {
    hasRide = ride ~= nil,
    summoner = summon and summon.summoner or nil,
    areaName = summon and summon.areaName or nil,
    agreedWarlock = ride and ride.driver or nil,
  }
end

-- A summon from the ride's own warlock: the ride is summoning, and where the
-- summon found me is kept so that its landing can be told (R43). A summon from
-- anyone else takes the warlock's place on screen, so no landing is expected.
local function awaitLanding(e, ride, summon)
  if summon == nil or not Names.same(summon.summoner, ride.driver) then
    ride.summon = nil
    return
  end
  if ride.state == "grouped" then
    Ride.apply(ride, "SUMMON_OFFERED", e.clock:now())
    changed(e, ride)
  end
  if ride.state == "summoning" then
    local loc = try(e, "location", e.game.location, e.game)
    loc = type(loc) == "table" and loc or {}
    ride.summon = { mapID = loc.mapID, wx = loc.wx, wy = loc.wy }
  end
end

-- The summon on screen, as the game tells it: its facts (nil when they can't
-- be read), and whether the game said plainly that there is none (`gone`).
local function summonNow(e)
  local game = e.game
  local ok, summon = pcall(game.summonFacts, game)
  if not ok then
    pcall(e.log, tostring(e.me) .. ": summon facts: " .. tostring(summon))
    return nil, false
  end
  if summon == nil then
    return nil, true
  end
  return type(summon) == "table" and summon or nil, false
end

-- The guard's verdict on `summon` against `ride`. Gathering the facts can't
-- stop the verdict: if it fails, the guard gets unknowns.
local function judge(e, summon, ride)
  local facts = try(e, "guard facts", guardFacts, e, summon, ride) or unknownFacts(summon, ride)
  return SummonGuard.evaluate(facts)
end

-- While a summon is on screen, e.pendingSummon = { ride }: the ride it was
-- judged against. What the guard checked can change while the popup is up (the
-- crew starts a fight, the warlock walks off), so it is judged again on every
-- COMBAT_CHANGED, GROUP_CHANGED and MOVED, and every RECHECK_SECONDS, and the
-- new verdict goes out. Facts are gathered afresh each time; the ride stays the
-- one the summon was offered for (a ride cancelled meanwhile is still the one
-- to compare with: its warlock is no longer in my group, which is RED). It
-- stops when the popup goes (SUMMON_GONE, or the game names no summon) or the
-- summon lands me.
local RECHECK_SECONDS = 1

local function recheck(e)
  local pending = e.pendingSummon
  if pending == nil then
    return
  end
  local summon, gone = summonNow(e)
  if gone then
    e.pendingSummon = nil
    return
  end
  e:emit("GUARD_VERDICT", judge(e, summon, pending.ride), pending.ride)
end

local function recheckEverySecond(e, pending)
  e.clock:after(RECHECK_SECONDS, function()
    if e.stopped or e.pendingSummon ~= pending then
      return
    end
    e:safely("guard recheck", recheck, e)
    recheckEverySecond(e, pending)
  end)
end

-- A summon is offered: the guard compares it with my ride (see summonRide),
-- and keeps comparing while it is on screen (see recheck). It never accepts
-- anything.
Engine.gameHandlers.SUMMON_OFFERED = function(e)
  local summon = summonNow(e)
  local ride = summonRide(e, summon and summon.summoner)
  local verdict = judge(e, summon, ride)
  if ride ~= nil then
    awaitLanding(e, ride, summon)
  end
  local pending = { ride = ride }
  e.pendingSummon = pending
  recheckEverySecond(e, pending)
  e:emit("GUARD_VERDICT", verdict, ride)
end

Engine.gameHandlers.COMBAT_CHANGED = recheck
Engine.gameHandlers.GROUP_CHANGED = recheck

-- Declines the summon on screen (the guard panel's button). Always allowed:
-- turning a summon down is never refused.
function Engine:cancelSummon()
  for _, ride in pairs(self.rides) do
    if isMine(self, ride) and ride.state == "summoning" and ride.summon ~= nil then
      ride.summon.declined = true
    end
  end
  self.game:cancelSummon()
  return true
end

local function summonFailed(e, ride)
  ride.summon = nil
  Ride.apply(ride, "SUMMON_FAILED", e.clock:now())
  changed(e, ride)
end

-- The summon popup went away. The UI hears it first (SUMMON_GONE, ride or no
-- ride: the guard panel closes on it). Declined on the guard panel, or not the
-- warlock's, the summon failed: wait for another, once. Otherwise it may have
-- been accepted, and the landing may be seen only a moment later, so the
-- failure waits LANDING_WINDOW seconds (R43).
Engine.gameHandlers.SUMMON_GONE = function(e)
  e.pendingSummon = nil
  e:emit("SUMMON_GONE")
  for _, ride in pairs(e.rides) do
    local summon = ride.summon
    if isMine(e, ride) and ride.state == "summoning" then
      if summon == nil or summon.declined then
        summonFailed(e, ride)
      elseif summon.goneAt == nil then
        summon.goneAt = e.clock:now()
        e.clock:after(LANDING_WINDOW, function()
          if not e.stopped and ride.summon == summon and ride.state == "summoning" then
            e:safely("summon gone", summonFailed, e, ride)
          end
        end)
      end
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

-- Whether a move looks like the landing of my ride's own summon (R43): while
-- the summon is on screen, or within LANDING_WINDOW after it went away (after
-- that SUMMON_GONE's timer has failed the summon), I changed map or am more
-- than JUMP_YARDS from where it found me. Wherever I landed: a summon to the
-- wrong place is still the warlock's. A summon I declined never lands. It is
-- the landing only once the popup is gone (MOVED, M8).
local function landed(ride, loc)
  local from = ride.summon
  if ride.state ~= "summoning" or from == nil or from.declined then
    return false
  end
  if loc.mapID ~= nil and from.mapID ~= nil and loc.mapID ~= from.mapID then
    return true
  end
  return finite(loc.wx) and finite(loc.wy) and finite(from.wx) and finite(from.wy)
    and Util.distance(from.wx, from.wy, loc.wx, loc.wy) > JUMP_YARDS
end

-- Whether I have arrived where `loc` puts me: a summon ride when its summon
-- landed me, a portal ride on its destination's map.
local function arrivedAt(ride, loc)
  if ride.kind == "summon" then
    return landed(ride, loc)
  end
  local mapID = portalMap(ride.dest)
  return ride.state == "portal" and mapID ~= nil and loc.mapID == mapID
end

-- Within GUARD_YARDS of the stand, on its map.
local function atStand(stand, loc)
  return loc.mapID ~= nil and loc.mapID == stand.mapID
    and finite(loc.wx) and finite(loc.wy) and finite(stand.wx) and finite(stand.wy)
    and Util.distance(loc.wx, loc.wy, stand.wx, stand.wy) <= Config.GUARD_YARDS
end

-- I arrived: the ride says so, ARRIVED goes out (it opens the death window on
-- every client that heard the start), and my own witness and receipts get it.
-- A summon that landed me away from the place I asked for is wrongPlace. The
-- driver gets ARRIVED a second time by whisper (R50): a lost channel message
-- would otherwise leave his ride unfinished and his ride log unsent. Everyone
-- who hears both handles the repeat as no news.
local function arrive(e, ride, loc)
  local now = e.clock:now()
  Ride.apply(ride, "ARRIVED", now)
  if ride.kind == "summon" then
    ride.summon = nil
    ride.wrongPlace = not atStand(ride.stand, loc)
    e.pendingSummon = nil -- the summon is over: no more verdicts on it
  end
  local fields = { rideId = ride.rideId, warlock = ride.driver }
  e:send("ARRIVED", fields, "CHANNEL")
  e:send("ARRIVED", fields, "WHISPER", ride.driver)
  e.witness:arrived(ride.rideId, e.me, now, e.me)
  if Ratings.addReceipt(e.db, ride.driver, ride.rideId, now, now) then
    e.dirty = true
  end
  changed(e, ride)
  e:emit("ARRIVED", ride)
end

-- Whether the summon that found me is still on screen (M8): its popup's end
-- was not seen and the game still names a summoner. A move while it is up is
-- my own (a flight path, a hearthstone), never its landing.
local function stillOffered(e, summon)
  if summon.goneAt ~= nil then
    return false
  end
  local ok, facts = pcall(e.game.summonFacts, e.game)
  return ok and type(facts) == "table"
end

Engine.gameHandlers.MOVED = function(e)
  local loc = e.game:location()
  if type(loc) ~= "table" then
    return
  end
  for _, ride in pairs(e.rides) do
    if isMine(e, ride) and arrivedAt(ride, loc) then
      if ride.kind == "summon" and stillOffered(e, ride.summon) then
        -- Not the summon's landing. Where it finds me now is where it would
        -- land me from, so a later move is judged from here.
        local from = ride.summon
        from.mapID, from.wx, from.wy = loc.mapID, loc.wx, loc.wy
      else
        arrive(e, ride, loc)
      end
    end
  end
end

-- A move of mine while a summon is still on screen changes what the guard
-- sees (registered after the landing check above, which may end the summon).
Engine.gameHandlers.MOVED = recheck

-- After the ride ------------------------------------------------------------------------------

-- Rates the ride (summon rides only) and opens the trade for a tip. Every
-- check comes first, so nothing happens unless all of it can. stars: 1 to 5,
-- or nil for no rating; tip: copper, or nil for no tip. Returns true, or nil
-- and "unknown_ride", "not_arrived", "no_rating_for_portals", "bad_stars",
-- "zero" / "too_much" (Money.validateTip), "no_trade" or a Ratings reason.
-- The money is not put in the trade here: the window that opens may not be the
-- driver's yet (another player's trade can be open), so only the arrival
-- window's Put button does that, from the player's own click (putTipInTrade,
-- R64).
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
  return true
end)

-- Whether a trade window with this ride's driver is open now: the arrival
-- window's Put button is enabled only then.
function Engine:tradeOpenWithDriver(rideId)
  local ride = rideById(self, rideId)
  return ride ~= nil and self.game:tradeOpenWith(ride.driver) == true
end

-- Tries to put a tip in the open trade window with the driver, for the Put
-- button (the player's own click, R64). Returns true and whether the game could
-- put it there, or nil and "unknown_ride", "not_arrived", "zero" / "too_much"
-- (Money.validateTip) or "no_window" (no trade window with the driver is open).
Engine.putTipInTrade = Engine.action(function(e, rideId, tip)
  local ride = rideById(e, rideId)
  if ride == nil then
    return nil, "unknown_ride"
  end
  if ride.state ~= "arrived" and ride.state ~= "done" then
    return nil, "not_arrived"
  end
  local ok, why = Money.validateTip(tip, e.game:money())
  if not ok then
    return nil, why
  end
  if not e.game:tradeOpenWith(ride.driver) then
    return nil, "no_window"
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
