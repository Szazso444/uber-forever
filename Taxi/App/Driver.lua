local _, ns = ...

-- Driver: a warlock's summon stand or a mage's portal stand, as methods and
-- handlers on the Engine. The driver opens the stand and keeps it on everyone's
-- board with a heartbeat, takes travelers' requests and invites them, keeps the
-- queue the "Summon next" button works through, signs clickers up at an agreed
-- share, and keeps the stand's ledger so that the clickers can be paid.
--
-- A request is filed under traveler .. "#" .. standId, the key the traveler
-- uses for its own copy of the ride; the ride id is made here, on accept. The
-- Engine drops the player's own messages, so anything sent here that this
-- client's own records need (the RIDE_LOG, the TIP_ACK) is recorded directly.
--
-- What the stand keeps besides Stand's own fields:
--   queue  accepted rides, in the order they were accepted
--   talks  clicker name -> the Negotiation still open with them
--   seen   clicker name -> true once they were seen in my group
--
-- Pure Lua: no WoW API (this file is also loaded in-game for /taxi sim).
local Engine, Config, Names = ns.Engine, ns.Config, ns.Names
local Stand, Ride, Negotiation, Ledger, Ratings = ns.Stand, ns.Ride, ns.Negotiation, ns.Ledger, ns.Ratings

local LOCK_LEVEL = 20 -- Ritual of Summoning is learned at 20
local INVITE_TIMEOUT = 60 -- seconds an accepted traveler has to join the group
local RAID_TIMEOUT = 5 -- seconds convertAndAccept waits for the group to become a raid (R53)
local MAX_SEATS = 37 -- a raid of 40, less the warlock and two clickers
local MAX_OFFERED_PCT = 50 -- two clickers at this share leave the owner nothing
local MAX_CLICKERS = 2 -- as Stand.addClicker allows

-- True only for a real, finite number (not nil, not NaN, not +-infinity).
local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function wholeIn(x, lo, hi)
  return finite(x) and x == math.floor(x) and x >= lo and x <= hi
end

-- One of the stand's own tables (see the top of the file), made on first use.
local function part(stand, field)
  local t = stand[field]
  if t == nil then
    t = {}
    stand[field] = t
  end
  return t
end

local function isClicker(stand, name)
  for clicker in pairs(stand.clickers) do
    if Names.same(clicker, name) then
      return true
    end
  end
  return false
end

local function isSeated(stand, name)
  for _, traveler in ipairs(stand.travelers) do
    if Names.same(traveler, name) then
      return true
    end
  end
  return false
end

local function offers(stand, dest)
  for _, key in ipairs(stand.portals or {}) do
    if key == dest then
      return true
    end
  end
  return false
end

-- My ride (as its driver) with this ride id, or nil.
local function rideById(e, rideId)
  if type(rideId) ~= "string" then
    return nil
  end
  for _, ride in pairs(e.rides) do
    if ride.rideId == rideId and Names.same(ride.driver, e.me) then
      return ride
    end
  end
  return nil
end

-- The ledger of a lock stand, made on first use.
local function ledgerOf(e, stand)
  local l = e.ledgers[stand.standId]
  if l == nil then
    l = Ledger.new(stand.standId, e.me)
    e.ledgers[stand.standId] = l
  end
  return l
end

-- Stand.status has to be asked after every change for "paused" to be told
-- apart from "recruiting"; the UI hears STAND_CHANGED.
local function standChanged(e, stand)
  Stand.status(stand)
  e:emit("STAND_CHANGED", stand)
end

-- The stand's flags: combat while I or a clicker in my group is in combat, and
-- (on a heartbeat) noShards when a warlock has no soul shard left.
local function refreshFlags(e, stand, checkShards)
  local before = Stand.status(stand)
  local game = e.game
  local fighting = game:unitInCombat("player") == true
  for clicker in pairs(stand.clickers) do
    local unit = game:unitFor(clicker)
    if unit ~= nil and game:unitInCombat(unit) == true then
      fighting = true
    end
  end
  stand.flags.combat = fighting
  if checkShards and stand.kind == "lock" then
    local shards = game:soulShards()
    stand.flags.noShards = finite(shards) and shards < 1
  end
  if Stand.status(stand) ~= before then
    e:emit("STAND_CHANGED", stand)
  end
