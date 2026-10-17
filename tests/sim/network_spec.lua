-- Network and environment failure scenarios: message loss, instance lockdown,
-- wiped saved data and a warlock who disconnects. Whole Taxi clients (Engine +
-- Transport) on the simulated World and Bus. Every scenario ends with no engine
-- error logged (R15).

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

describe("message loss", function()
  local ns, w, lock, t, stand, key, changes

  -- Records the state each RIDE_CHANGED of p had at the moment it was emitted,
  -- and when. (The event itself holds the live ride, which changes afterwards,
  -- so it can't show that the traveler was told at the time.)
  local function watch(p)
    local seen = {}
    local emit = p.engine.emit
    p.engine.emit = function(e, event, ride, ...)
      if event == "RIDE_CHANGED" then
        seen[#seen + 1] = {state = ride.state, at = w.clock:now()}
      end
      return emit(e, event, ride, ...)
    end
    return seen
  end

  local function states(list)
    local out = {}
    for i, change in ipairs(list) do out[i] = change.state end
    return out
  end

  -- A warlock with an open stand that the traveler has on his board (set up
  -- before any message is lost).
  local function setup(seed)
    ns = Taxi.load(); w = ns.World.new{seed = seed, start = 700000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan"}
    t = w:addPlayer{name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000}
    changes = watch(t)
    stand = lock.engine:openStand{kind = "lock"}; w:advance(2)
    key = "Tra Veler#" .. stand.standId
  end
  after_each(function() assert.are.same({}, w.errors) end)

  -- The players act as they would: the warlock accepts a request that reaches
  -- him, the traveler takes the invite once the warlock has sent it, and the
  -- warlock summons him once he is in the group.
  local function play(seconds)
    for _ = 1, seconds do
      local mine, theirs = lock.engine.rides[key], t.engine.rides[key]
      if mine ~= nil and mine.state == "requested" then lock.engine:acceptRequest(key) end
      if mine ~= nil and mine.state == "accepted" and t.invitedBy ~= nil then w:acceptInvite(t.name) end
      if theirs.state == "grouped" then
        w:offerSummon(lock.name, t.name); w:acceptSummon(t.name)
      end
      w:advance(1)
    end
  end

  it("a REQUEST that is lost is sent again, and the resend gets through", function()
    setup(41)
    w.bus:setDropRate(1)
    local ride = t.engine:requestRide(stand.standId, 0); w:advance(1)
    assert.are.equal(1, #wireOf(ns, w, "REQUEST", "Tra Veler")) -- sent, and lost on the way
    assert.is_nil(lock.engine.rides[key])
    w.bus:setDropRate(0)
    w:advance(ns.Config.RETRY_TIMEOUT)
    assert.are.equal(2, #wireOf(ns, w, "REQUEST", "Tra Veler"))
    assert.are.equal("requested", lock.engine.rides[key].state)
    assert.is_string(lock.engine:acceptRequest(key)); w:advance(2)
    assert.are.equal("accepted", ride.state)
    assert.are.same({"requested", "accepted"}, states(changes))
  end)

  it("when every REQUEST is lost the traveler's ride is cancelled at the third timeout, and he is told then", function()
    setup(42)
    w.bus:setDropRate(1)
    local ride = t.engine:requestRide(stand.standId, 0)
    local asked = ride.times.requested
    w:advance(ns.Config.RETRY_TIMEOUT * 3 - 1)
    assert.are.equal("requested", ride.state)
    assert.are.same({"requested"}, states(changes)) -- nothing to tell yet
    w:advance(2)
    assert.are.equal(3, #wireOf(ns, w, "REQUEST", "Tra Veler")) -- the request and two resends
    assert.are.equal("cancelled", ride.state)
    assert.are.same({"requested", "cancelled"}, states(changes))
    assert.is_near(asked + ns.Config.RETRY_TIMEOUT * 3, changes[2].at, 1e-6) -- told at the cancel, not before or after
    assert.is_near(ride.times.cancelled, changes[2].at, 1e-6)
    assert.is_nil(lock.engine.rides[key])
  end)

  it("a lost ACCEPT is said again when the traveler repeats his REQUEST, and the ride goes on (R49)", function()
    setup(43)
    local ride = t.engine:requestRide(stand.standId, 0); w:advance(2)
    w.bus:setDropRate(1)
    assert.is_string(lock.engine:acceptRequest(key)); w:advance(1) -- ACCEPT is lost; the invite is not a message
    w.bus:setDropRate(0)
    assert.are.same({"accepted", "requested"}, {lock.engine.rides[key].state, ride.state})
    w:advance(ns.Config.RETRY_TIMEOUT) -- his REQUEST goes out again and brings the ACCEPT again
    assert.are.equal("accepted", ride.state)
    play(5)
    assert.are.equal("arrived", ride.state)
    assert.are.same({"requested", "accepted", "grouped", "summoning", "arrived"}, states(changes))
    assert.are.equal(2, #wireOf(ns, w, "ACCEPT", "Dar Kbolt"))
  end)

  it("when every ACCEPT is lost both sides give up cleanly: the traveler at 30 s, the warlock when his invite goes unanswered", function()
    setup(44)
    local send = lock.engine.send
    lock.engine.send = function(e, msgType, ...)
      if msgType == "ACCEPT" then return nil, "lost" end
      return send(e, msgType, ...)
    end
    local ride = t.engine:requestRide(stand.standId, 0); w:advance(2)
    assert.is_string(lock.engine:acceptRequest(key))
    local mine = lock.engine.rides[key]
    w:advance(ns.Config.RETRY_TIMEOUT * 3) -- his resends are answered with ACCEPTs that never arrive
    assert.are.equal("cancelled", ride.state)
    assert.are.same({"requested", "cancelled"}, states(changes))
    assert.are.equal("accepted", mine.state)
    assert.are.same({"Tra Veler"}, stand.travelers)
    w:advance(31) -- 60 s after the accept
    assert.are.equal("cancelled", mine.state)
    assert.are.same({}, stand.travelers) -- the seat is free again
    assert.are.same({"requested", "cancelled"}, states(changes)) -- the DECLINE that follows changes nothing for him
    assert.are.same({}, wireOf(ns, w, "ACCEPT"))
  end)

  it("a lost channel ARRIVED leaves the warlock's ride logged anyway, by the whisper (R50)", function()
    setup(45)
    local by = w:addPlayer{name = "Bys Tander", class = "ROGUE", level = 44, place = "ironforge"}
    local send = t.engine.send
    t.engine.send = function(e, msgType, fields, dist, ...)
      if msgType == "ARRIVED" and dist == "CHANNEL" then return nil, "lost" end
      return send(e, msgType, fields, dist, ...)
    end
    local ride = assert(t.engine:requestRide(stand.standId, 0))
    play(8)
    assert.are.equal("arrived", ride.state)
    assert.are.equal("arrived", lock.engine.rides[key].state)
    assert.are.equal(1, #wireOf(ns, w, "RIDE_LOG", "Dar Kbolt"))
    -- Everyone who hears the log can count the traveler's rating in full, even
    -- though he never heard the ARRIVED (so he holds no receipt of the ride).
    assert.is_truthy(by.db.rideLogs["Dar Kbolt"][ride.rideId])
    assert.is_nil(by.db.receipts["Dar Kbolt"])
  end)

  -- A fifth of all deliveries lost, for several seeds of the bus: the ride
  -- either completes or the traveler's request is cancelled in time, and the
  -- traveler is told of each state as it happens; nothing raises.
  for seed = 1, 12 do
    it("with 20% of deliveries lost (seed " .. seed .. ") the ride completes or the request is cancelled within three timeouts", function()
      setup(seed)
      w.bus:setDropRate(0.2)
      local ride = assert(t.engine:requestRide(stand.standId, 0))
      play(45)
      assert.is_truthy(({arrived = true, done = true, cancelled = true})[ride.state], ride.state)
      -- He was told of the state the ride ended in, when it happened.
      local told = states(changes)
      assert.are.equal(ride.state, told[#told])
      if ride.state == "cancelled" then
        assert.is_near(ride.times.cancelled, changes[#changes].at, 1e-6)
        assert.is_true(changes[#changes].at - ride.times.requested <= ns.Config.RETRY_TIMEOUT * 3 + 1e-6)
      else
        assert.is_number(ride.times.arrived)
        assert.is_near(ride.times.arrived, changes[#changes].at, 1e-6)
      end
    end)
  end
end)

describe("lockdown", function()
  local ns, w, lock, obs
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 51, start = 800000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan"}
    obs = w:addPlayer{name = "Fre Sh", class = "ROGUE", level = 44, place = "ironforge"}
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  it("a warlock who enters an instance can't open a stand and is told so once; the stand he had closes", function()
    local stand = lock.engine:openStand{kind = "lock"}; w:advance(2)
    assert.is_truthy(ns.Board.get(obs.engine.board, stand.standId))
    w:moveTo("Dar Kbolt", "deadmines")
    assert.are.same({nil, "instance"}, {lock.engine:openStand{kind = "lock"}})
    assert.are.same({"STATUS", "STATUS_LOCKDOWN", ns.L.STATUS_LOCKDOWN}, last(lock, "STATUS"))
    assert.are.equal(1, #emitted(lock, "STATUS")) -- the only status he was ever shown
    assert.is_true(stand.closed)
    assert.is_nil(lock.engine.stand)
    w:moveTo("Dar Kbolt", "deadmines", 10, 10) -- moving about inside says nothing more
    assert.are.equal(1, #emitted(lock, "STATUS"))
    assert.are.same({nil, "instance"}, {lock.engine:openStand{kind = "lock"}})
  end)

  it("inside the instance nothing leaves the warlock; outside again his STAND_END goes out and he can open a stand", function()
    local stand = lock.engine:openStand{kind = "lock"}; w:advance(2)
    local sent = #w.bus:sent()
    w:moveTo("Dar Kbolt", "deadmines")
    lock.engine:send("QUERY", {target = "Bad Lock"}, "CHANNEL")
    w:advance(10)
    assert.are.equal(sent, #w.bus:sent()) -- held in his queue, not sent, not lost
    assert.is_true(lock.engine.transport:queued() >= 2)
    assert.is_truthy(ns.Board.get(obs.engine.board, stand.standId)) -- others see the stand until it expires
    w:moveTo("Dar Kbolt", "gadgetzan")
    w:advance(2)
    assert.are.equal(1, #wireOf(ns, w, "STAND_END", "Dar Kbolt"))
    assert.are.equal(1, #wireOf(ns, w, "QUERY", "Dar Kbolt"))
    assert.is_nil(ns.Board.get(obs.engine.board, stand.standId))
    local again = lock.engine:openStand{kind = "lock"}
    assert.is_table(again)
    assert.are_not.equal(stand.standId, again.standId)
    w:moveTo("Dar Kbolt", "deadmines") -- another visit is announced again
    assert.are.equal(2, #emitted(lock, "STATUS"))
  end)
end)

describe("wiped saved data", function()
  local ns, w, wiped

  local function add(name, o)
    o = o or {}
    o.name, o.class, o.level, o.place = name, o.class or "PRIEST", o.level or 30, o.place or "ironforge"
    return w:addPlayer(o)
  end

  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 61, start = 900000}
    wiped = add("Wip Ed")
    add("Hol Dera"); add("Hol Derb"); add("Hol Derc")
    -- Three travelers rate Dar Kbolt on the channel and log off; the holders and
    -- Wip Ed hear it live.
    local ts = math.floor(w.clock:now())
    for i, stars in ipairs{5, 4, 2} do
      local rater = add("Rat Er" .. string.char(96 + i))
      rater.engine:send("RATING", {kind = "trust", target = "Dar Kbolt", stars = stars,
        id = ns.Ride.makeId("Dar Kbolt", rater.name, ts), ts = ts}, "CHANNEL")
    end
    w:advance(2)
    for i = 1, 3 do w:removePlayer("Rat Er" .. string.char(96 + i)) end
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  it("a player recreated with an empty db regains the ratings by asking the others, second hand", function()
    local C = ns.Config.RATING
    assert.are.equal(3, #wiped.db.ratings["Dar Kbolt"].trust) -- heard live: three direct ratings

    w:removePlayer("Wip Ed")
    local again = add("Wip Ed", {db = ns.Store.init(nil)}) -- the saved variables are gone
    assert.are.same({}, again.db.ratings)
    local empty = again.engine:summary("Dar Kbolt", "trust")
    assert.are.same({nil, 0}, {empty.stars, empty.count})
    assert.is_true(again.engine:query("Dar Kbolt")); w:advance(10)

    local list = again.db.ratings["Dar Kbolt"].trust
    assert.are.equal(3, #list)
    for _, r in ipairs(list) do
      assert.are.same({["Hol Dera"] = true, ["Hol Derb"] = true, ["Hol Derc"] = true}, r.via, r.rater)
    end
    local after = again.engine:summary("Dar Kbolt", "trust")
    -- Three holders back each record, so each weighs the corroborated 0.5 (under
    -- both relay caps), and second-hand ratings leave the warlock "New".
    local expected = (C.PRIOR_WEIGHT * C.PRIOR_MEAN + C.W_RELAYED_CORROBORATED * (5 + 4 + 2))
      / (C.PRIOR_WEIGHT + 3 * C.W_RELAYED_CORROBORATED)
    assert.is_near(expected, after.score, 1e-9)
    assert.are.same({3.7, 3, true}, {after.stars, after.count, after.isNew})
    assert.is_false(again.engine:query("Dar Kbolt")) -- the new client's own cooldown is running now
  end)
end)

describe("board expiry", function()
  local ns, w, lock, obs, t
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 71, start = 1000000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan"}
    obs = w:addPlayer{name = "Fre Sh", class = "ROGUE", level = 44, place = "ironforge"}
    t = w:addPlayer{name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge"}
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  it("a stand whose warlock disconnects is gone from every board STAND_TTL after its last heartbeat (R51)", function()
    local TTL = ns.Config.STAND_TTL
    local stand = lock.engine:openStand{kind = "lock"}
    w:advance(130) -- heartbeats at 0, 60 and 120 s
    local view = ns.Board.get(obs.engine.board, stand.standId)
    assert.is_truthy(view)
    local heard = view.seenAt
    assert.is_true(w.clock:now() - heard < ns.Config.HEARTBEAT + 1e-6)

    w:removePlayer("Dar Kbolt") -- no STAND_END: he just drops off the server
    w:advance(TTL - 1 - (w.clock:now() - heard)) -- one second short of the TTL
    for _, p in ipairs{obs, t} do
      assert.is_truthy(ns.Board.get(p.engine.board, stand.standId, w.clock:now()), p.name)
      assert.are.equal(1, #ns.Board.list(p.engine.board, {now = w.clock:now()}), p.name)
    end

    w:advance(2) -- one second past it
    assert.is_near(TTL + 1, w.clock:now() - heard, 1e-6)
    for _, p in ipairs{obs, t} do
      local now = w.clock:now()
      assert.is_nil(ns.Board.get(p.engine.board, stand.standId, now), p.name)
      assert.are.same({}, ns.Board.list(p.engine.board, {now = now}), p.name)
      assert.are.same({nil, "unknown_stand"}, {p.engine:requestRide(stand.standId, 0)}, p.name)
    end

    -- The board's own sweep follows within one sweep interval, and tells the UI.
    local changes = #emitted(obs, "BOARD_CHANGED")
    assert.is_not_nil(obs.engine.board.stands[stand.standId])
    w:advance(ns.Engine.TICK_INTERVAL)
    assert.is_nil(obs.engine.board.stands[stand.standId])
    assert.are.equal(changes + 1, #emitted(obs, "BOARD_CHANGED"))
  end)
end)
