-- Attack scenarios: whole Taxi clients (Engine + Transport) on the simulated
-- World and Bus, with the attacker's moves made through real messages. Each
-- scenario's expected numbers are worked out from Config, so a retuned weight
-- changes the sum and not the story. Every scenario ends with no engine error
-- logged (R15).

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

-- The trust ratings on file about target.
local function trust(db, target) return (db.ratings[target] or {}).trust or {} end

-- The score the rating rules give for parts = { {stars, weight}, ... }.
local function scoreOf(ns, parts)
  local C = ns.Config.RATING
  local sumW, sumWS = 0, 0
  for _, part in ipairs(parts) do
    sumW, sumWS = sumW + part[2], sumWS + part[2] * part[1]
  end
  return (C.PRIOR_WEIGHT * C.PRIOR_MEAN + sumWS) / (C.PRIOR_WEIGHT + sumW)
end

-- A summon ride up to the traveler's arrival: the traveler asks the stand, the
-- warlock accepts, the traveler joins the group, the warlock presses Summon
-- next and summons, and the traveler accepts. Returns the traveler's ride.
local function rideTo(w, lock, p, standId)
  local ride = assert(p.engine:requestRide(standId, 0)); w:advance(2)
  assert(lock.engine:acceptRequest(p.name .. "#" .. standId)); w:advance(2)
  assert.is_true(w:acceptInvite(p.name)); w:advance(2)
  assert.are.equal(p.name, lock.engine:nextTraveler())
  w:offerSummon(lock.name, p.name); w:advance(1)
  assert.is_true(w:acceptSummon(p.name))
  assert.are.equal("arrived", ride.state)
  return ride
end

-- The player never gets the server's death notice (HC_DEATH): it was throttled
-- or lost. He can learn of a death from the victim's own DEATH message only.
local function deaf(p)
  local onGame = p.engine.onGame
  p.engine.onGame = function(e, event, ...)
    if event == "HC_DEATH" then return end
    return onGame(e, event, ...)
  end
end

-- The warlock's addon never broadcasts its RIDE_LOG (it still keeps it).
local function suppressRideLog(lock)
  local send = lock.engine.send
  lock.engine.send = function(e, msgType, ...)
    if msgType == "RIDE_LOG" then return nil, "skipped" end
    return send(e, msgType, ...)
  end
end

-- The check of a guard verdict with this id.
local function check(verdict, id)
  for _, c in ipairs(verdict.checks) do
    if c.id == id then return c end
  end
end