end

-- Every HEARTBEAT the open stand checks its flags and goes out again.
local function heartbeat(e, stand)
  e.clock:after(Config.HEARTBEAT, function()
    if e.stopped or e.stand ~= stand then
      return
    end
    e:safely("heartbeat", function()
      refreshFlags(e, stand, true)
      e:send("STAND", Stand.toFields(stand), "CHANNEL")
    end)
    heartbeat(e, stand)
  end)
end

-- Opening and closing -------------------------------------------------------------

-- o: kind ("lock" or "mage"), seats (default DEFAULT_SEATS, 1 to 37),
-- clickerPct (the share offered to each clicker, default
-- DEFAULT_CLICKER_PCT, 1 to 50), note. Returns the stand, or nil and why not:
-- "disabled", "dead", "instance", "already_open", "bad_kind", "not_warlock",
-- "low_level" (a warlock below level 20), "no_portals" (no known portal
-- spell), "bad_seats", "bad_pct", "bad_note" (not text, or too long to send)
-- or "no_position" (the game can't say where I am).
Engine.openStand = Engine.action(function(e, o)
  o = type(o) == "table" and o or {}
  local game = e.game
  local loc = game:location()
  if type(loc) == "table" and loc.inInstance == true then
    return nil, "instance"
  end
  if e.stand ~= nil then
    return nil, "already_open"
  end
  local portals = {}
  if o.kind == "lock" then
    if game:class() ~= "WARLOCK" then
      return nil, "not_warlock"
    end
    if not (finite(game:level()) and game:level() >= LOCK_LEVEL) then
      return nil, "low_level"
    end
  elseif o.kind == "mage" then
    for _, portal in ipairs(game:knownPortals() or {}) do
      portals[#portals + 1] = portal.key
    end
    if #portals == 0 then
      return nil, "no_portals"
    end
  else
    return nil, "bad_kind"
  end
  local seats = o.seats == nil and Config.DEFAULT_SEATS or o.seats
  if not wholeIn(seats, 1, MAX_SEATS) then
    return nil, "bad_seats"
  end
  local pct = o.clickerPct == nil and Config.DEFAULT_CLICKER_PCT or o.clickerPct
  if not wholeIn(pct, 1, MAX_OFFERED_PCT) then
    return nil, "bad_pct"
  end
  if o.note ~= nil and type(o.note) ~= "string" then
    return nil, "bad_note"
  end
  if type(loc) ~= "table" or loc.mapID == nil or not (finite(loc.wx) and finite(loc.wy)) or loc.zone == nil then
    return nil, "no_position"
  end

  local now = e.clock:now()
  local stand = Stand.new{
    standId = Names.normalize(e.me) .. "@" .. math.floor(now), -- R41: the id names its owner
    owner = Names.normalize(e.me), kind = o.kind, faction = game:faction(),
    mapID = loc.mapID, x = loc.x, y = loc.y, wx = loc.wx, wy = loc.wy, zone = loc.zone, subzone = loc.subzone,
    seats = seats, clickerPct = pct, note = o.note, portals = portals, now = now,
  }
  if not ns.Transport.fits("STAND", Stand.toFields(stand)) then
    return nil, "bad_note"
  end
  stand.queue, stand.talks, stand.seen = {}, {}, {}
  e.stand, e.lastStand = stand, stand
  if stand.kind == "lock" then
    ledgerOf(e, stand)
  end
  e.charDb.stand = { seats = seats, clickerPct = pct, note = o.note or "" }
  Stand.status(stand)
  e:send("STAND", Stand.toFields(stand), "CHANNEL")
  heartbeat(e, stand)
  e:emit("STAND_CHANGED", stand)
  return stand
end)

-- The agreed spot stops being true once I walk away from it: more than
-- STAND_MOVE_YARDS, onto another map, or somewhere the game can't place.
Engine.gameHandlers.MOVED = function(e)
  local stand = e.stand
  if stand == nil then
    return
  end
  local loc = e.game:location()
  if type(loc) ~= "table" or loc.mapID ~= stand.mapID or not (finite(loc.wx) and finite(loc.wy))
    or Stand.movedTooFar(stand, loc.wx, loc.wy) then
    e:closeStand()
  end
end

Engine.gameHandlers.COMBAT_CHANGED = function(e)
  if e.stand ~= nil then
    refreshFlags(e, e.stand, false)
  end
end

-- Requests ---------------------------------------------------------------------------

-- A request repeated while its ride is live is not a new request, but it means
-- the traveler heard nothing from me. If I accepted it, my ACCEPT was lost (R49):
-- say it again, the very same one (it names the same ride), and invite him again
-- if he has not joined. The wait for him to join is not started over, so
-- repeating the request can't hold a seat. A request I have not answered yet
-- gets no answer.
local function repeatAnswer(e, stand, ride)
  if ride.rideId == nil then
    return
  end
  e:send("ACCEPT", { rideId = ride.rideId, standId = stand.standId }, "WHISPER", ride.traveler)
  if ride.state == "accepted" and not e:inGroup(ride.traveler) then
    e.game:invite(ride.traveler)
  end
end

-- A traveler asks for a seat. The owner and the stand's own clickers can't
-- ride on it (R19); a request repeated while its ride is live is not filed
-- again (see repeatAnswer).
Engine.handlers.REQUEST = function(e, msg, sender)
  local stand = e.stand
  if stand == nil or msg.standId ~= stand.standId then
    return
  end
  local traveler = Names.normalize(sender)
  if Names.same(traveler, e.me) or isClicker(stand, traveler) then
    return
  end
  local key = traveler .. "#" .. stand.standId
  local old = e.rides[key]
  if old ~= nil and not Ride.isFinal(old) then
    repeatAnswer(e, stand, old)
    return
  end
  local kind, dest = "summon", nil
  if stand.kind == "mage" then
    kind, dest = "portal", msg.dest
    if not offers(stand, dest) then
      return
    end
  end
  local offer = msg.offer
  if not (offer >= 0 and offer == math.floor(offer)) then
    offer = 0 -- only ever shown
  end
  local ride = Ride.new{
    kind = kind, driver = Names.normalize(e.me), traveler = traveler, standId = stand.standId,
    offer = offer, dest = dest, now = e.clock:now(),
  }
  ride.key, ride.level = key, msg.level
  e.rides[key] = ride
  e:emit("REQUEST_RECEIVED", ride)
end

-- The request filed under key for my open stand, still waiting for an answer.
local function waiting(e, key)
  local stand, ride = e.stand, e.rides[key]
  if stand == nil or ride == nil or ride.state ~= "requested" or ride.standId ~= stand.standId
    or not Names.same(ride.driver, e.me) then
    return nil
  end
  return ride, stand
end

-- A seated traveler gives up the seat.
local function unseat(e, ride)
  if e.stand ~= nil and e.stand.standId == ride.standId then
    Stand.removeTraveler(e.stand, ride.traveler)
  end
end

-- An accepted traveler who hasn't joined my group in time.
local function inviteExpired(e, ride)
  if ride.state ~= "accepted" or e.rides[ride.key] ~= ride then
    return
  end
  Ride.apply(ride, "CANCEL", e.clock:now())
  unseat(e, ride)
  e:send("DECLINE", { standId = ride.standId, reason = "invite_failed" }, "WHISPER", ride.traveler)
  e:emit("RIDE_CHANGED", ride)
end

-- Gives an invited traveler INVITE_TIMEOUT seconds to join. A new invite
-- starts the wait over: only the latest wait can give up on the ride.
local function awaitJoin(e, ride)
  local wait = {}
  ride.inviteWait = wait
  e.clock:after(INVITE_TIMEOUT, function()
    if not e.stopped and ride.inviteWait == wait then
      e:safely("invite timeout", inviteExpired, e, ride)
    end
  end)
end

-- Accepts the request filed under key: the ride gets its id, the traveler a
-- seat and an invite, and ACCEPT is whispered. Returns the ride id, or nil and
-- "unknown_ride" (no request waiting under key), "full" (no free seat) or
-- "needs_raid" (the group would pass 5; convertAndAccept does it).
Engine.acceptRequest = Engine.action(function(e, key)
  local ride, stand = waiting(e, key)
  if ride == nil then
    return nil, "unknown_ride"
  end
  if Stand.seatsFree(stand) == 0 then
    return nil, "full"
  end
  if Stand.needsRaid(stand, 1) and not e.game:isRaid() then
    return nil, "needs_raid"
  end
  local now = e.clock:now()
  local rideId = Ride.makeId(Names.normalize(e.me), ride.traveler, now)
  Ride.apply(ride, "ACCEPT", now, { rideId = rideId })
  Stand.addTraveler(stand, ride.traveler)
  local queue = part(stand, "queue")
  queue[#queue + 1] = ride
  e:send("ACCEPT", { rideId = rideId, standId = stand.standId }, "WHISPER", ride.traveler)
  if e:inGroup(ride.traveler) then
    Ride.apply(ride, "JOINED", now)
  else
    e.game:invite(ride.traveler)
    awaitJoin(e, ride)
  end
  e:emit("RIDE_CHANGED", ride)
  return rideId
end)

-- Invites an accepted traveler again (one who had to leave another group
-- first), and starts their INVITE_TIMEOUT over. Returns true, or nil and
-- "unknown_ride" when no ride under key is waiting for its traveler to join.
Engine.reinvite = Engine.action(function(e, key)
  local ride = e.rides[key]
  if ride == nil or ride.state ~= "accepted" or not Names.same(ride.driver, e.me) or e:inGroup(ride.traveler) then
    return nil, "unknown_ride"
  end
  e.game:invite(ride.traveler)
  awaitJoin(e, ride)
  return true
end)

-- The toast's "Convert to raid & invite": the conversion is the player's own
-- click. The game makes the raid on a later roster update, so the request is
-- accepted on the first GROUP_CHANGED that finds a raid (R53); a conversion
-- not seen within RAID_TIMEOUT seconds is given up with STATUS_RAID_FAILED.
-- Returns the ride id when already in a raid, true when the accept waits for
-- the conversion, or nil and "unknown_ride".
Engine.convertAndAccept = Engine.action(function(e, key)
  if waiting(e, key) == nil then
    return nil, "unknown_ride"
  end
  if e.game:isRaid() then
    return e:acceptRequest(key)
  end
  local pending = e.raidPending
  if pending == nil then
    pending = {}
    e.raidPending = pending
    e.clock:after(RAID_TIMEOUT, function()
      if not e.stopped and e.raidPending == pending then
        e.raidPending = nil
        e:safely("raid timeout", e.status, e, "STATUS_RAID_FAILED")
      end
    end)
  end
  local queued = false
  for _, k in ipairs(pending) do
    queued = queued or k == key
  end
  if not queued then
    pending[#pending + 1] = key
  end
  e.game:convertToRaid()
  return true
end)

-- The raid convertAndAccept waited for is there: accept, in click order.
Engine.gameHandlers.GROUP_CHANGED = function(e)
  local pending = e.raidPending
  if pending == nil or not e.game:isRaid() then
    return
  end
  e.raidPending = nil
  for _, key in ipairs(pending) do
    e:acceptRequest(key)
  end
end

-- Turns the request under key down; DECLINE carries the reason. Returns true,
-- or nil and "unknown_ride".
Engine.declineRequest = Engine.action(function(e, key, reason)
  local ride = waiting(e, key)
  if ride == nil then
    return nil, "unknown_ride"
  end
  Ride.apply(ride, "DECLINE", e.clock:now())
  e:send("DECLINE", { standId = ride.standId, reason = type(reason) == "string" and reason or nil }, "WHISPER",
    ride.traveler)
  e:emit("RIDE_CHANGED", ride)
  return true
end)

-- The ride the "Summon next" (or "Open portal") button is for: the first ride
-- in accept order whose traveler is in my group and not yet there. A ride stays
-- first until it arrives or ends. Sends nothing, so the UI can ask on every
-- refresh to aim its secure button (only rides that ended are dropped from the
-- queue). Returns the ride, or nil when nobody is waiting.
function Engine:nextRide()
  local stand = self.stand
  if stand == nil then
    return nil
  end
  local queue = part(stand, "queue")
  for i = #queue, 1, -1 do
    local state = queue[i].state
    if Ride.isFinal(queue[i]) or state == "arrived" then
      table.remove(queue, i)
    end
  end
  for _, ride in ipairs(queue) do
    if ride.state == "grouped" then
      return ride
    end
  end
  return nil
end

-- The traveler nextRide names, for the player's click on that button.
-- PORTAL_UP goes to the group, so the clickers (or a mage's travelers) know to
-- click. Returns the name, or nil when nobody is waiting.
Engine.nextTraveler = Engine.action(function(e)
  local ride = e:nextRide()
  if ride == nil then
    return nil
  end
  e:send("PORTAL_UP", { dest = ride.dest }, e:groupDist())
  return ride.traveler
end)

-- Group changes: an accepted traveler who joined is grouped; a seated
-- traveler who left gives up the seat, and a ride that hadn't arrived is
-- cancelled. A clicker seen in my group who is gone now leaves the stand.
local AWAITING = { grouped = true, summoning = true, portal = true }

-- A clicker leaves the stand: their shift ends in my ledger. When `tell`, the
-- owner sent them away and CLICK_NO tells their addon the shift is over.
local function dropClicker(e, stand, name, tell)
  Stand.removeClicker(stand, name)
  part(stand, "seen")[Names.normalize(name)] = nil
  local l = e.ledgers[stand.standId]
  if l ~= nil then
    Ledger.leave(l, name, e.clock:now())
  end
  if tell then
    e:send("CLICK_NO", { standId = stand.standId }, "WHISPER", name)
  end
  standChanged(e, stand)
end

Engine.gameHandlers.GROUP_CHANGED = function(e)
  local now = e.clock:now()
  for _, ride in pairs(e.rides) do
    if Names.same(ride.driver, e.me) then
      local here = e:inGroup(ride.traveler)
      if ride.state == "accepted" and here then
        Ride.apply(ride, "JOINED", now)
        e:emit("RIDE_CHANGED", ride)
      elseif not here and (AWAITING[ride.state] or ride.state == "arrived" or ride.state == "done") then
        unseat(e, ride)
        if AWAITING[ride.state] then
          Ride.apply(ride, "CANCEL", now)
          e:emit("RIDE_CHANGED", ride)
        end
      end
    end
  end
  local stand = e.stand
  if stand ~= nil then
    local seen = part(stand, "seen")
    for clicker in pairs(stand.clickers) do
      if e:inGroup(clicker) then
        seen[clicker] = true
      elseif seen[clicker] then
        dropClicker(e, stand, clicker)
      end
    end
  end
end

-- Arrival and tips ----------------------------------------------------------------------

-- One of my travelers arrived. A summon ride is logged and the log goes out as
-- RIDE_LOG, the proof that makes the traveler's rating two-sided (portal rides
-- are never rated). A TIP heard before the arrival now counts for the shifts
-- the arrival falls in (R39).
Engine.handlers.ARRIVED = function(e, msg, sender)
  if not Names.same(msg.warlock, e.me) then
    return
  end
  local ride = rideById(e, msg.rideId)
  if ride == nil or not Names.same(ride.traveler, sender) then
    return
  end
  local now = e.clock:now()
  if ride.state == "grouped" then
    Ride.apply(ride, ride.kind == "summon" and "SUMMON_OFFERED" or "PORTAL_UP", now)
  end
  if not Ride.apply(ride, "ARRIVED", now) then
    return
  end
  if ride.kind == "summon" then
    if Ratings.addRideLog(e.db, e.me, ride.rideId, now, ride.traveler, now) then
      e.dirty = true
    end
    e:send("RIDE_LOG", { rideId = ride.rideId, traveler = ride.traveler }, "CHANNEL")
  end
  local l = e.ledgers[ride.standId]
  local tip = l and l.tips[ride.rideId]
  if tip ~= nil and tip.arrivedTs == nil then
    Ledger.tip(l, ride.rideId, tip.amount, now)
  end
  e:emit("RIDE_CHANGED", ride)
end

local function tipAmount(x)
  return finite(x) and x >= 0 and x <= Config.MAX_TIP
end

-- The traveler's report of a tip, taken only from that ride's own traveler
-- (R39); it counts once the warlock's own TIP_ACK agrees.
Engine.handlers.TIP = function(e, msg, sender)
  local ride = rideById(e, msg.rideId)
  if ride == nil or not Names.same(ride.traveler, sender) or not tipAmount(msg.amount) then
    return
  end
  local l = e.ledgers[ride.standId]
  if l ~= nil then
    Ledger.tip(l, ride.rideId, msg.amount, ride.times.arrived)
  end
end

-- The latest ride of this traveler that arrived and hasn't been tipped yet.
local function arrivedRideOf(e, traveler)
  local best
  for _, ride in pairs(e.rides) do
    if ride.state == "arrived" and Names.same(ride.driver, e.me) and Names.same(ride.traveler, traveler)
      and (best == nil or ride.times.arrived > best.times.arrived) then
      best = ride
    end
  end
  return best
end

-- A finished trade: copper I gave a clicker is their pay; copper an arrived
-- traveler gave me is their tip, which I report to the group as TIP_ACK.
Engine.gameHandlers.TRADE_DONE = function(e, partner, gave, got)
  local name = Names.normalize(partner)
  if name == nil or name == "" then
    return
  end
  local stand = e.lastStand
  local l = stand and e.ledgers[stand.standId]
  if l ~= nil and l.shifts[name] ~= nil and finite(gave) and gave > 0 then
    Ledger.received(l, name, gave)
  end
  local ride = finite(got) and got > 0 and arrivedRideOf(e, name)
  if ride then
    e:send("TIP_ACK", { rideId = ride.rideId, amount = got }, e:groupDist())
    local rideLedger = e.ledgers[ride.standId]
    if rideLedger ~= nil then
      Ledger.ack(rideLedger, ride.rideId, got)
    end
    Ride.apply(ride, "FINISHED", e.clock:now())
    e:emit("RIDE_CHANGED", ride)
  end
end

-- Clickers ----------------------------------------------------------------------------------

-- Whether name may click on my stand (R19): not me, not already a clicker,
-- and not a seated traveler still waiting for their ride. A traveler whose
-- ride has arrived may stay and click.
local function mayClick(e, stand, name)
  if Names.same(name, e.me) or isClicker(stand, name) then
    return false
  end
  if isSeated(stand, name) then
    local ride = e.rides[Names.normalize(name) .. "#" .. stand.standId]
    return ride ~= nil and (ride.state == "arrived" or ride.state == "done")
  end
  return true
end

-- Seats a clicker at pct: on the stand, in the ledger (their shift starts),
-- and out of any traveler seat they held. Returns true, or nil and why not.
local function seatClicker(e, stand, name, pct)
  local now = e.clock:now()
  local ok, why = Stand.addClicker(stand, name, pct, now)
  if not ok then
    return nil, why
  end
  local shift, refused = Ledger.join(ledgerOf(e, stand), name, pct, now)
  if not shift then
    Stand.removeClicker(stand, name)
    return nil, refused
  end
  local clean = Names.normalize(name)
  Stand.removeTraveler(stand, clean)
  part(stand, "talks")[clean] = nil
  if e:inGroup(clean) then
    part(stand, "seen")[clean] = true
  end
  standChanged(e, stand)
  return true
end

-- A clicker invited to my group gets INVITE_TIMEOUT seconds to join it, or is
-- sent away; one who joined is watched by GROUP_CHANGED instead.
local function awaitClicker(e, stand, name)
  local seat = stand.clickers[name]
  e.clock:after(INVITE_TIMEOUT, function()
    if e.stopped or e.stand ~= stand or stand.clickers[name] ~= seat or part(stand, "seen")[name] then
      return
    end
    e:safely("clicker invite timeout", dropClicker, e, stand, name, true)
  end)
end

-- An agreed negotiation: the clicker is seated, CLICK_OK confirms the share
-- and the clicker is invited. If the share no longer fits, CLICK_NO.
local function agree(e, stand, neg)
  local ok, why = seatClicker(e, stand, neg.clicker, neg.pct)
  if not ok then
    part(stand, "talks")[neg.clicker] = nil
    e:send("CLICK_NO", { standId = stand.standId }, "WHISPER", neg.clicker)
    return nil, why
  end
  e:send("CLICK_OK", { standId = stand.standId, agreedPct = neg.pct }, "WHISPER", neg.clicker)
  if not e:inGroup(neg.clicker) then
    e.game:invite(neg.clicker)
    awaitClicker(e, stand, neg.clicker)
  end
  return true
end

-- Someone asks to click on my stand for askedPct. CLICK_NO when they can't
-- (R19), the stand has no room for a clicker, or the ask is not a share. A
-- repeat while my talk with them is open is ignored, so the share I am
-- answering can't be swapped under me (R47).
Engine.handlers.CLICK_APPLY = function(e, msg, sender)
  local stand = e.stand
  if stand == nil or msg.standId ~= stand.standId then
    return
  end
  local name = Names.normalize(sender)
  if part(stand, "talks")[name] ~= nil then
    return
  end
  if stand.kind ~= "lock" or not mayClick(e, stand, name) or Stand.clickerCount(stand) >= MAX_CLICKERS
    or not wholeIn(msg.askedPct, 1, 99) then
    e:send("CLICK_NO", { standId = stand.standId }, "WHISPER", sender)
    return
  end
  local neg = Negotiation.new{
    standId = stand.standId, owner = Names.normalize(e.me), clicker = name,
    offeredPct = stand.clickerPct, askedPct = msg.askedPct,
  }
  part(stand, "talks")[name] = neg
  e:emit("CLICKER_APPLIED", neg)
end

local RESPONSES = { ACCEPT = true, COUNTER = true, DECLINE = true }

-- The owner answers an application: "ACCEPT" (the asked share), "COUNTER"
-- with pct, or "DECLINE". Every check uses the owner's share left now
-- (Stand.ownerPct). Returns true, or nil and "unknown_clicker", "bad_action",
-- "full", or why Negotiation or Stand refused.
Engine.respondClicker = Engine.action(function(e, clicker, action, pct)
  local stand = e.stand
  local name = Names.normalize(clicker)
  local talks = stand and part(stand, "talks")
  local neg = talks and name and talks[name]
  if not neg then
    return nil, "unknown_clicker"
  end
  if not RESPONSES[action] then
    return nil, "bad_action"
  end
  if action == "ACCEPT" and Stand.clickerCount(stand) >= MAX_CLICKERS then
    return nil, "full"
  end
  local ok, why = Negotiation.apply(neg, action, pct, Stand.ownerPct(stand))
  if not ok then
    return nil, why
  end
  if action == "ACCEPT" then
    return agree(e, stand, neg)
  elseif action == "COUNTER" then
    e:send("CLICK_OFFER", { standId = stand.standId, offeredPct = pct }, "WHISPER", name)
  else
    talks[name] = nil
    e:send("CLICK_NO", { standId = stand.standId }, "WHISPER", name)
  end
  standChanged(e, stand) -- the talk is no longer waiting for me: the UI's offer window closes
  return true
end)

-- The clicker takes my counter-offer. It is checked again against the share I
-- have left now, since another clicker may have taken some meanwhile.
Engine.handlers.CLICK_OK = function(e, msg, sender)
  local stand = e.stand
  if stand == nil or msg.standId ~= stand.standId then
    return
  end
  local name = Names.normalize(sender)
  local talks = part(stand, "talks")
  local neg = talks[name]
  if neg == nil or neg.state ~= "countered" then
    return
  end
  if msg.agreedPct == neg.pct and Stand.clickerCount(stand) < MAX_CLICKERS
    and Negotiation.apply(neg, "CLICKER_ACCEPT", nil, Stand.ownerPct(stand)) then
    agree(e, stand, neg)
  else
    talks[name] = nil
    e:send("CLICK_NO", { standId = stand.standId }, "WHISPER", sender)
  end
end

-- The clicker turns my counter-offer down.
Engine.handlers.CLICK_NO = function(e, msg, sender)
  local stand = e.stand
  if stand == nil or msg.standId ~= stand.standId then
    return
  end
  local talks = part(stand, "talks")
  local name = Names.normalize(sender)
  local neg = talks[name]
  if neg ~= nil then
    Negotiation.apply(neg, "DECLINE", nil, Stand.ownerPct(stand))
    talks[name] = nil
  end
end

-- A clicker ends their shift.
Engine.handlers.CLICK_LEAVE = function(e, msg, sender)
  local stand = e.stand
  if stand ~= nil and msg.standId == stand.standId and isClicker(stand, sender) then
    dropClicker(e, stand, sender)
  end
end

-- Marks a member of my group as a clicker at pct without any messages (my own
-- crew; their addon, if any, keeps no ledger). Returns true, or nil and
-- "no_stand", "is_owner", "not_in_group", "already_crew", "seated" (a
-- traveler still waiting for their ride), or why Stand or Ledger refused.
Engine.addOwnCrew = Engine.action(function(e, name, pct)
  local stand = e.stand
  if stand == nil then
    return nil, "no_stand"
  end
  if Names.same(name, e.me) then
    return nil, "is_owner"
  end
  if not e:inGroup(name) then
    return nil, "not_in_group"
  end
  if isClicker(stand, name) then
    return nil, "already_crew"
  end
  if not mayClick(e, stand, name) then
    return nil, "seated"
  end
  return seatClicker(e, stand, name, pct)
end)

-- Sends a clicker away from my stand: their shift ends and CLICK_NO tells
-- them. Returns true, or nil and "no_stand" or "unknown_clicker".
Engine.dismissClicker = Engine.action(function(e, name)
  local stand = e.stand
  if stand == nil then
    return nil, "no_stand"
  end
  if not isClicker(stand, name) then
    return nil, "unknown_clicker"
  end
  dropClicker(e, stand, Names.normalize(name), true)
  return true
end)

-- Payouts --------------------------------------------------------------------------------------

-- Each clicker of my latest stand with what they are owed (agreed tips only)
-- and what I have paid them, by name: { {clicker, owed, received}, ... }.
function Engine:payoutList()
  local stand = self.lastStand
  local l = stand and self.ledgers[stand.standId]
  local out = {}
  if l == nil then
    return out
  end
  local names = {}
  for name in pairs(l.shifts) do
    names[#names + 1] = name
  end
  table.sort(names)
  for _, name in ipairs(names) do
    out[#out + 1] = { clicker = name, owed = (Ledger.owed(l, name)), received = Ledger.receivedBy(l, name) }
  end
  return out
end

-- Opens a trade with a clicker of my latest stand, to pay them. Returns true,
-- or nil and "unknown_clicker" or "no_trade" (the game wouldn't open one).
Engine.payClicker = Engine.action(function(e, name)
  local stand = e.lastStand
  local l = stand and e.ledgers[stand.standId]
  local who = Names.normalize(name)
  if l == nil or who == nil or l.shifts[who] == nil then
    return nil, "unknown_clicker"
  end
  if not e.game:openTrade(who) then
    return nil, "no_trade"
  end
  return true
end)
