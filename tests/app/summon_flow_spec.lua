-- A TaxiDB in which `warlock` is an established warlock: five other travelers
-- rated them 5 stars. A fresh warlock is "New", and the guard warns about a New
-- warlock (decision 7), so without this no summon could be GREEN.
local function trusted(ns, warlock, now)
  local db = ns.Store.init(nil)
  for i = 1, 5 do
    local rater = "Old Rider" .. string.char(96 + i) -- "Old Ridera" .. "Old Ridere"
    local ts = now - 100 * i
    assert(ns.Ratings.addDirect(db, {kind = "trust", rater = rater, target = warlock, stars = 5,
      id = ns.Ride.makeId(warlock, rater, ts), ts = ts}, rater, now))
  end
  return db
end

-- The events p's engine emitted with this name, and the last of them.
local function emitted(p, name)
  local out = {}
  for _, ev in ipairs(p.events) do
    if ev[1] == name then out[#out + 1] = ev end
  end
  return out
end
local function last(p, name)
  local list = emitted(p, name)
  return list[#list]
end

-- Decoded single-chunk messages of one type on the bus, optionally from one sender.
local function wireOf(ns, w, msgType, sender)
  local out = {}
  for _, sent in ipairs(w.bus:sent()) do
    local text = sent.text:match("^[^:]+:1/1:(.*)$")
    local msg = text and ns.Protocol.decode(text)
    if msg and msg.type == msgType and (sender == nil or sent.sender == sender) then
      msg.dist, msg.to = sent.dist, sent.target
      out[#out + 1] = msg
    end
  end
  return out
end

describe("summon flow", function()
  local ns, w, lock, c1, c2, t
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed=2, start=20000}
    lock = w:addPlayer{name="Dar Kbolt", class="WARLOCK", level=45, place="gadgetzan", money=0}
    c1 = w:addPlayer{name="Cee One", class="PRIEST", level=40, place="gadgetzan"}
    c2 = w:addPlayer{name="Cee Two", class="ROGUE", level=40, place="gadgetzan"}
    t = w:addPlayer{name="Tra Veler", class="HUNTER", level=44, place="ironforge", money=50000,
      db=trusted(ns, "Dar Kbolt", 20000)}
  end)
  after_each(function() assert.are.same({}, w.errors) end) -- nothing logged (R15)
  local function crewUp()
    local s = lock.engine:openStand{kind="lock", seats=3, clickerPct=25}
    c1.engine:applyClicker(s.standId, 25); c2.engine:applyClicker(s.standId, 25); w:advance(2)
    lock.engine:respondClicker("Cee One", "ACCEPT"); lock.engine:respondClicker("Cee Two", "ACCEPT"); w:advance(2)
    w:acceptInvite("Cee One"); w:acceptInvite("Cee Two"); w:advance(61); return s
  end
  it("full ride: green guard, arrival, tip, two-sided rating, clicker shares", function()
    local s = crewUp(); assert.are.equal("live", ns.Stand.status(lock.engine.stand))
    t.engine:requestRide(s.standId, 10000); w:advance(2)
    local key = "Tra Veler#"..s.standId; lock.engine:acceptRequest(key); w:advance(2); w:acceptInvite("Tra Veler"); w:advance(2)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    local verdict = t.events[#t.events]; assert.are.equal("GUARD_VERDICT", verdict[1]); assert.are.equal("GREEN", verdict[2].level)
    w:acceptSummon("Tra Veler"); w:advance(2)
    local rideId = t.engine.rides[key] and t.engine.rides[key].rideId
    t.engine:submitArrival(rideId, 5, 10000); w:trade("Tra Veler", "Dar Kbolt", 10000); w:advance(3)
    local sum = t.engine:summary("Dar Kbolt", "trust"); assert.are.equal(5, sum.stars)
    assert.is_truthy(c1.engine.db.rideLogs["Dar Kbolt"][rideId])       -- two-sided proof reached others
    c1.engine:leaveStand(); w:advance(1)
    local ended; for _, ev in ipairs(c1.events) do if ev[1] == "SHIFT_ENDED" then ended = ev[2] end end
    assert.are.equal(2500, ended.owed); assert.are.equal(0, ended.received); assert.are.equal(1, ended.prefill)
  end)
  it("wrong destination is red", function()
    local s = crewUp(); t.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest("Tra Veler#"..s.standId); w:advance(2); w:acceptInvite("Tra Veler"); w:advance(2)
    w:moveTo("Dar Kbolt", "searing"); w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    -- Moving closed the stand, so a BOARD_CHANGED (its STAND_END) follows the verdict.
    assert.are.equal("RED", last(t, "GUARD_VERDICT")[2].level)
  end)
  it("raid conversion for the 3rd traveler", function()
    local t2 = w:addPlayer{name="Tre Two", class="MAGE", level=44, place="ironforge"}
    local t3 = w:addPlayer{name="Tre Three", class="DRUID", level=44, place="ironforge"}
    local s = crewUp()
    for _, p in ipairs{t, t2, t3} do assert.is_table(p.engine:requestRide(s.standId, 0)) end
    w:advance(2)
    assert.is_string(lock.engine:acceptRequest("Tra Veler#"..s.standId))
    assert.is_string(lock.engine:acceptRequest("Tre Two#"..s.standId))
    assert.are.same({nil, "needs_raid"}, {lock.engine:acceptRequest("Tre Three#"..s.standId)})
    assert.is_false(lock.game:isRaid())
    assert.is_string(lock.engine:convertAndAccept("Tre Three#"..s.standId))
    assert.is_true(lock.game:isRaid())
    w:advance(2)
    for _, name in ipairs{"Tra Veler", "Tre Two", "Tre Three"} do assert.is_true(w:acceptInvite(name), name) end
    w:advance(1)
    assert.are.equal(6, lock.game:groupSize())
    assert.are.same({"Tra Veler", "Tre Two", "Tre Three"}, lock.engine.stand.travelers)
    assert.are.equal("grouped", t3.engine.rides["Tre Three#"..s.standId].state)
  end)
  it("stranger summon shows no-ride yellow", function()                           -- Review Focus 3
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    local v = t.events[#t.events]; assert.are.equal("YELLOW", v[2].level); assert.are.equal("noride", v[2].checks[1].id)
  end)

  it("request resent twice then cancelled", function()
    local s = lock.engine:openStand{kind="lock"}; w:advance(1)
    w:removePlayer("Dar Kbolt")
    local ride = t.engine:requestRide(s.standId, 0)
    w:advance(ns.Config.RETRY_TIMEOUT * 3 - 1)
    assert.are.equal(3, #wireOf(ns, w, "REQUEST", "Tra Veler"))
    assert.are.equal("requested", ride.state)
    w:advance(2)
    assert.are.equal(3, #wireOf(ns, w, "REQUEST", "Tra Veler"))
    assert.are.equal("cancelled", ride.state)
    local changed = last(t, "RIDE_CHANGED")
    assert.are.equal(ride, changed[2]); assert.are.equal("cancelled", changed[2].state)
  end)

  it("driver leaving the group cancels the ride", function()
    local s = lock.engine:openStand{kind="lock"}; w:advance(1)
    local ride = t.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest("Tra Veler#"..s.standId); w:advance(2); w:acceptInvite("Tra Veler"); w:advance(1)
    assert.are.equal("grouped", ride.state)
    lock.engine:leaveGroup(); w:advance(1)
    assert.are.equal("cancelled", ride.state)
    assert.are.equal(ride, last(t, "RIDE_CHANGED")[2])
  end)

  it("traveler already in another group gets STATUS_LEAVE_GROUP", function()
    assert.are.equal("Leave your group so the driver can invite you.", rawget(ns.L, "STATUS_LEAVE_GROUP"))
    local s = lock.engine:openStand{kind="lock"}; w:advance(1)
    local friend = w:addPlayer{name="Fri End", class="PALADIN", level=40, place="ironforge"}
    friend.game:invite("Tra Veler"); assert.is_true(w:acceptInvite("Tra Veler"))
    t.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest("Tra Veler#"..s.standId); w:advance(2)
    assert.are.same({"STATUS", "STATUS_LEAVE_GROUP", "Leave your group so the driver can invite you."}, last(t, "STATUS"))
    assert.is_false(w:acceptInvite("Tra Veler")) -- the game refuses the invite while grouped
  end)

  it("pays the clickers their share: payout list, Pay, and a 5-star prefill when paid in full", function()
    local s = crewUp()
    local key = "Tra Veler#"..s.standId
    t.engine:requestRide(s.standId, 10000); w:advance(2)
    lock.engine:acceptRequest(key); w:advance(2); w:acceptInvite("Tra Veler"); w:advance(2)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler"); w:advance(2)
    local rideId = t.engine.rides[key].rideId
    assert.is_true(t.engine:submitArrival(rideId, nil, 10000))
    assert.are.equal("Dar Kbolt", t.tradeWith); assert.are.equal(10000, t.tradeMoney)
    w:trade("Tra Veler", "Dar Kbolt", 10000); w:advance(3)
    assert.are.same({{clicker = "Cee One", owed = 2500, received = 0}, {clicker = "Cee Two", owed = 2500, received = 0}},
      lock.engine:payoutList())
    assert.is_true(lock.engine:payClicker("Cee One"))
    assert.are.equal("Cee One", lock.tradeWith)
    assert.are.same({nil, "unknown_clicker"}, {lock.engine:payClicker("Tra Veler")})
    w:trade("Dar Kbolt", "Cee One", 2500); w:advance(1)
    assert.are.same({clicker = "Cee One", owed = 2500, received = 2500}, lock.engine:payoutList()[1])
    c1.engine:leaveStand(); w:advance(1)
    local ended = last(c1, "SHIFT_ENDED")[2]
    assert.are.equal(2500, ended.owed); assert.are.equal(2500, ended.received); assert.are.equal(5, ended.prefill)
    assert.are.same({}, ended.disputed)
  end)
end)

-- Beyond the brief --------------------------------------------------------------

describe("Driver", function()
  local ns, w, lock, t
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 3, start = 20000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan"}
    t = w:addPlayer{name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000}
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  local function add(name, o)
    o = o or {}
    o.name, o.class, o.level, o.place = name, o.class or "PRIEST", o.level or 40, o.place or "ironforge"
    return w:addPlayer(o)
  end

  -- A traveler's ride from request to grouped; returns the driver's and the traveler's ride.
  local function grouped(p, s)
    local key = p.name .. "#" .. s.standId
    local ride = p.engine:requestRide(s.standId, 0); w:advance(2)
    assert.is_string(lock.engine:acceptRequest(key)); w:advance(2)
    assert.is_true(w:acceptInvite(p.name)); w:advance(1)
    return lock.engine.rides[key], ride
  end

  it("opens a lock stand: STAND at once and every HEARTBEAT, settings kept in TaxiCharDB", function()
    local s = lock.engine:openStand{kind = "lock", seats = 2, clickerPct = 30, note = "Gadgetzan bank"}
    assert.are.equal("Dar Kbolt@20000", s.standId)
    assert.are.equal(s, lock.engine.stand)
    assert.are.equal("Dar Kbolt", s.owner)
    assert.are.same({"lock", "Alliance", 1446, 5000, 5000, "Tanaris", "Gadgetzan", 2, 30, "Gadgetzan bank"},
      {s.kind, s.faction, s.mapID, s.wx, s.wy, s.zone, s.subzone, s.seats, s.clickerPct, s.note})
    assert.are.same({seats = 2, clickerPct = 30, note = "Gadgetzan bank"}, lock.charDb.stand)
    assert.are.same({"STAND_CHANGED", s}, last(lock, "STAND_CHANGED"))
    w:advance(1)
    assert.are.equal(1, #wireOf(ns, w, "STAND", "Dar Kbolt"))
    local view = ns.Board.get(t.engine.board, s.standId)
    assert.are.same({"Dar Kbolt", 2, 0, 30}, {view.owner, view.seatsFree, view.clickers, view.clickerPct})
    w:advance(58)
    assert.are.equal(1, #wireOf(ns, w, "STAND", "Dar Kbolt"))
    w:advance(1) -- HEARTBEAT seconds after opening
    assert.are.equal(2, #wireOf(ns, w, "STAND", "Dar Kbolt"))
    w:advance(60)
    assert.are.equal(3, #wireOf(ns, w, "STAND", "Dar Kbolt"))
    lock.engine:closeStand(); w:advance(120)
    assert.are.equal(3, #wireOf(ns, w, "STAND", "Dar Kbolt")) -- no heartbeat after closing
    assert.are.equal(1, #wireOf(ns, w, "STAND_END", "Dar Kbolt"))
  end)

  it("refuses a stand it can't run, and sends nothing for it", function()
    local priest = add("Pri Est")
    local young = add("You Nglock", {class = "WARLOCK", level = 19})
    local mage = add("Mag Ister", {class = "MAGE", level = 30})
    local deep = add("Dee Plock", {class = "WARLOCK", level = 45, place = "deadmines"})
    assert.are.same({nil, "not_warlock"}, {priest.engine:openStand{kind = "lock"}})
    assert.are.same({nil, "low_level"}, {young.engine:openStand{kind = "lock"}})
    assert.are.same({nil, "no_portals"}, {mage.engine:openStand{kind = "mage"}})
    assert.are.same({nil, "no_portals"}, {priest.engine:openStand{kind = "mage"}})
    assert.are.same({nil, "instance"}, {deep.engine:openStand{kind = "lock"}})
    assert.are.same({nil, "bad_kind"}, {lock.engine:openStand{kind = "taxi"}})
    for _, seats in ipairs{0, 38, 2.5, "3"} do
      assert.are.same({nil, "bad_seats"}, {lock.engine:openStand{kind = "lock", seats = seats}}, tostring(seats))
    end
    for _, pct in ipairs{0, 51, 12.5} do
      assert.are.same({nil, "bad_pct"}, {lock.engine:openStand{kind = "lock", clickerPct = pct}}, tostring(pct))
    end
    assert.are.same({nil, "bad_note"}, {lock.engine:openStand{kind = "lock", note = string.rep("x", 4000)}})
    w:advance(1)
    assert.are.same({}, wireOf(ns, w, "STAND"))
    assert.is_table(lock.engine:openStand{kind = "lock"})
    assert.are.same({nil, "already_open"}, {lock.engine:openStand{kind = "lock"}})
    w:kill("Dar Kbolt")
    assert.are.same({nil, "dead"}, {lock.engine:openStand{kind = "lock"}})
  end)

  it("closes the stand when its owner moves more than 50 yards from it", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    w:moveTo("Dar Kbolt", "gadgetzan", 30, 0)
    assert.are.equal(s, lock.engine.stand)
    w:moveTo("Dar Kbolt", "gadgetzan", 51, 0)
    assert.is_nil(lock.engine.stand)
    assert.is_true(s.closed)
    w:advance(1)
    assert.are.equal(1, #wireOf(ns, w, "STAND_END", "Dar Kbolt"))
    assert.is_nil(ns.Board.get(t.engine.board, s.standId))
  end)

  it("files a request once, seats the traveler on accept, and gives up on an invite not taken in 60 s", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    local key = "Tra Veler#" .. s.standId
    local ride = t.engine:requestRide(s.standId, 5000)
    w:advance(ns.Config.RETRY_TIMEOUT + 2) -- the request was resent once
    assert.are.equal(2, #wireOf(ns, w, "REQUEST", "Tra Veler"))
    assert.are.equal(1, #emitted(lock, "REQUEST_RECEIVED"))
    local mine = lock.engine.rides[key]
    assert.are.same({"REQUEST_RECEIVED", mine}, last(lock, "REQUEST_RECEIVED"))
    assert.are.same({"requested", "summon", "Tra Veler", 5000, 44, key}, {mine.state, mine.kind, mine.traveler, mine.offer, mine.level, mine.key})
    local rideId = lock.engine:acceptRequest(key)
    assert.are.equal("Dar Kbolt@Tra Veler@" .. math.floor(w.clock:now()), rideId)
    assert.are.same({"Tra Veler"}, s.travelers)
    assert.are.equal("Dar Kbolt", t.invitedBy)
    w:advance(2)
    assert.are.equal("accepted", ride.state)
    assert.are.equal(rideId, ride.rideId)
    w:advance(57)
    assert.are.equal("accepted", mine.state)
    w:advance(2)
    assert.are.equal("cancelled", mine.state)
    assert.are.same({}, s.travelers)
    local declines = wireOf(ns, w, "DECLINE", "Dar Kbolt")
    assert.are.same({s.standId, "invite_failed", "WHISPER", "Tra Veler"}, {declines[1].standId, declines[1].reason, declines[1].dist, declines[1].to})
    assert.are.equal("cancelled", ride.state)
    assert.are.equal(ride, last(t, "RIDE_CHANGED")[2])
  end)

  it("says full when every seat is taken, and unknown_ride for anything else", function()
    local t2 = add("Tre Two")
    local s = lock.engine:openStand{kind = "lock", seats = 1}; w:advance(1)
    t.engine:requestRide(s.standId, 0); t2.engine:requestRide(s.standId, 0); w:advance(2)
    assert.is_string(lock.engine:acceptRequest("Tra Veler#" .. s.standId))
    assert.are.same({nil, "full"}, {lock.engine:acceptRequest("Tre Two#" .. s.standId)})
    assert.are.same({nil, "unknown_ride"}, {lock.engine:acceptRequest("Tra Veler#" .. s.standId)}) -- accepted already
    assert.are.same({nil, "unknown_ride"}, {lock.engine:acceptRequest("Nob Ody#" .. s.standId)})
  end)

  it("declineRequest whispers DECLINE with the reason", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    local ride = t.engine:requestRide(s.standId, 0); w:advance(2)
    assert.is_true(lock.engine:declineRequest("Tra Veler#" .. s.standId, "busy"))
    assert.are.same({nil, "unknown_ride"}, {lock.engine:declineRequest("Tra Veler#" .. s.standId, "busy")})
    w:advance(2)
    assert.are.equal("busy", wireOf(ns, w, "DECLINE", "Dar Kbolt")[1].reason)
    assert.are.equal("declined", ride.state)
    assert.are.equal(ride, last(t, "RIDE_CHANGED")[2])
  end)

  it("a traveler leaving the group frees the seat and cancels a ride that has not arrived", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    local mine = grouped(t, s)
    assert.are.equal("grouped", mine.state)
    t.engine:leaveGroup(); w:advance(1)
    assert.are.equal("cancelled", mine.state)
    assert.are.same({}, s.travelers)
    assert.are.equal(mine, last(lock, "RIDE_CHANGED")[2])
  end)

  it("ignores a REQUEST from one of its own clickers (R19)", function()
    local c1 = add("Cee One", {place = "gadgetzan"})
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    lock.game:invite("Cee One"); w:acceptInvite("Cee One")
    assert.is_true(lock.engine:addOwnCrew("Cee One", 25))
    c1.engine:requestRide(s.standId, 0); w:advance(2)
    assert.are.same({}, emitted(lock, "REQUEST_RECEIVED"))
    assert.is_nil(lock.engine.rides["Cee One#" .. s.standId])
  end)

  it("nextTraveler names the first grouped traveler in accept order and sends PORTAL_UP to the group", function()
    local t2 = add("Tre Two")
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    assert.is_nil(lock.engine:nextTraveler())
    t.engine:requestRide(s.standId, 0); t2.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest("Tra Veler#" .. s.standId); lock.engine:acceptRequest("Tre Two#" .. s.standId); w:advance(2)
    assert.is_true(w:acceptInvite("Tre Two")); w:advance(1)
    assert.are.equal("Tre Two", lock.engine:nextTraveler()) -- Tra Veler, first in the queue, hasn't joined
    assert.is_true(w:acceptInvite("Tra Veler")); w:advance(1)
    assert.are.equal("Tra Veler", lock.engine:nextTraveler())
    w:advance(1)
    local ups = wireOf(ns, w, "PORTAL_UP", "Dar Kbolt")
    assert.are.equal(2, #ups)
    assert.are.equal("PARTY", ups[1].dist)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler"); w:advance(2)
    assert.are.equal("arrived", lock.engine.rides["Tra Veler#" .. s.standId].state)
    assert.are.equal("Tre Two", lock.engine:nextTraveler())
  end)

  it("files a TIP only from the ride's traveler, and counts an early one once the ride arrives (R39)", function()
    add("Cee One", {place = "gadgetzan"})
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    lock.game:invite("Cee One"); assert.is_true(w:acceptInvite("Cee One"))
    assert.is_true(lock.engine:addOwnCrew("Cee One", 25))
    local mine = grouped(t, s)
    local function hear(sender, msgType, fields, dist)
      lock.engine:handle(assert(ns.Protocol.decode(ns.Protocol.encode(msgType, "t1", fields))), sender, dist)
    end
    hear("Cee One", "TIP", {rideId = mine.rideId, amount = 999}, "PARTY")         -- not the ride's traveler
    hear("Tra Veler", "TIP", {rideId = "Dar Kbolt@Tra Veler@1", amount = 999}, "PARTY") -- not a ride of mine
    hear("Tra Veler", "TIP", {rideId = mine.rideId, amount = 10000}, "PARTY")     -- before the ARRIVED
    hear("Tra Veler", "ARRIVED", {rideId = mine.rideId, warlock = "Dar Kbolt"}, "CHANNEL")
    assert.are.equal("arrived", mine.state)
    w:trade("Tra Veler", "Dar Kbolt", 10000); w:advance(1)
    assert.are.same({{clicker = "Cee One", owed = 2500, received = 0}}, lock.engine:payoutList())
  end)

  it("keeps the stand's combat and soul shard flags, and its status with them", function()
    add("Cee One", {place = "gadgetzan"}); add("Cee Two", {place = "gadgetzan"})
    local s = lock.engine:openStand{kind = "lock"}
    for _, name in ipairs{"Cee One", "Cee Two"} do
      lock.game:invite(name); assert.is_true(w:acceptInvite(name))
      assert.is_true(lock.engine:addOwnCrew(name, 25))
    end
    assert.are.equal("live", ns.Stand.status(s))
    w:setCombat("Cee Two", true)
    assert.is_true(s.flags.combat)
    assert.are.equal("paused", ns.Stand.status(s))
    w:setCombat("Cee Two", false)
    assert.is_false(s.flags.combat)
    lock.shards = 0
    w:advance(60) -- the heartbeat checks the shards
    assert.is_true(s.flags.noShards)
    assert.are.equal("paused", ns.Stand.status(s))
    lock.shards = 3
    w:advance(60)
    assert.is_false(s.flags.noShards)
    assert.are.equal("live", ns.Stand.status(s))
  end)
end)

describe("Traveler", function()
  local ns, w, lock, t
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 4, start = 30000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan"}
    t = w:addPlayer{name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000,
      db = trusted(ns, "Dar Kbolt", 30000)}
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  local function add(name, o)
    o = o or {}
    o.name, o.class, o.level, o.place = name, o.class or "PRIEST", o.level or 40, o.place or "ironforge"
    return w:addPlayer(o)
  end

  -- Opens Dar's stand and brings the traveler's ride to grouped; returns the stand and the ride.
  local function grouped()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    local ride = t.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest("Tra Veler#" .. s.standId); w:advance(2)
    assert.is_true(w:acceptInvite("Tra Veler")); w:advance(1)
    assert.are.equal("grouped", ride.state)
    return s, ride
  end

  local function check(verdict, id)
    for _, c in ipairs(verdict.checks) do
      if c.id == id then return c end
    end
  end

  it("requestRide keeps a copy of the stand, whispers REQUEST and refuses what it can't send", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    assert.are.same({nil, "unknown_stand"}, {t.engine:requestRide("Dar Kbolt@1", 0)})
    assert.are.same({nil, "bad_offer"}, {t.engine:requestRide(s.standId, -5)})
    assert.are.same({nil, "bad_offer"}, {t.engine:requestRide(s.standId, 1.5)})
    local ride = t.engine:requestRide(s.standId, nil)
    assert.are.equal(ride, t.engine.rides["Tra Veler#" .. s.standId])
    assert.are.same({"requested", "summon", "Dar Kbolt", "Tra Veler", 0}, {ride.state, ride.kind, ride.driver, ride.traveler, ride.offer})
    assert.are.same(ns.Board.get(t.engine.board, s.standId), ride.stand)
    assert.are_not.equal(ns.Board.get(t.engine.board, s.standId), ride.stand) -- a copy (R6)
    assert.are.same({nil, "pending"}, {t.engine:requestRide(s.standId, 0)})
    w:advance(1)
    local sent = wireOf(ns, w, "REQUEST", "Tra Veler")
    assert.are.same({s.standId, 0, 44, "WHISPER", "Dar Kbolt"}, {sent[1].standId, sent[1].offer, sent[1].level, sent[1].dist, sent[1].to})
  end)

  it("takes ACCEPT and DECLINE only from its driver, and an ACCEPT only with a ride id naming us both", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    local ride = t.engine:requestRide(s.standId, 0)
    local function hear(sender, msgType, fields)
      t.engine:handle(assert(ns.Protocol.decode(ns.Protocol.encode(msgType, "t1", fields))), sender, "WHISPER")
    end
    hear("Mal Ory", "ACCEPT", {rideId = "Mal Ory@Tra Veler@30001", standId = s.standId})
    hear("Mal Ory", "DECLINE", {standId = s.standId})
    hear("Dar Kbolt", "ACCEPT", {rideId = "Dar Kbolt@Oth Er@30001", standId = s.standId})
    hear("Dar Kbolt", "ACCEPT", {rideId = "free-form", standId = s.standId})
    assert.are.equal("requested", ride.state)
    hear("Dar Kbolt", "ACCEPT", {rideId = "Dar Kbolt@Tra Veler@30001", standId = s.standId})
    assert.are.equal("accepted", ride.state)
    assert.are.equal("Dar Kbolt@Tra Veler@30001", ride.rideId)
  end)

  it("a dead Hardcore traveler can't request a ride (R35, R37)", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    w:kill("Tra Veler")
    assert.are.same({nil, "dead"}, {t.engine:requestRide(s.standId, 0)})
  end)

  it("broadcasts RIDE_START on joining and records the ride in its own witness (R40)", function()
    local _, ride = grouped()
    w:advance(1)
    local starts = wireOf(ns, w, "RIDE_START", "Tra Veler")
    assert.are.same({ride.rideId, "Dar Kbolt", "CHANNEL"}, {starts[1].rideId, starts[1].warlock, starts[1].dist})
    assert.are.equal("Tra Veler", t.engine.witness.rides[ride.rideId].victim)
  end)

  it("my own death soon after arriving goes out as DEATH{self}", function()
    local _, ride = grouped()
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler")
    assert.are.equal("arrived", ride.state)
    assert.are.same({"ARRIVED", ride}, last(t, "ARRIVED"))
    w:advance(30)
    w:kill("Tra Veler"); w:advance(1)
    local deaths = wireOf(ns, w, "DEATH", "Tra Veler")
    assert.are.same({ride.rideId, "Tra Veler", "Dar Kbolt", "self"}, {deaths[1].rideId, deaths[1].victim, deaths[1].warlock, deaths[1].source})
  end)

  it("uses its copy of the stand once the stand is gone, and warns that it changed (R6)", function()
    grouped()
    lock.engine:closeStand(); w:advance(1)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    local v = last(t, "GUARD_VERDICT")[2]
    assert.are.equal("YELLOW", v.level)
    assert.is_false(check(v, "changed").ok)
    for _, id in ipairs{"summoner", "area", "position", "combat", "level", "trust"} do
      assert.is_true(check(v, id).ok, id)
    end
  end)

  it("warns when the stand moved after the request, even before the accept", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    t.engine:requestRide(s.standId, 0); w:advance(2)
    -- The owner's addon re-advertises its stand somewhere else under the same id.
    local moved = ns.Stand.toFields(s)
    moved.wx = 5030
    lock.engine:send("STAND", moved, "CHANNEL"); w:advance(1)
    lock.engine:acceptRequest("Tra Veler#" .. s.standId); w:advance(2)
    assert.is_true(w:acceptInvite("Tra Veler")); w:advance(1)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    assert.is_false(check(last(t, "GUARD_VERDICT")[2], "changed").ok)
  end)

  it("is RED when someone at the stand is in combat, but not for a group member far away", function()
    grouped()
    add("Far Away") -- in Ironforge
    add("Nea Rby", {place = "gadgetzan"})
    lock.game:invite("Far Away"); assert.is_true(w:acceptInvite("Far Away"))
    lock.game:invite("Nea Rby"); assert.is_true(w:acceptInvite("Nea Rby"))
    w:setCombat("Far Away", true); w:advance(1)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    local v = last(t, "GUARD_VERDICT")[2]
    assert.are.equal("GREEN", v.level)
    w:setCombat("Nea Rby", true)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    v = last(t, "GUARD_VERDICT")[2]
    assert.are.equal("RED", v.level)
    assert.are.equal("In combat: Nea Rby", check(v, "combat").text)
  end)

  it("counts a member the game can't place or can't tell the combat of as fighting at the stand (R21)", function()
    grouped()
    add("Far Away") -- in Ironforge, fighting
    lock.game:invite("Far Away"); assert.is_true(w:acceptInvite("Far Away"))
    w:setCombat("Far Away", true)
    local unitPos = t.game.unitPos
    t.game.unitPos = function(g, unit)
      if unit == g:unitFor("Far Away") then return nil end
      return unitPos(g, unit)
    end
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    assert.are.equal("In combat: Far Away", check(last(t, "GUARD_VERDICT")[2], "combat").text)
    t.game.unitPos = unitPos
    w:setCombat("Far Away", false)
    local unitInCombat = t.game.unitInCombat
    t.game.unitInCombat = function(g, unit)
      if unit == g:unitFor("Dar Kbolt") then return nil end
      return unitInCombat(g, unit)
    end
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    local v = last(t, "GUARD_VERDICT")[2]
    assert.are.equal("RED", v.level)
    assert.are.equal("In combat: Dar Kbolt", check(v, "combat").text)
  end)

  it("a declined summon waits for another once, then the ride is cancelled", function()
    local _, ride = grouped()
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    assert.are.equal("summoning", ride.state)
    assert.is_true(t.engine:cancelSummon()); w:advance(1)
    assert.are.equal("grouped", ride.state)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    t.engine:cancelSummon(); w:advance(1)
    assert.are.equal("cancelled", ride.state)
    assert.are.equal(ride, last(t, "RIDE_CHANGED")[2])
  end)

  it("landing away from the stand is not an arrival", function()
    local _, ride = grouped()
    w:moveTo("Dar Kbolt", "gadgetzan", 45, 0) -- still within 50 yards: the stand stays open
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler"); w:advance(1)
    assert.are.equal("RED", last(t, "GUARD_VERDICT")[2].level)
    assert.are.equal("summoning", ride.state)
    assert.are.same({}, emitted(t, "ARRIVED"))
  end)

  it("submitArrival checks everything before it rates or opens a trade", function()
    local _, ride = grouped()
    assert.are.same({nil, "unknown_ride"}, {t.engine:submitArrival("Dar Kbolt@Nob Ody@1", 5)})
    assert.are.same({nil, "not_arrived"}, {t.engine:submitArrival(ride.rideId, 5)})
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler"); w:advance(1)
    assert.are.same({nil, "bad_stars"}, {t.engine:submitArrival(ride.rideId, 6, 100)})
    assert.are.same({nil, "too_much"}, {t.engine:submitArrival(ride.rideId, 5, 60000)})
    assert.are.same({nil, "zero"}, {t.engine:submitArrival(ride.rideId, 5, 0)})
    assert.is_nil(t.tradeWith)
    assert.are.same({}, t.db.given)
    w:advance(1)
    assert.are.same({}, wireOf(ns, w, "RATING"))
    assert.is_true(t.engine:submitArrival(ride.rideId, 4))
    assert.is_nil(t.tradeWith) -- no tip, no trade
    w:advance(1)
    local r = wireOf(ns, w, "RATING", "Tra Veler")[1]
    assert.are.same({"trust", "Dar Kbolt", 4, ride.rideId, "CHANNEL"}, {r.kind, r.target, r.stars, r.id, r.dist})
  end)

  it("sends TIP to the group after the trade and finishes the ride", function()
    local _, ride = grouped()
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler"); w:advance(1)
    assert.is_true(t.engine:submitArrival(ride.rideId, nil, 5000))
    w:trade("Tra Veler", "Dar Kbolt", 5000); w:advance(1)
    assert.are.equal("done", ride.state)
    local tips = wireOf(ns, w, "TIP", "Tra Veler")
    assert.are.same({ride.rideId, 5000, "PARTY"}, {tips[1].rideId, tips[1].amount, tips[1].dist})
    local acks = wireOf(ns, w, "TIP_ACK", "Dar Kbolt")
    assert.are.same({ride.rideId, 5000, "PARTY"}, {acks[1].rideId, acks[1].amount, acks[1].dist})
    assert.are.equal("done", lock.engine.rides["Tra Veler#" .. ride.standId].state)
  end)
end)
