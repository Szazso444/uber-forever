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
    -- R53: the game converts on a later roster update; the accept waits for it.
    assert.is_true(lock.engine:convertAndAccept("Tre Three#"..s.standId))
    assert.is_false(lock.game:isRaid())
    assert.are.equal("requested", lock.engine.rides["Tre Three#"..s.standId].state)
    w:advance(0.2)
    assert.is_true(lock.game:isRaid())
    assert.are.equal("accepted", lock.engine.rides["Tre Three#"..s.standId].state)
    w:advance(2)
    for _, name in ipairs{"Tra Veler", "Tre Two", "Tre Three"} do assert.is_true(w:acceptInvite(name), name) end
    w:advance(1)
    assert.are.equal(6, lock.game:groupSize())
    assert.are.same({"Tra Veler", "Tre Two", "Tre Three"}, lock.engine.stand.travelers)
    assert.are.equal("grouped", t3.engine.rides["Tre Three#"..s.standId].state)
  end)
  it("a raid conversion that never happens gives up after 5 s (R53)", function()
    local t2 = w:addPlayer{name="Tre Two", class="MAGE", level=44, place="ironforge"}
    local t3 = w:addPlayer{name="Tre Three", class="DRUID", level=44, place="ironforge"}
    local s = crewUp()
    for _, p in ipairs{t, t2, t3} do assert.is_table(p.engine:requestRide(s.standId, 0)) end
    w:advance(2)
    lock.engine:acceptRequest("Tra Veler#"..s.standId); lock.engine:acceptRequest("Tre Two#"..s.standId)
    local convert = lock.game.convertToRaid
    lock.game.convertToRaid = function() end -- the game refuses (say, not the leader)
    local key = "Tre Three#"..s.standId
    local function failures()
      local n = 0
      for _, ev in ipairs(emitted(lock, "STATUS")) do if ev[2] == "STATUS_RAID_FAILED" then n = n + 1 end end
      return n
    end
    assert.is_true(lock.engine:convertAndAccept(key))
    w:advance(4.8)
    assert.are.equal(0, failures())
    w:advance(0.4)
    assert.are.equal(1, failures())
    assert.are.same({"STATUS", "STATUS_RAID_FAILED", "Couldn't convert the group to a raid."}, last(lock, "STATUS"))
    assert.are.equal("requested", lock.engine.rides[key].state)
    -- the wait is over: a raid made later doesn't accept the request by itself
    lock.game.convertToRaid = convert
    lock.game:convertToRaid(); w:advance(0.2)
    assert.is_true(lock.game:isRaid())
    assert.are.equal("requested", lock.engine.rides[key].state)
  end)

  it("convertAndAccept in a raid already accepts at once", function()
    local s = crewUp()
    lock.game:convertToRaid(); w:advance(0.2)
    assert.is_table(t.engine:requestRide(s.standId, 0)); w:advance(2)
    assert.is_string(lock.engine:convertAndAccept("Tra Veler#"..s.standId))
    assert.are.equal("accepted", lock.engine.rides["Tra Veler#"..s.standId].state)
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
    -- The traveler leaves that group and the driver invites again, which starts the 60 s wait over.
    local key = "Tra Veler#"..s.standId
    t.engine:leaveGroup(); w:advance(40)
    assert.is_true(lock.engine:reinvite(key))
    w:advance(40) -- 80 s after the accept: still waiting
    assert.are.equal("accepted", lock.engine.rides[key].state)
    assert.is_true(w:acceptInvite("Tra Veler")); w:advance(1)
    assert.are.equal("grouped", lock.engine.rides[key].state)
    assert.are.equal("grouped", t.engine.rides[key].state)
    assert.are.same({nil, "unknown_ride"}, {lock.engine:reinvite(key)}) -- in the group already
    assert.are.same({nil, "unknown_ride"}, {lock.engine:reinvite("Nob Ody#"..s.standId)})
  end)

  it("accepting the warlock's summon is an arrival wherever it lands, flagged as the wrong place (R43)", function()
    local s = crewUp()
    local key = "Tra Veler#"..s.standId
    t.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest(key); w:advance(2); w:acceptInvite("Tra Veler"); w:advance(2)
    w:moveTo("Dar Kbolt", "searing"); w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    assert.are.equal("RED", last(t, "GUARD_VERDICT")[2].level)
    w:acceptSummon("Tra Veler") -- against the guard's advice
    local ride = t.engine.rides[key]
    assert.are.same({"ARRIVED", ride}, last(t, "ARRIVED"))
    assert.are.equal("arrived", ride.state)
    assert.is_true(ride.wrongPlace)
    w:advance(30)
    w:kill("Tra Veler"); w:advance(1)
    for _, p in ipairs{lock, c1, c2, t} do
      local death = p.db.deaths["Dar Kbolt"] and p.db.deaths["Dar Kbolt"][ride.rideId]
      assert.is_true(death and death.heavy, p.name)
    end
  end)

  it("a summon from someone else during a live ride is judged against that ride: RED (R45)", function()
    local s = crewUp()
    local key = "Tra Veler#"..s.standId
    t.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest(key); w:advance(2); w:acceptInvite("Tra Veler"); w:advance(2)
    w:offerSummon("Cee One", "Tra Veler"); w:advance(1)
    local v, ride = last(t, "GUARD_VERDICT")[2], last(t, "GUARD_VERDICT")[3]
    assert.are.equal("RED", v.level)
    assert.are.equal("summoner", v.checks[1].id)
    assert.are.equal("Summoner: Cee One (agreed: Dar Kbolt)", v.checks[1].text)
    assert.are.equal(t.engine.rides[key], ride)
    assert.are.equal("grouped", ride.state) -- not the ride's summon: the ride doesn't move
    w:acceptSummon("Tra Veler")
    assert.are.same({}, emitted(t, "ARRIVED")) -- and taking it is no arrival of this ride
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

  describe("a request repeated after the warlock accepted it (R49)", function()
    local s, key, ride
    local function resend()
      t.engine:send("REQUEST", {standId = s.standId, offer = 0, level = 44}, "WHISPER", "Dar Kbolt")
    end
    before_each(function()
      s = lock.engine:openStand{kind = "lock"}; w:advance(1)
      key = "Tra Veler#" .. s.standId
      ride = t.engine:requestRide(s.standId, 0); w:advance(2)
    end)

    it("says the same ACCEPT again and invites the traveler again", function()
      local rideId = lock.engine:acceptRequest(key); w:advance(2)
      assert.are.equal(1, #wireOf(ns, w, "ACCEPT", "Dar Kbolt"))
      t.invitedBy = nil -- the first invite is gone
      resend(); w:advance(2)
      local accepts = wireOf(ns, w, "ACCEPT", "Dar Kbolt")
      assert.are.equal(2, #accepts)
      assert.are.same({rideId, s.standId, "WHISPER", "Tra Veler"}, {accepts[2].rideId, accepts[2].standId, accepts[2].dist, accepts[2].to})
      assert.are.equal("Dar Kbolt", t.invitedBy)
      -- It is the same ride: one request received, one seat, the same state.
      assert.are.equal(1, #emitted(lock, "REQUEST_RECEIVED"))
      assert.are.same({"Tra Veler"}, s.travelers)
      assert.are.same({"accepted", rideId}, {lock.engine.rides[key].state, lock.engine.rides[key].rideId})
    end)

    it("completes the traveler's ride when his first ACCEPT was lost", function()
      w.bus:setDropRate(1)
      lock.engine:acceptRequest(key); w:advance(2)
      w.bus:setDropRate(0)
      assert.are.equal("requested", ride.state)
      w:advance(ns.Config.RETRY_TIMEOUT) -- his REQUEST goes out again
      assert.are.equal("accepted", ride.state)
      assert.are.equal(lock.engine.rides[key].rideId, ride.rideId)
      assert.is_true(w:acceptInvite("Tra Veler")); w:advance(1)
      assert.are.equal("grouped", ride.state)
    end)

    it("joins a traveler who took the invite while his ACCEPT was lost", function()
      w.bus:setDropRate(1)
      lock.engine:acceptRequest(key); w:advance(2)
      w.bus:setDropRate(0)
      assert.is_true(w:acceptInvite("Tra Veler")); w:advance(1) -- in the group, ride still "requested" on his side
      assert.are.equal("requested", ride.state)
      w:advance(ns.Config.RETRY_TIMEOUT)
      assert.are.equal("grouped", ride.state)
      assert.is_table(t.engine.witness.rides[ride.rideId]) -- the RIDE_START went out: deaths can be tied to this ride
    end)

    it("does not invite a traveler who is in the group already, but still answers", function()
      lock.engine:acceptRequest(key); w:advance(2)
      assert.is_true(w:acceptInvite("Tra Veler")); w:advance(1)
      assert.is_nil(t.invitedBy)
      resend(); w:advance(2)
      assert.are.equal(2, #wireOf(ns, w, "ACCEPT", "Dar Kbolt"))
      assert.is_nil(t.invitedBy)
      assert.are.equal("grouped", ride.state) -- the repeated ACCEPT changes nothing
    end)

    it("does not start the 60 s wait over, so repeating the request can't hold the seat", function()
      lock.engine:acceptRequest(key); w:advance(30)
      resend(); w:advance(29)
      assert.are.equal("accepted", lock.engine.rides[key].state)
      w:advance(3) -- 62 s after the accept
      assert.are.equal("cancelled", lock.engine.rides[key].state)
      assert.are.same({}, s.travelers)
    end)

    it("answers nothing for a request that is still waiting, and a new one once the ride ended", function()
      resend(); w:advance(2)
      assert.are.same({}, wireOf(ns, w, "ACCEPT", "Dar Kbolt"))
      assert.is_true(lock.engine:declineRequest(key, "busy")); w:advance(2)
      local again = t.engine:requestRide(s.standId, 0); w:advance(2)
      assert.are.equal("requested", lock.engine.rides[key].state)
      assert.are.equal(again, t.engine.rides[key])
      assert.are.equal(2, #emitted(lock, "REQUEST_RECEIVED"))
    end)
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

  it("nextRide names the ride the Summon next button is for and sends nothing", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    assert.is_nil(lock.engine:nextRide())
    t.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest("Tra Veler#" .. s.standId); w:advance(2)
    assert.is_nil(lock.engine:nextRide()) -- accepted, not in the group yet
    assert.is_true(w:acceptInvite("Tra Veler")); w:advance(1)
    local ride = lock.engine.rides["Tra Veler#" .. s.standId]
    assert.are.equal(ride, lock.engine:nextRide())
    assert.are.equal(ride, lock.engine:nextRide()) -- asking again changes nothing
    w:advance(1)
    assert.are.same({}, wireOf(ns, w, "PORTAL_UP", "Dar Kbolt"))
    assert.are.equal("Tra Veler", lock.engine:nextTraveler()); w:advance(1) -- the click itself tells the group
    assert.are.equal(1, #wireOf(ns, w, "PORTAL_UP", "Dar Kbolt"))
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

  it("drops a clicker who agreed but didn't join the group within 60 s", function()
    local c1 = add("Cee One", {place = "gadgetzan"})
    local s = lock.engine:openStand{kind = "lock"}
    assert.is_true(c1.engine:applyClicker(s.standId, 25)); w:advance(2)
    assert.is_true(lock.engine:respondClicker("Cee One", "ACCEPT"))
    w:advance(59)
    assert.is_truthy(s.clickers["Cee One"])
    w:advance(2)
    assert.is_nil(s.clickers["Cee One"])
    assert.are.equal("recruiting", ns.Stand.status(s))
    assert.is_number(lock.engine.ledgers[s.standId].shifts["Cee One"].leaveTs)
    local no = wireOf(ns, w, "CLICK_NO", "Dar Kbolt")
    assert.are.same({s.standId, "WHISPER", "Cee One"}, {no[1].standId, no[1].dist, no[1].to})
    assert.is_nil(c1.engine.shift)
    assert.are.equal(1, #emitted(c1, "SHIFT_ENDED"))
  end)

  it("keeps a clicker who joined in time", function()
    add("Cee One", {place = "gadgetzan"}).engine:applyClicker(lock.engine:openStand{kind = "lock"}.standId, 25)
    w:advance(2)
    lock.engine:respondClicker("Cee One", "ACCEPT"); w:advance(30)
    assert.is_true(w:acceptInvite("Cee One")); w:advance(40)
    assert.is_truthy(lock.engine.stand.clickers["Cee One"])
    assert.are.same({}, wireOf(ns, w, "CLICK_NO"))
  end)

  it("ignores messages from players who aren't part of the ride, the talk or the stand", function()
    local c1 = add("Cee One", {place = "gadgetzan"})
    add("Mal Ory")
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    local mine = grouped(t, s)
    local function hear(sender, msgType, fields, dist)
      lock.engine:handle(assert(ns.Protocol.decode(ns.Protocol.encode(msgType, "t1", fields))), sender, dist or "WHISPER")
    end
    local requests, applied = #emitted(lock, "REQUEST_RECEIVED"), #emitted(lock, "CLICKER_APPLIED")
    -- An ARRIVED for my ride, but not from its traveler: no arrival, no ride log.
    hear("Mal Ory", "ARRIVED", {rideId = mine.rideId, warlock = "Dar Kbolt"}, "CHANNEL")
    assert.are.equal("grouped", mine.state)
    assert.is_nil(lock.db.rideLogs["Dar Kbolt"])
    -- A request or an application for a stand id that isn't mine.
    hear("Mal Ory", "REQUEST", {standId = "Dar Kbolt@1", offer = 0, level = 30})
    hear("Mal Ory", "CLICK_APPLY", {standId = "Dar Kbolt@1", askedPct = 25})
    assert.are.equal(requests, #emitted(lock, "REQUEST_RECEIVED"))
    assert.are.equal(applied, #emitted(lock, "CLICKER_APPLIED"))
    -- Cee One's talk is countered; others can't take or drop it.
    assert.is_true(c1.engine:applyClicker(s.standId, 30)); w:advance(2)
    assert.is_true(lock.engine:respondClicker("Cee One", "COUNTER", 20))
    hear("Mal Ory", "CLICK_OK", {standId = s.standId, agreedPct = 20})
    hear("Mal Ory", "CLICK_NO", {standId = s.standId})
    hear("Cee One", "CLICK_OK", {standId = "Dar Kbolt@1", agreedPct = 20})
    assert.is_nil(s.clickers["Mal Ory"])
    assert.is_nil(s.clickers["Cee One"])
    assert.are.equal("countered", s.talks["Cee One"].state)
    -- Cee One clicks; a CLICK_LEAVE from anyone else, or for another stand, changes nothing.
    hear("Cee One", "CLICK_OK", {standId = s.standId, agreedPct = 20})
    assert.are.equal(20, s.clickers["Cee One"].pct)
    hear("Mal Ory", "CLICK_LEAVE", {standId = s.standId})
    hear("Cee One", "CLICK_LEAVE", {standId = "Dar Kbolt@1"})
    assert.are.equal(20, s.clickers["Cee One"].pct)
    assert.is_nil(lock.engine.ledgers[s.standId].shifts["Cee One"].leaveTs)
    w:advance(2)
    assert.are.same({}, wireOf(ns, w, "CLICK_NO", "Dar Kbolt")) -- no replies to any of it
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

  it("a stand past its TTL can't be asked for a ride even before the sweep has removed it (R51)", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    w:removePlayer("Dar Kbolt") -- no STAND_END
    w:advance(ns.Config.STAND_TTL) -- the board sweep runs every 30 s and has not reached it yet
    assert.is_not_nil(t.engine.board.stands[s.standId])
    assert.is_nil(ns.Board.get(t.engine.board, s.standId, w.clock:now()))
    assert.are.same({nil, "unknown_stand"}, {t.engine:requestRide(s.standId, 0)})
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

  it("lands at the stand: an arrival in the right place (R43)", function()
    local _, ride = grouped()
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler")
    assert.are.equal("arrived", ride.state)
    assert.is_false(ride.wrongPlace)
  end)

  it("lands 45 yards off the stand: still an arrival, in the wrong place (R43)", function()
    local _, ride = grouped()
    w:moveTo("Dar Kbolt", "gadgetzan", 45, 0) -- within 50 yards: the stand stays open
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler")
    assert.are.equal("arrived", ride.state)
    assert.is_true(ride.wrongPlace)
    w:advance(1)
    assert.are.equal(2, #wireOf(ns, w, "ARRIVED", "Tra Veler")) -- one arrival: the channel and the driver (R50)
  end)

  describe("ARRIVED goes to the channel and by whisper to the driver (R50)", function()
    it("sends the same ARRIVED twice, once to each", function()
      local _, ride = grouped()
      w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler"); w:advance(1)
      local sent = wireOf(ns, w, "ARRIVED", "Tra Veler")
      assert.are.equal(2, #sent)
      assert.are.same({ride.rideId, "Dar Kbolt", "CHANNEL"}, {sent[1].rideId, sent[1].warlock, sent[1].dist})
      assert.are.same({ride.rideId, "Dar Kbolt", "WHISPER", "Dar Kbolt"}, {sent[2].rideId, sent[2].warlock, sent[2].dist, sent[2].to})
    end)

    it("the warlock still logs the ride and says RIDE_LOG when the channel ARRIVED is lost", function()
      local _, ride = grouped()
      local send = t.engine.send
      t.engine.send = function(e, msgType, fields, dist, ...)
        if msgType == "ARRIVED" and dist == "CHANNEL" then return nil, "lost" end
        return send(e, msgType, fields, dist, ...)
      end
      w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler"); w:advance(2)
      local mine = lock.engine.rides["Tra Veler#" .. ride.standId]
      assert.are.equal("arrived", mine.state)
      assert.are.equal("Tra Veler", lock.db.rideLogs["Dar Kbolt"][ride.rideId].traveler)
      local logs = wireOf(ns, w, "RIDE_LOG", "Dar Kbolt")
      assert.are.equal(1, #logs)
      assert.are.same({ride.rideId, "Tra Veler"}, {logs[1].rideId, logs[1].traveler})
    end)

    it("a driver hearing it twice logs and answers once, and keeps the first receipt time", function()
      local _, ride = grouped()
      w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler"); w:advance(2)
      local arrivedAt = lock.engine.rides["Tra Veler#" .. ride.standId].times.arrived
      local changes = #emitted(lock, "RIDE_CHANGED")
      lock.engine:handle(assert(ns.Protocol.decode(ns.Protocol.encode("ARRIVED", "t9", {rideId = ride.rideId, warlock = "Dar Kbolt"}))), "Tra Veler", "WHISPER")
      w:advance(2)
      assert.are.equal(1, #wireOf(ns, w, "RIDE_LOG", "Dar Kbolt"))
      assert.are.equal(changes, #emitted(lock, "RIDE_CHANGED"))
      assert.are.equal(arrivedAt, lock.engine.rides["Tra Veler#" .. ride.standId].times.arrived)
    end)

    it("every other listener is idempotent too: a repeat keeps the receipt time and the arrival", function()
      local _, ride = grouped()
      w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler"); w:advance(2)
      local receipt = lock.db.receipts["Dar Kbolt"][ride.rideId]
      local arrival = lock.engine.witness.rides[ride.rideId].arrivedTs
      w:advance(20)
      lock.engine:handle(assert(ns.Protocol.decode(ns.Protocol.encode("ARRIVED", "t9", {rideId = ride.rideId, warlock = "Dar Kbolt"}))), "Tra Veler", "CHANNEL")
      assert.are.equal(receipt, lock.db.receipts["Dar Kbolt"][ride.rideId])
      assert.are.equal(arrival, lock.engine.witness.rides[ride.rideId].arrivedTs)
    end)
  end)

  it("a declined summon (no move) is not an arrival (R43)", function()
    local _, ride = grouped()
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    t.engine:cancelSummon()
    w:moveTo("Tra Veler", "gadgetzan") -- a move before the popup's SUMMON_GONE is seen
    w:advance(31)
    assert.are.equal("grouped", ride.state)
    w:moveTo("Tra Veler", "ironforge")
    -- Declined on the game's own popup: the addon only sees the popup go away.
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    t.game:cancelSummon(); w:advance(31)
    assert.are.equal("cancelled", ride.state) -- the second failure
    assert.are.same({}, emitted(t, "ARRIVED"))
  end)

  it("tells the UI when the summon popup went away, ride or no ride (the guard panel hides on it)", function()
    local _, ride = grouped()
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    assert.are.equal(0, #emitted(t, "SUMMON_GONE"))
    t.engine:cancelSummon(); w:advance(1) -- declined on the guard panel: the popup closes
    assert.are.equal(1, #emitted(t, "SUMMON_GONE"))
    assert.are.equal("grouped", ride.state)
    -- A summon nobody asked for: no ride is involved, the popup still goes away.
    local stranger = add("Cee One")
    w:offerSummon("Dar Kbolt", "Cee One"); w:advance(1)
    assert.are.equal("YELLOW", last(stranger, "GUARD_VERDICT")[2].level)
    w:fire(stranger, "SUMMON_GONE")
    assert.are.equal(1, #emitted(stranger, "SUMMON_GONE"))
  end)

  it("a landing seen within 30 s after the popup went away is still the summon's (R43)", function()
    local _, ride = grouped()
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    w:fire(t, "SUMMON_GONE") -- the popup closes on accepting, before the teleport is seen
    w:advance(5)
    assert.are.equal("summoning", ride.state)
    w:acceptSummon("Tra Veler")
    assert.are.equal("arrived", ride.state)
    assert.is_false(ride.wrongPlace)
  end)

  it("a move more than 30 s after the popup went away is not the summon's (R43)", function()
    local _, ride = grouped()
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    w:fire(t, "SUMMON_GONE"); w:advance(31)
    assert.are.equal("grouped", ride.state)
    w:moveTo("Tra Veler", "gadgetzan")
    assert.are.same({}, emitted(t, "ARRIVED"))
  end)

  it("while summoning, a short walk is no arrival, a jump of more than 100 yards is (R43)", function()
    local _, ride = grouped()
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    w:moveTo("Tra Veler", "ironforge", 60, 0)
    assert.are.equal("summoning", ride.state)
    w:moveTo("Tra Veler", "ironforge", 101, 0)
    assert.are.equal("arrived", ride.state)
    assert.is_true(ride.wrongPlace)
  end)

  it("still judges a summon when gathering the facts fails, and never GREEN", function()
    local _, ride = grouped()
    -- The game's summon popup names the summoner itself; the map lookup the guard needs raises.
    t.game.summonFacts = function() return {summoner = "Dar Kbolt", areaName = "Tanaris"} end
    t.game.mapName = function() error("adapter broke") end
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    local verdict = last(t, "GUARD_VERDICT")
    assert.are.equal("RED", verdict[2].level)
    assert.are.equal(ride, verdict[3])
    assert.are.equal("summoning", ride.state)
    local logged = false
    for _, line in ipairs(w.errors) do
      if line:find("guard facts", 1, true) then logged = true end
    end
    assert.is_true(logged)
    w.errors = {} -- logged on purpose
  end)

  it("is RED when the game gives no group roster (R21)", function()
    grouped()
    t.game.groupNames = function() return nil end
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    local v = last(t, "GUARD_VERDICT")[2]
    assert.are.equal("RED", v.level)
    assert.is_false(check(v, "combat").ok)
  end)

  it("checks the warlock's combat directly, and counts a roster name it can't find as fighting", function()
    grouped()
    -- The roster leaves the warlock out (or spells them otherwise); the warlock is fighting.
    t.game.groupNames = function() return {"Tra Veler"} end
    w:setCombat("Dar Kbolt", true)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    local v = last(t, "GUARD_VERDICT")[2]
    assert.are.equal("RED", v.level)
    assert.are.equal("In combat: Dar Kbolt", check(v, "combat").text)
    w:setCombat("Dar Kbolt", false)
    -- A roster name that resolves to no unit counts as fighting, by name.
    t.game.groupNames = function() return {"Tra Veler", "Dar Kbolt", "Dar Kbolt-Forever"} end
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    v = last(t, "GUARD_VERDICT")[2]
    assert.are.equal("RED", v.level)
    assert.are.equal("In combat: Dar Kbolt-Forever", check(v, "combat").text)
  end)

  it("judges a summon from a moved stand against the place I asked for: RED (R46)", function()
    local s = grouped()
    -- A changed addon keeps its stand open while the warlock walks 60 yards,
    -- and advertises the new spot under the same id.
    lock.engine.stand = nil
    w:moveTo("Dar Kbolt", "gadgetzan", 60, 0)
    local moved = ns.Stand.toFields(s)
    moved.wx = s.wx + 60
    lock.engine:send("STAND", moved, "CHANNEL"); w:advance(1)
    assert.are.equal(s.wx + 60, ns.Board.get(t.engine.board, s.standId).wx)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:advance(1)
    local v = last(t, "GUARD_VERDICT")[2]
    assert.are.equal("RED", v.level)
    assert.is_false(check(v, "position").ok)
    assert.is_false(check(v, "changed").ok)
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