describe("alt ring", function()
  local ns, w, lock, honest, obs, alts, stand
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 31, start = 200000}
    lock = w:addPlayer{name = "Bad Lock", class = "WARLOCK", level = 45, place = "gadgetzan"}
    honest = w:addPlayer{name = "Hon Est", class = "HUNTER", level = 44, place = "ironforge", money = 50000}
    obs = w:addPlayer{name = "Fre Sh", class = "ROGUE", level = 44, place = "ironforge"} -- fresh db, hears everything
    alts = {}
    for i = 1, 10 do
      alts[i] = w:addPlayer{name = "Ring Alt" .. string.char(96 + i), class = "MAGE", level = 30, place = "ironforge"}
    end
    stand = lock.engine:openStand{kind = "lock"}; w:advance(2)
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  it("ten alts with no ride logs are outweighed by one honest 1-star and one death: score under 3.0, trust check YELLOW", function()
    local C = ns.Config
    -- Each alt rates 5 stars on its own account; none rode, so the warlock's ride
    -- log names none of them and each counts one-sided (W_ONE_SIDED), once.
    local ts = math.floor(w.clock:now())
    for _, alt in ipairs(alts) do
      alt.engine:send("RATING", {kind = "trust", target = "Bad Lock", stars = 5,
        id = ns.Ride.makeId("Bad Lock", alt.name, ts), ts = ts}, "CHANNEL")
    end
    w:advance(2)
    local ring = obs.engine:summary("Bad Lock", "trust")
    assert.are.equal(10, #trust(obs.db, "Bad Lock"))
    assert.are.same({5, false}, {ring.stars, ring.isNew}) -- ten direct ratings clear "New"
    assert.is_true(ring.score >= C.GUARD_LOW_TRUST)       -- the known limit: the ring alone passes the guard

    -- One honest rider: a real ride, a 1-star rating (two-sided, the warlock's
    -- RIDE_LOG names him) and, 30 s after arriving, his death.
    local ride = rideTo(w, lock, honest, stand.standId)
    assert.is_true(honest.engine:submitArrival(ride.rideId, 1)); w:advance(30)
    w:kill("Hon Est"); w:advance(2)
    assert.is_truthy(obs.db.rideLogs["Bad Lock"][ride.rideId])
    local d = obs.db.deaths["Bad Lock"][ride.rideId]
    assert.are.same({true, "Hon Est"}, {d.heavy, d.victim})

    -- Ten 5-star alts at 0.3, one 1-star at 1.0, one heavy death at 5.0:
    -- (5 * 3.5 + 15 + 1 + 5) / (5 + 3 + 1 + 5) = 2.75.
    local after = obs.engine:summary("Bad Lock", "trust")
    local parts = {{1, C.RATING.W_TWO_SIDED}, {1, C.RATING.W_DEATH}}
    for _ = 1, 10 do parts[#parts + 1] = {5, C.RATING.W_ONE_SIDED} end
    assert.is_near(scoreOf(ns, parts), after.score, 1e-9)
    assert.is_true(after.score < C.GUARD_LOW_TRUST)
    assert.are.same({false, 1}, {after.isNew, after.deathsReported}) -- not New: 11 direct ratings and a death

    -- So a fresh observer who asks Bad Lock for a ride is warned about trust, and
    -- about nothing else.
    local key = "Fre Sh#" .. stand.standId
    assert.is_table(obs.engine:requestRide(stand.standId, 0)); w:advance(2)
    assert.is_string(lock.engine:acceptRequest(key)); w:advance(2)
    assert.is_true(w:acceptInvite("Fre Sh")); w:advance(2)
    w:offerSummon("Bad Lock", "Fre Sh"); w:advance(1)
    local verdict = last(obs, "GUARD_VERDICT")[2]
    local trustCheck = check(verdict, "trust")
    assert.are.same({false, "YELLOW"}, {trustCheck.ok, trustCheck.level})
    assert.are.equal("YELLOW", verdict.level)
    for _, id in ipairs{"summoner", "area", "position", "combat", "level", "changed"} do
      assert.is_true(check(verdict, id).ok, id)
    end
  end)
end)

-- R66: a warlock and one alt in league log and rate 60 rides that never
-- happened, each backdated to its own day, so each is two-sided.
describe("backdated rides from one alt", function()
  it("are one rider's one vote: a single two-sided rating's effect, still New", function()
    local ns = Taxi.load()
    local w = ns.World.new{seed = 9, start = 400000000}
    local lock = w:addPlayer{name = "Bad Lock", class = "WARLOCK", level = 50, place = "searing"}
    local alt = w:addPlayer{name = "Alt One", class = "MAGE", level = 20, place = "ironforge"}
    local obs = w:addPlayer{name = "Fre Sh", class = "ROGUE", level = 44, place = "ironforge"}
    local now = math.floor(w.clock:now())
    for i = 1, 60 do
      local id = ns.Ride.makeId("Bad Lock", "Alt One", now - i * 86400)
      lock.engine:send("RIDE_LOG", {rideId = id, traveler = "Alt One"}, "CHANNEL")
      alt.engine:send("RATING", {kind = "trust", target = "Bad Lock", stars = 5, id = id, ts = now - i * 86400}, "CHANNEL")
    end
    w:advance(200)
    assert.are.equal(60, #trust(obs.db, "Bad Lock")) -- all kept
    local s = obs.engine:summary("Bad Lock", "trust")
    assert.is_near(scoreOf(ns, {{5, ns.Config.RATING.W_TWO_SIDED}}), s.score, 1e-9)
    assert.is_true(s.isNew)
    assert.are.same({}, w.errors)
  end)
end)

-- R67: receipts alone are one side's word. An alt that announces 300 arrivals
-- from a warlock (or the warlock's addon that logs them) moves the shown
-- count by little, and Store.prune caps what is kept.
describe("a flood of arrivals", function()
  it("from one alt shows no summons, and is capped on disk", function()
    local ns = Taxi.load()
    ns.Config.RATING.CAP_PER_KIND = 100
    local w = ns.World.new{seed = 13, start = 600000}
    local alt = w:addPlayer{name = "Alt One", class = "MAGE", level = 20, place = "ironforge"}
    local lock = w:addPlayer{name = "Any Lock", class = "WARLOCK", level = 50, place = "gadgetzan"}
    local obs = w:addPlayer{name = "Fre Sh", class = "ROGUE", level = 44, place = "ironforge"}
    local now = math.floor(w.clock:now())
    for i = 1, 300 do
      alt.engine:send("ARRIVED", {rideId = ns.Ride.makeId("Any Lock", "Alt One", now - i), warlock = "Any Lock"}, "CHANNEL")
    end
    w:advance(400)
    assert.are.equal(0, obs.engine:summary("Any Lock", "trust").count) -- no ride log backs any of them
    -- With the warlock in league logging every one of them: one ride a day.
    for i = 1, 300 do
      lock.engine:send("RIDE_LOG", {rideId = ns.Ride.makeId("Any Lock", "Alt One", now - i), traveler = "Alt One"}, "CHANNEL")
    end
    w:advance(400)
    assert.are.equal(1, obs.engine:summary("Any Lock", "trust").count)
    ns.Store.prune(obs.db)
    local receipts, logs = 0, 0
    for _ in pairs(obs.db.receipts["Any Lock"]) do receipts = receipts + 1 end
    for _ in pairs(obs.db.rideLogs["Any Lock"]) do logs = logs + 1 end
    assert.are.same({100, 100}, {receipts, logs})
    assert.are.same({}, w.errors)
  end)
end)

-- R68: one client's QUERYs must not hold a responder's ride traffic back.
describe("a query flood", function()
  it("leaves an honest warlock's ACCEPT on time, and the ride completes", function()
    local ns = Taxi.load()
    local w = ns.World.new{seed = 17, start = 700000}
    local lock = w:addPlayer{name = "Hon Lock", class = "WARLOCK", level = 50, place = "gadgetzan"}
    local q = w:addPlayer{name = "Que Ry", class = "MAGE", level = 20, place = "ironforge"}
    local t = w:addPlayer{name = "Tra Vel", class = "HUNTER", level = 40, place = "ironforge"}
    local now = math.floor(w.clock:now())
    -- The warlock's addon has heard 50 ratings about each of 20 other warlocks.
    for k = 1, 20 do
      local target = "Oth Er" .. string.char(96 + k)
      for i = 1, 50 do
        local rater = "Rat Er" .. k .. "x" .. i
        assert(ns.Ratings.addDirect(lock.db, {kind = "trust", rater = rater, target = target, stars = 4,
          id = ns.Ride.makeId(target, rater, now - 5000 - i), ts = now - 4000 - i}, rater, now))
      end
    end
    local stand = assert(lock.engine:openStand{kind = "lock"}); w:advance(2)
    for k = 1, 20 do
      q.engine:send("QUERY", {target = "Oth Er" .. string.char(96 + k)}, "CHANNEL")
    end
    w:advance(8)
    assert.is_true(lock.transport:queuedMessages("QUERY_R") <= ns.Config.QUERY_MAX_QUEUED)
    local ride = assert(t.engine:requestRide(stand.standId, 0)); w:advance(1)
    assert.is_string(lock.engine:acceptRequest("Tra Vel#" .. stand.standId))
    w:advance(2)
    assert.are.equal("accepted", ride.state)
    assert.is_true(w:acceptInvite("Tra Vel")); w:advance(2)
    assert.are.equal("Tra Vel", lock.engine:nextTraveler())
    w:offerSummon("Hon Lock", "Tra Vel"); w:advance(1)
    assert.is_true(w:acceptSummon("Tra Vel")); w:advance(3)
    assert.are.equal("arrived", ride.state)
    assert.are.equal("arrived", lock.engine.rides["Tra Vel#" .. stand.standId].state)
    -- The flood bought the asker few replies: at most one every QUERY_REPLY_INTERVAL.
    local replies = 0
    for _, sent in ipairs(w.bus:sent()) do
      if sent.sender == "Hon Lock" and sent.text:find("^[^:]+:1/%d+:%d+%^QUERY_R%^") then replies = replies + 1 end
    end
    assert.is_true(replies <= 1 + math.floor((w.clock:now() - now) / ns.Config.QUERY_REPLY_INTERVAL), replies)
    assert.are.same({}, w.errors)
  end)
end)

describe("invented relays", function()
  local ns, w, obs, relayers, nobody, TS, ID
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 32, start = 300000}
    obs = w:addPlayer{name = "Fre Sh", class = "ROGUE", level = 44, place = "ironforge"}
    nobody = w:addPlayer{name = "Nobody Real", class = "PRIEST", level = 40, place = "ironforge"}
    relayers = {}
    for i = 1, 3 do
      relayers[i] = w:addPlayer{name = "Rel Ay" .. string.char(96 + i), class = "MAGE", level = 30, place = "ironforge"}
    end
    TS = math.floor(w.clock:now())
    ID = ns.Ride.makeId("Bad Lock", "Nobody Real", TS)
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  -- Every relayer answers the observer's open query with the same invented
  -- records, as a client that wants to be believed would.
  local function relay(records)
    assert.is_true(obs.engine:query("Bad Lock")); w:advance(1)
    for _, r in ipairs(relayers) do
      assert.is_string(r.engine:send("QUERY_R", {target = "Bad Lock", records = records}, "WHISPER", "Fre Sh"))
    end
    w:advance(3)
  end

  it("three relayers of an invented 5-star weigh 0.5; the real rater's own 1-star strikes each of them once and counts alone", function()
    local C = ns.Config.RATING
    relay({{kind = "trust", rater = "Nobody Real", stars = 5, id = ID, ts = TS}})
    local list = trust(obs.db, "Bad Lock")
    assert.are.equal(1, #list)
    assert.are.same({["Rel Aya"] = true, ["Rel Ayb"] = true, ["Rel Ayc"] = true}, list[1].via)
    local invented = obs.engine:summary("Bad Lock", "trust")
    assert.are.same({5, true}, {invented.stars, invented.isNew}) -- second hand never clears "New"
    assert.is_near(scoreOf(ns, {{5, C.W_RELAYED_CORROBORATED}}), invented.score, 1e-9)

    -- The real rater says 1 star for that very ride and time.
    assert.is_string(nobody.engine:send("RATING", {kind = "trust", target = "Bad Lock", stars = 1, id = ID, ts = TS}, "CHANNEL"))
    w:advance(2)
    for _, r in ipairs(relayers) do
      assert.are.equal(1, obs.db.strikes[r.name], r.name)
    end
    list = trust(obs.db, "Bad Lock")
    assert.are.equal(1, #list)
    assert.are.same({"Nobody Real", 1}, {list[1].rater, list[1].stars})
    assert.is_nil(list[1].via)
    local real = obs.engine:summary("Bad Lock", "trust")
    assert.are.same({1, 1}, {real.stars, real.count})
    assert.is_near(scoreOf(ns, {{1, C.W_ONE_SIDED}}), real.score, 1e-9)
  end)

  it("an invented record the real rater's rating does not match is dropped without blaming the relayers", function()
    relay({{kind = "trust", rater = "Nobody Real", stars = 5, id = ID, ts = TS}})
    -- A rating of the same day under another id: not the same record, so nobody
    -- altered anything, but it replaces the rater's second-hand rating.
    assert.is_string(nobody.engine:send("RATING", {kind = "trust", target = "Bad Lock", stars = 1,
      id = ns.Ride.makeId("Bad Lock", "Nobody Real", TS + 60), ts = TS + 60}, "CHANNEL"))
    w:advance(2)
    assert.are.same({}, obs.db.strikes)
    local list = trust(obs.db, "Bad Lock")
    assert.are.equal(1, #list)
    assert.are.equal(1, list[1].stars)
    assert.is_nil(list[1].via)
  end)

  it("a flood of invented relays buys at most RELAY_CAP_TOTAL of weight and never clears New", function()
    local C = ns.Config.RATING
    for i = 1, 3 do
      relayers[#relayers + 1] = w:addPlayer{name = "Rel Ayx" .. string.char(96 + i), class = "MAGE", level = 30, place = "ironforge"}
    end
    local records = {}
    for i = 1, 10 do
      local rater = "Fak Rat" .. string.char(96 + i)
      records[i] = {kind = "trust", rater = rater, stars = 5, id = ns.Ride.makeId("Bad Lock", rater, TS), ts = TS}
    end
    relay(records)
    assert.are.equal(10, #trust(obs.db, "Bad Lock"))
    local flood = obs.engine:summary("Bad Lock", "trust")
    assert.is_true(flood.isNew)
    -- Six relayers back ten records at 0.5 each: scaled to 0.5 per relayer, then
    -- to 2.0 in all.
    assert.is_near(scoreOf(ns, {{5, C.RELAY_CAP_TOTAL}}), flood.score, 1e-9)
  end)
end)

describe("warlock that skips RIDE_LOG", function()
  local ns, w, lock, t, by, stand
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 33, start = 400000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan"}
    t = w:addPlayer{name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000}
    by = w:addPlayer{name = "Bys Tander", class = "ROGUE", level = 44, place = "ironforge"}
    stand = lock.engine:openStand{kind = "lock"}; w:advance(2)
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  local function rateOnce()
    local ride = rideTo(w, lock, t, stand.standId)
    assert.is_true(t.engine:submitArrival(ride.rideId, 1)); w:advance(2)
    return ride
  end

  it("with the RIDE_LOG the traveler's rating is two-sided (control)", function()
    local ride = rateOnce()
    assert.is_truthy(by.db.rideLogs["Dar Kbolt"][ride.rideId])
    local s = by.engine:summary("Dar Kbolt", "trust")
    assert.are.equal(1, s.stars)
    assert.is_near(scoreOf(ns, {{1, ns.Config.RATING.W_TWO_SIDED}}), s.score, 1e-9)
  end)

  it("without it the same rating counts one-sided (0.3), for everyone who heard it", function()
    suppressRideLog(lock)
    local ride = rateOnce()
    for _, p in ipairs{by, t} do
      assert.is_nil(p.db.rideLogs["Dar Kbolt"], p.name)
      local s = p.engine:summary("Dar Kbolt", "trust")
      assert.are.equal(1, s.stars, p.name)
      assert.is_near(scoreOf(ns, {{1, ns.Config.RATING.W_ONE_SIDED}}), s.score, 1e-9, p.name)
    end
    assert.is_truthy(by.db.receipts["Dar Kbolt"][ride.rideId]) -- the ride is still known: the traveler said ARRIVED
  end)
end)

describe("death within the window", function()
  local ns, w, lock, c1, by, blind, t, stand, ride
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 34, start = 450000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan"}
    c1 = w:addPlayer{name = "Cee One", class = "PRIEST", level = 40, place = "gadgetzan"}
    by = w:addPlayer{name = "Bys Tander", class = "ROGUE", level = 44, place = "ironforge"}
    blind = w:addPlayer{name = "Bli Nd", class = "ROGUE", level = 44, place = "ironforge"}
    deaf(blind) -- hears everything but the server's death notice
    t = w:addPlayer{name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000}
    stand = lock.engine:openStand{kind = "lock"}; w:advance(2)
    ride = rideTo(w, lock, t, stand.standId)
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  local function stored(p)
    return p.db.deaths["Dar Kbolt"] and p.db.deaths["Dar Kbolt"][ride.rideId]
  end
  local function heavy(p)
    local d = stored(p)
    return d ~= nil and d.heavy == true
  end

  for _, secs in ipairs{30, 119} do
    it("a kill " .. secs .. " s after arrival is a heavy death on every player who heard RIDE_START", function()
      w:advance(secs - 1)
      local late = w:addPlayer{name = "Lat Ecomer", class = "ROGUE", level = 44, place = "ironforge"} -- missed the start
      w:advance(1)
      w:kill("Tra Veler"); w:advance(2)
      -- Those who saw the server's notice saw the death themselves; Bli Nd only
      -- has the victim's report, which the warlock's RIDE_LOG (heard by all) backs.
      for _, p in ipairs{lock, c1, by, t, blind} do
        assert.is_true(heavy(p), p.name)
        assert.are.equal(p == blind and "self" or "observed", stored(p).source, p.name)
        local s = p.engine:summary("Dar Kbolt", "trust")
        assert.are.equal(1, s.deathsReported, p.name)
        assert.is_near(scoreOf(ns, {{1, ns.Config.RATING.W_DEATH}}), s.score, 1e-9, p.name)
      end
      -- Someone who never heard the victim start the ride has nothing to tie his
      -- death to: he records none, whatever the victim's own report says.
      assert.is_false(heavy(late))
      assert.are.same({}, late.db.deaths)
      -- The dead victim sends nothing more, so nobody takes him for a liar and
      -- the death stays on file.
      w:advance(ns.Config.ALIVE_GRACE + 60)
      for _, p in ipairs{lock, c1, by, t, blind} do
        assert.is_true(heavy(p), p.name)
        assert.are.same({}, p.db.liars, p.name)
      end
    end)
  end

  for _, secs in ipairs{121, 150} do
    it("a kill " .. secs .. " s after arrival records nothing", function()
      w:advance(secs)
      w:kill("Tra Veler"); w:advance(2)
      for _, p in ipairs{lock, c1, by, t, blind} do
        assert.are.same({}, p.db.deaths, p.name)
        assert.are.equal(0, p.engine:summary("Dar Kbolt", "trust").deathsReported, p.name)
      end
    end)
  end

  it("one death is one heavy death: a traveler with two rides open counts against one warlock only, the latest arrival's (R32)", function()
    w:advance(10)
    local other = ns.Ride.makeId("Eve Lock", "Tra Veler", math.floor(w.clock:now()))
    assert.is_string(t.engine:send("RIDE_START", {rideId = other, warlock = "Eve Lock"}, "CHANNEL")); w:advance(1)
    assert.is_string(t.engine:send("ARRIVED", {rideId = other, warlock = "Eve Lock"}, "CHANNEL")); w:advance(10)
    w:kill("Tra Veler"); w:advance(2)
    for _, p in ipairs{lock, c1, by} do
      assert.is_true(p.db.deaths["Eve Lock"][other].heavy, p.name)
      assert.is_nil(p.db.deaths["Dar Kbolt"], p.name) -- his own death report for that ride is refused: one heavy death each
    end
  end)
end)

describe("fake death claim", function()
  local ns, w, lock, fake, bo, cy, stand, id
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 35, start = 500000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan"}
    fake = w:addPlayer{name = "Fak Er", class = "ROGUE", level = 44, place = "ironforge"}
    bo = w:addPlayer{name = "Bo Lee", class = "MAGE", level = 30, place = "ironforge"}
    cy = w:addPlayer{name = "Cy New", class = "PRIEST", level = 30, place = "ironforge"}
    stand = lock.engine:openStand{kind = "lock"}; w:advance(2)
    id = ns.Ride.makeId("Dar Kbolt", "Fak Er", math.floor(w.clock:now()))
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  it("a living player who reports his own death is a liar on every observer once he is heard again", function()
    -- R7: RIDE_START, then DEATH{self}, then (after ALIVE_GRACE) a message that is not a DEATH.
    -- He never rode: no accept, no arrival, no RIDE_LOG from the warlock behind it.
    assert.is_string(fake.engine:send("RIDE_START", {rideId = id, warlock = "Dar Kbolt"}, "CHANNEL")); w:advance(2)
    assert.is_string(fake.engine:send("DEATH", {rideId = id, victim = "Fak Er", warlock = "Dar Kbolt", secs = 10,
      source = "self"}, "CHANNEL")); w:advance(2)
    -- R48: a silent throwaway identity moves the warlock's score by a one-sided
    -- rating's weight only, not a heavy death's. The warning is still there.
    for _, p in ipairs{lock, bo, cy} do
      local d = p.db.deaths["Dar Kbolt"][id]
      assert.are.same({false, "self", nil}, {d.heavy, d.source, d.via}, p.name)
      local s = p.engine:summary("Dar Kbolt", "trust")
      assert.are.same({1, true}, {s.deathsReported, s.isNew}, p.name)
      assert.is_near(scoreOf(ns, {{1, ns.Config.RATING.W_ONE_SIDED}}), s.score, 1e-9, p.name)
    end

    w:advance(ns.Config.ALIVE_GRACE + 1)
    -- His REQUEST is whispered to the warlock alone, so only the warlock hears he is alive.
    assert.is_table(fake.engine:requestRide(stand.standId, 0)); w:advance(2)
    assert.is_number(lock.db.liars["Fak Er"])
    assert.is_nil(lock.db.deaths["Dar Kbolt"])
    assert.is_nil(bo.db.liars["Fak Er"])
    assert.is_truthy(bo.db.deaths["Dar Kbolt"][id])
    -- Asking the channel about the warlock he rode with reaches everyone.
    assert.is_true(fake.engine:query("Dar Kbolt")); w:advance(2)
    for _, p in ipairs{lock, bo, cy} do
      assert.is_number(p.db.liars["Fak Er"], p.name)
      assert.is_nil(p.db.deaths["Dar Kbolt"], p.name)
      assert.are.equal(0, p.engine:summary("Dar Kbolt", "trust").deathsReported, p.name)
      assert.are.same({}, p.db.strikes, p.name)
    end
  end)

  it("a throwaway identity cannot mint a death a second time: one claim per victim, on any warlock", function()
    assert.is_string(fake.engine:send("RIDE_START", {rideId = id, warlock = "Dar Kbolt"}, "CHANNEL")); w:advance(1)
    local other = ns.Ride.makeId("Eve Lock", "Fak Er", math.floor(w.clock:now()))
    assert.is_string(fake.engine:send("RIDE_START", {rideId = other, warlock = "Eve Lock"}, "CHANNEL")); w:advance(1)
    for _, ride in ipairs{{id, "Dar Kbolt"}, {other, "Eve Lock"}} do
      fake.engine:send("DEATH", {rideId = ride[1], victim = "Fak Er", warlock = ride[2], secs = 10, source = "self"}, "CHANNEL")
    end
    w:advance(2)
    for _, p in ipairs{lock, bo, cy} do
      assert.is_truthy(p.db.deaths["Dar Kbolt"][id], p.name)
      assert.is_nil(p.db.deaths["Eve Lock"], p.name)
    end
  end)
end)

-- R48 again, from the other side: the real death of an honest traveler. Bli Nd
-- never gets the server's death notice, so he knows of the death from the
-- victim's own report only.
describe("a real death and the warlock's ride log (R48)", function()
  local ns, w, lock, c1, blind, t, stand, ride
  local function setup(suppress)
    ns = Taxi.load(); w = ns.World.new{seed = 37, start = 480000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan"}
    c1 = w:addPlayer{name = "Cee One", class = "PRIEST", level = 40, place = "gadgetzan"}
    blind = w:addPlayer{name = "Bli Nd", class = "ROGUE", level = 44, place = "ironforge"}
    deaf(blind)
    t = w:addPlayer{name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000}
    if suppress then suppressRideLog(lock) end
    stand = lock.engine:openStand{kind = "lock"}; w:advance(2)
    ride = rideTo(w, lock, t, stand.standId)
    w:advance(30)
    w:kill("Tra Veler"); w:advance(2)
  end
  after_each(function() assert.are.same({}, w.errors) end)

  local function death(p) return p.db.deaths["Dar Kbolt"][ride.rideId] end

  it("an honest warlock's ride log makes the victim's report heavy for an observer who did not see him die", function()
    setup(false)
    assert.are.same({true, "self"}, {death(blind).heavy, death(blind).source})
    assert.is_near(scoreOf(ns, {{1, ns.Config.RATING.W_DEATH}}), blind.engine:summary("Dar Kbolt", "trust").score, 1e-9)
    assert.are.same({true, "observed"}, {death(c1).heavy, death(c1).source})
  end)

  it("a warlock who suppresses his ride logs leaves the report light for that observer, heavy for those who saw the death", function()
    setup(true)
    assert.is_nil(blind.db.rideLogs["Dar Kbolt"])
    assert.are.same({false, "self"}, {death(blind).heavy, death(blind).source})
    local s = blind.engine:summary("Dar Kbolt", "trust")
    assert.are.same({1, true}, {s.deathsReported, s.isNew}) -- the warning is there
    assert.is_near(scoreOf(ns, {{1, ns.Config.RATING.W_ONE_SIDED}}), s.score, 1e-9)
    for _, p in ipairs{c1, lock, t} do
      assert.are.same({true, "observed"}, {death(p).heavy, death(p).source}, p.name)
      assert.is_near(scoreOf(ns, {{1, ns.Config.RATING.W_DEATH}}), p.engine:summary("Dar Kbolt", "trust").score, 1e-9, p.name)
    end
  end)

  it("the warlock's answer to a query carries the log he did not broadcast, and the light death turns heavy", function()
    setup(true)
    assert.is_false(death(blind).heavy)
    assert.is_true(blind.engine:query("Dar Kbolt")); w:advance(10)
    assert.is_truthy(blind.db.rideLogs["Dar Kbolt"][ride.rideId])
    assert.are.same({true, "self"}, {death(blind).heavy, death(blind).source})
  end)
end)

-- R52: a grouped throwaway that was never summoned forges its arrival, claims
-- its own death and goes silent, to smear an honest warlock.
describe("forged arrival", function()
  local ns, w, lock, thr, obs, stand, ride
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 11, start = 500000}
    lock = w:addPlayer{name = "Hon Lock", class = "WARLOCK", level = 50, place = "gadgetzan"}
    thr = w:addPlayer{name = "Thr Ow", class = "WARRIOR", level = 30, place = "ironforge"}
    obs = w:addPlayer{name = "Obs Erver", class = "ROGUE", level = 44, place = "ironforge"}
    stand = assert(lock.engine:openStand{kind = "lock"}); w:advance(2)
    ride = assert(thr.engine:requestRide(stand.standId, 0)); w:advance(2)
    assert.is_string(lock.engine:acceptRequest("Thr Ow#" .. stand.standId)); w:advance(2)
    assert.is_true(w:acceptInvite("Thr Ow")); w:advance(2)
    assert.are.equal("grouped", ride.state)
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  it("gets no ride log out of the warlock, so the death it claims stays light", function()
    local f = {rideId = ride.rideId, warlock = "Hon Lock"}
    thr.engine:send("ARRIVED", f, "CHANNEL"); thr.engine:send("ARRIVED", f, "WHISPER", "Hon Lock"); w:advance(3)
    assert.are.equal("grouped", lock.engine.rides["Thr Ow#" .. stand.standId].state)
    for _, p in ipairs{lock, obs} do
      assert.is_nil(p.db.rideLogs["Hon Lock"], p.name)
    end
    thr.engine:send("DEATH", {rideId = ride.rideId, victim = "Thr Ow", warlock = "Hon Lock", secs = 20,
      source = "self"}, "CHANNEL")
    w:advance(3)
    w:removePlayer("Thr Ow"); w:advance(300)
    local d = obs.db.deaths["Hon Lock"][ride.rideId]
    assert.are.same({false, "self"}, {d.heavy, d.source})
    assert.is_near(scoreOf(ns, {{1, ns.Config.RATING.W_ONE_SIDED}}), obs.engine:summary("Hon Lock", "trust").score, 1e-9)
  end)

  it("the warlock's real summon still logs the ride (control)", function()
    assert.are.equal("Thr Ow", lock.engine:nextTraveler())
    w:offerSummon("Hon Lock", "Thr Ow"); w:advance(1)
    assert.is_true(w:acceptSummon("Thr Ow")); w:advance(2)
    assert.are.equal("Thr Ow", obs.db.rideLogs["Hon Lock"][ride.rideId].traveler)
  end)
end)

-- R65: the zone a stand's message names is the sender's text; every client
-- shows and checks its own name for the stand's map instead.
describe("a stand that lies about its zone", function()
  local ns, w
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 7, start = 300000}
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  -- target gets five 5-star ratings in db, so the trust check passes.
  local function trusted(db, target, now)
    for i = 1, 5 do
      local rater = "Hap Py" .. string.char(96 + i)
      local id = ns.Ride.makeId(target, rater, now - 1000 - i)
      assert(ns.Ratings.addDirect(db, {kind = "trust", rater = rater, target = target, stars = 5,
        id = id, ts = now - 900 - i}, rater, now))
    end
  end

  -- The traveler books the stand, joins the group and is offered the summon.
  local function summoned(lock, t, stand)
    assert(t.engine:requestRide(stand.standId, 0)); w:advance(2)
    assert.is_string(lock.engine:acceptRequest(t.name .. "#" .. stand.standId)); w:advance(2)
    assert.is_true(w:acceptInvite(t.name)); w:advance(2)
    w:offerSummon(lock.name, t.name); w:advance(1)
    return last(t, "GUARD_VERDICT")[2]
  end

  it("is listed and judged at the zone of its real map, with the wire subzone as a hint", function()
    local lock = w:addPlayer{name = "Bad Lock", class = "WARLOCK", level = 50, place = "searing",
      zoneText = "Ironforge", subzoneText = "The Commons"}
    local t = w:addPlayer{name = "Tra Vel", class = "HUNTER", level = 50, place = "ironforge"}
    trusted(t.db, "Bad Lock", w.clock:now())
    local stand = assert(lock.engine:openStand{kind = "lock"}); w:advance(2)
    local view = ns.Board.get(t.engine.board, stand.standId, w.clock:now())
    assert.are.same({"Searing Gorge", "The Commons", 1427, "Ironforge"}, {view.zone, view.subzone, view.mapID, view.wireZone})
    assert.are.same({view}, ns.Board.list(t.engine.board, {zone = "Searing Gorge"}))
    assert.are.same({}, ns.Board.list(t.engine.board, {zone = "Ironforge"}))
    -- The summon goes where the list said; the guard agreed to Searing Gorge.
    local verdict = summoned(lock, t, stand)
    assert.are.equal("Destination: Searing Gorge", check(verdict, "area").text)
    assert.is_true(check(verdict, "area").ok)
    assert.is_true(w:acceptSummon("Tra Vel"))
    assert.are.equal("searing", t.place)
  end)

  it("an honest stand is GREEN for a traveler whose client names the zone in another language", function()
    local lock = w:addPlayer{name = "Hon Lock", class = "WARLOCK", level = 50, place = "ironforge"}
    local t = w:addPlayer{name = "Ute Berg", class = "HUNTER", level = 50, place = "gadgetzan", locale = "deDE"}
    trusted(t.db, "Hon Lock", w.clock:now())
    local stand = assert(lock.engine:openStand{kind = "lock"}); w:advance(2)
    local view = ns.Board.get(t.engine.board, stand.standId, w.clock:now())
    assert.are.same({"Eisenschmiede", "Ironforge"}, {view.zone, view.wireZone})
    local verdict = summoned(lock, t, stand)
    assert.are.equal("GREEN", verdict.level)
    assert.are.equal("Destination: Eisenschmiede", check(verdict, "area").text)
  end)
end)

describe("stingy warlock", function()
  local ns, w, lock, c1, c2, t, stand
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 36, start = 600000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan", money = 10000}
    c1 = w:addPlayer{name = "Cee One", class = "PRIEST", level = 40, place = "gadgetzan"}
    c2 = w:addPlayer{name = "Cee Two", class = "ROGUE", level = 40, place = "gadgetzan"}
    t = w:addPlayer{name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000}
    stand = lock.engine:openStand{kind = "lock", clickerPct = 25}
    assert.is_true(c1.engine:applyClicker(stand.standId, 25)); w:advance(2)
    assert.is_true(lock.engine:respondClicker("Cee One", "ACCEPT")); w:advance(2)
    assert.is_true(w:acceptInvite("Cee One")); w:advance(1)
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  it("a warlock who pays his clicker nothing earns a 1-star Share rating that third parties see", function()
    local ride = rideTo(w, lock, t, stand.standId); w:advance(2) -- the warlock hears ARRIVED before the trade
    assert.is_true(t.engine:submitArrival(ride.rideId, 5, 10000))
    assert.is_true(w:trade("Tra Veler", "Dar Kbolt", 10000)); w:advance(2)

    local ended = c1.engine:leaveStand()
    assert.are.same({2500, 0, 1}, {ended.owed, ended.received, ended.prefill}) -- nothing paid: prefilled 1 star
    assert.is_true(c1.engine:submitShiftRating(ended.shiftId, ended.prefill)); w:advance(2)

    local share = c2.engine:summary("Dar Kbolt", "share")
    assert.are.same({1, 1}, {share.stars, share.count})
    local rec = c2.db.ratings["Dar Kbolt"].share[1]
    assert.are.same({"Cee One", 2500, 0, 25}, {rec.rater, rec.owed, rec.received, rec.pct})
  end)
end)
