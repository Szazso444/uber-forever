describe("Reputation", function()
  local ns, w, a, b
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed=3, start=30000}
    a = w:addPlayer{name="Ana Smith", class="PRIEST", level=30, place="ironforge"}
    b = w:addPlayer{name="Bo Lee", class="MAGE", level=30, place="ironforge"}
  end)
  after_each(function() assert.are.same({}, w.errors) end) -- nothing logged (R15)
  -- Ratings.give takes the receiver's clock as its last argument (R29).
  local function rate(stars) ns.Ratings.give(a.engine.db, {kind="trust", rater="Ana Smith", target="Dar Kbolt", stars=stars, id="r1", ts=w.clock:now()}, w.clock:now())
    a.engine:send("RATING", {kind="trust", target="Dar Kbolt", stars=stars, id="r1", ts=w.clock:now()}, "CHANNEL"); w:advance(2) end
  it("rating heard live", function() rate(4); assert.are.equal(4, b.engine:summary("Dar Kbolt", "trust").stars) end)
  it("rater is always the sender", function()   -- RATING has no rater field, so nobody can rate in someone else's name
    b.engine.transport:receive("TaxiFvr", "f1:1/1:"..ns.Protocol.encode("RATING", "f1", {kind="trust", target="Dar Kbolt", stars=1, id="r9", ts=1}), "CHANNEL", "Cy Forger")
    assert.are.equal("Cy Forger", ns.Store.ratingList(b.engine.db, "Dar Kbolt", "trust")[1].rater)
  end)
  it("fresh install recovers via query as relayed", function()
    rate(4); w:removePlayer("Ana Smith")
    local c = w:addPlayer{name="Cy New", class="ROGUE", level=30, place="ironforge"}
    assert.is_true(c.engine:query("Dar Kbolt")); w:advance(8)
    local rec = ns.Store.ratingList(c.engine.db, "Dar Kbolt", "trust")[1]
    assert.are.equal("Ana Smith", rec.rater); assert.is_true(rec.via["Bo Lee"])
    local s = c.engine:summary("Dar Kbolt", "trust"); assert.are.equal(4, s.stars)
    assert.are.equal((5 * 3.5 + 0.2 * 4) / (5 + 0.2), s.score)
  end)
  it("query cooldown", function() assert.is_true(b.engine:query("Dar Kbolt")); w:advance(10); assert.is_false(b.engine:query("Dar Kbolt")); w:advance(600); assert.is_true(b.engine:query("Dar Kbolt")) end)
  it("alive evidence marks liar", function()
    a.engine:send("RIDE_START", {rideId="x", warlock="Dar Kbolt"}, "CHANNEL"); w:advance(2)
    b.engine.transport:receive("TaxiFvr", "d1:1/1:"..ns.Protocol.encode("DEATH", "d1", {rideId="x", victim="Ana Smith", warlock="Dar Kbolt", secs=10, source="self"}), "CHANNEL", "Ana Smith")
    w:advance(61); a.engine:send("REQUEST", {standId="s", offer=0, level=30}, "WHISPER", "Bo Lee"); w:advance(2)
    assert.is_truthy(b.engine.db.liars["Ana Smith"])
  end)
end)

-- Beyond the brief --------------------------------------------------------------

describe("Reputation sync", function()
  local ns, w, b, START
  before_each(function()
    ns = Taxi.load(); START = 60000; w = ns.World.new{seed = 6, start = START}
    b = w:addPlayer{name = "Bo Lee", class = "MAGE", level = 30, place = "ironforge"}
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  local function add(name, o)
    o = o or {}
    o.name = name
    o.class = o.class or "PRIEST"
    o.level = o.level or 30
    o.place = o.place or "ironforge"
    return w:addPlayer(o)
  end

  local function now() return w.clock:now() end

  -- p's engine handles a message from sender exactly as it would come off the wire.
  local function hear(p, sender, msgType, fields, dist)
    local msg = assert(ns.Protocol.decode(ns.Protocol.encode(msgType, "t1", fields)))
    p.engine:handle(msg, sender, dist or "CHANNEL")
  end

  -- Whole messages on the bus (chunks put back together), optionally only those
  -- from one sender: decoded, plus dist and to.
  local function wire(sender)
    local out, parts = {}, {}
    for _, sent in ipairs(w.bus:sent()) do
      local id, i, n, payload = sent.text:match("^([^:]+):(%d+)/(%d+):(.*)$")
      local key = sent.sender .. ":" .. id
      parts[key] = parts[key] or {}
      parts[key][tonumber(i)] = payload
      if tonumber(i) == tonumber(n) and (sender == nil or sent.sender == sender) then
        local msg = assert(ns.Protocol.decode(table.concat(parts[key], "", 1, tonumber(n))))
        msg.dist, msg.to, msg.from = sent.dist, sent.target, sent.sender
        out[#out + 1] = msg
      end
    end
    return out
  end

  local function ofType(list, msgType)
    local out = {}
    for _, m in ipairs(list) do if m.type == msgType then out[#out + 1] = m end end
    return out
  end

  local function trust(db, target) return (db.ratings[target] or {}).trust or {} end
  local function share(db, target) return (db.ratings[target] or {}).share or {} end

  describe("ratings", function()
    it("keeps a heard rating as the sender's, with its share amounts, and marks the db dirty", function()
      assert.is_false(b.engine.dirty)
      hear(b, "Cee One", "RATING", {kind = "share", target = "Dar Kbolt", stars = 2, id = "sh1", ts = now(), owed = 2500, received = 1000, pct = 25})
      local rec = share(b.engine.db, "Dar Kbolt")[1]
      assert.are.same({"Cee One", 2, 2500, 1000, 25}, {rec.rater, rec.stars, rec.owed, rec.received, rec.pct})
      assert.is_nil(rec.via)
      assert.is_true(b.engine.dirty)
    end)

    it("leaves the db clean when a rating is refused", function()
      hear(b, "Cee One", "RATING", {kind = "trust", target = "Dar Kbolt", stars = 9, id = "r1", ts = now()})
      hear(b, "Cee One", "RATING", {kind = "trust", target = "Dar Kbolt", stars = 4, id = "r1", ts = now() + 3600})
      assert.are.same({}, trust(b.engine.db, "Dar Kbolt"))
      assert.is_false(b.engine.dirty)
    end)

    it("summary reads the summary of the engine's db", function()
      hear(b, "Cee One", "RATING", {kind = "trust", target = "Dar Kbolt", stars = 2, id = "r1", ts = now()})
      assert.are.same(ns.Ratings.summary(b.engine.db, "Dar Kbolt", "trust"), b.engine:summary("Dar Kbolt", "trust"))
    end)
  end)

  describe("rides", function()
    local id
    before_each(function() id = ns.Ride.makeId("Dar Kbolt", "Tra Veler", now()) end)

    it("learns a ride from its traveler's RIDE_START and ARRIVED", function()
      hear(b, "Tra Veler", "RIDE_START", {rideId = id, warlock = "Dar Kbolt"})
      w:advance(5)
      hear(b, "Tra Veler", "ARRIVED", {rideId = id, warlock = "Dar Kbolt"})
      local ride = b.engine.witness.rides[id]
      assert.are.same({"Tra Veler", "Dar Kbolt", START}, {ride.victim, ride.warlock, ride.startTs})
      assert.is_true(math.abs(ride.arrivedTs - (START + 5)) < 1e-6)
    end)

    it("ignores a RIDE_START sent on someone else's behalf", function()
      hear(b, "Mal Ory", "RIDE_START", {rideId = id, warlock = "Dar Kbolt"})
      assert.is_nil(b.engine.witness.rides[id])
    end)

    it("files a receipt for an ARRIVED whose ride id names the warlock and the sender (R3, R28)", function()
      hear(b, "Tra Veler", "ARRIVED", {rideId = id, warlock = "Dar Kbolt"})
      assert.are.equal(START, b.engine.db.receipts["Dar Kbolt"][id])
      assert.is_true(b.engine.dirty)
      assert.are.equal(0, b.engine:summary("Dar Kbolt", "trust").count) -- the traveler's word alone (R67)
      hear(b, "Dar Kbolt", "RIDE_LOG", {rideId = id, traveler = "Tra Veler"})
      assert.are.equal(1, b.engine:summary("Dar Kbolt", "trust").count) -- both sides
    end)

    it("files no receipt for an id naming another traveler, another warlock, or no one", function()
      hear(b, "Mal Ory", "ARRIVED", {rideId = id, warlock = "Dar Kbolt"})
      hear(b, "Tra Veler", "ARRIVED", {rideId = id, warlock = "Lok Other"})
      hear(b, "Tra Veler", "ARRIVED", {rideId = "free-form", warlock = "Dar Kbolt"})
      hear(b, "Tra Veler", "ARRIVED", {rideId = "Tra Veler@Tra Veler@1", warlock = "Tra Veler"})
      assert.are.same({}, b.engine.db.receipts)
      assert.is_false(b.engine.dirty)
    end)

    it("keeps the warlock's RIDE_LOG when the ride id names the warlock and the traveler", function()
      hear(b, "Dar Kbolt", "RIDE_LOG", {rideId = id, traveler = "Tra Veler"})
      assert.are.same({ts = START, traveler = "Tra Veler"}, b.engine.db.rideLogs["Dar Kbolt"][id])
      assert.is_true(b.engine.dirty)
    end)

    it("ignores a RIDE_LOG whose ride id names someone else", function()
      hear(b, "Mal Ory", "RIDE_LOG", {rideId = id, traveler = "Tra Veler"})
      hear(b, "Dar Kbolt", "RIDE_LOG", {rideId = id, traveler = "Alt Ernate"})
      hear(b, "Dar Kbolt", "RIDE_LOG", {rideId = "free-form", traveler = "Tra Veler"})
      assert.are.same({}, b.engine.db.rideLogs)
    end)
  end)

  describe("answering queries", function()
    local function rated(p, rater, stars)
      assert.is_true(ns.Ratings.addDirect(p.engine.db, {kind = "trust", rater = rater, target = "Dar Kbolt", stars = stars,
        id = rater .. "-r", ts = now()}, rater, now()))
    end

    it("whispers the reply after rng() * QUERY_JITTER seconds", function()
      local arrivals = {}
      ns.Engine.handlers.QUERY_R = function(e, msg, sender, dist) arrivals[#arrivals + 1] = {e.me, sender, dist, now(), #msg.records} end
      local c = add("Cy New")
      rated(b, "Ana Smith", 4)
      b.engine.rng = function() return 0.8 end
      c.engine:query("Dar Kbolt")
      w:advance(10)
      assert.are.equal(1, #arrivals)
      assert.are.same({"Cy New", "Bo Lee", "WHISPER"}, {arrivals[1][1], arrivals[1][2], arrivals[1][3]})
      local delay = arrivals[1][4] - START
      assert.is_true(delay >= 4 and delay <= 4.8, "delay " .. delay)
      assert.are.equal(1, arrivals[1][5])
    end)

    it("does not reply with nothing to tell", function()
      local c = add("Cy New")
      c.engine:query("Dar Kbolt")
      w:advance(10)
      assert.are.same({}, ofType(wire(), "QUERY_R"))
    end)

    it("answers one asker about one warlock once per QUERY_COOLDOWN", function()
      local apart = ns.Config.QUERY_REPLY_INTERVAL + ns.Config.QUERY_JITTER + 1 -- past the reply rate limit (R68)
      rated(b, "Ana Smith", 4)
      hear(b, "Cy New", "QUERY", {target = "Dar Kbolt"})
      hear(b, "Cy New", "QUERY", {target = "Dar Kbolt"})
      w:advance(apart)
      hear(b, "Di Other", "QUERY", {target = "Dar Kbolt"})
      w:advance(apart)
      local replies = ofType(wire("Bo Lee"), "QUERY_R")
      assert.are.same({"Cy New", "Di Other"}, {replies[1].to, replies[2].to})
      assert.are.equal(2, #replies)
      w:advance(ns.Config.QUERY_COOLDOWN)
      hear(b, "Cy New", "QUERY", {target = "Dar Kbolt"})
      w:advance(apart)
      assert.are.equal(3, #ofType(wire("Bo Lee"), "QUERY_R"))
    end)

    it("sends at most one reply per QUERY_REPLY_INTERVAL, and drops the others (R68)", function()
      assert.are.equal(10, ns.Config.QUERY_REPLY_INTERVAL)
      rated(b, "Ana Smith", 4)
      for i = 1, 5 do
        hear(b, "Ask Er" .. string.char(96 + i), "QUERY", {target = "Dar Kbolt"})
      end
      w:advance(ns.Config.QUERY_JITTER + 1)
      assert.are.equal(1, #ofType(wire("Bo Lee"), "QUERY_R"))
      w:advance(60)
      assert.are.equal(1, #ofType(wire("Bo Lee"), "QUERY_R")) -- dropped, not sent later
      assert.are.equal(0, b.transport:queuedMessages("QUERY_R"))
      hear(b, "Ask Erz", "QUERY", {target = "Dar Kbolt"})
      w:advance(ns.Config.QUERY_JITTER + 1)
      assert.are.equal(2, #ofType(wire("Bo Lee"), "QUERY_R"))
    end)

    it("keeps at most QUERY_MAX_QUEUED replies waiting to go out, and drops the others (R68)", function()
      assert.are.equal(2, ns.Config.QUERY_MAX_QUEUED)
      ns.Config.QUERY_REPLY_INTERVAL = 0 -- the queue cap alone
      rated(b, "Ana Smith", 4)
      w.bus:setLockdown("Bo Lee", true) -- nothing goes out for now
      for i = 1, 5 do
        hear(b, "Ask Er" .. string.char(96 + i), "QUERY", {target = "Dar Kbolt"})
      end
      w:advance(ns.Config.QUERY_JITTER + 1)
      assert.are.equal(2, b.transport:queuedMessages("QUERY_R"))
      w.bus:setLockdown("Bo Lee", false)
      w:advance(5)
      assert.are.equal(2, #ofType(wire("Bo Lee"), "QUERY_R"))
    end)

    it("fits a long history into one reply, newest first", function()
      local c = add("Cy New")
      for i = 1, 60 do
        local rater = "Clickerwithalongname Surnamewithlength" .. i
        assert.is_true(ns.Ratings.addDirect(b.engine.db, {kind = "share", rater = rater, target = "Dar Kbolt", stars = 3,
          id = "Dar Kbolt@" .. rater .. "@" .. (START - 100 + i), ts = START - 100 + i, owed = 25000, received = 25000, pct = 25}, rater, now()))
      end
      c.engine:query("Dar Kbolt")
      w:advance(30)
      local replies = ofType(wire("Bo Lee"), "QUERY_R")
      assert.are.equal(1, #replies)
      local records = replies[1].records
      assert.is_true(#records >= 20 and #records < 50, "records " .. #records)
      assert.are.equal("Clickerwithalongname Surnamewithlength60", records[1].rater)
      assert.are.equal(#records, #share(c.engine.db, "Dar Kbolt"))
    end)

    it("the warlock's own reply carries its ride logs, kept as its logs", function()
      local lock = add("Dar Kbolt", {class = "WARLOCK", level = 45})
      local c = add("Cy New")
      local id = ns.Ride.makeId("Dar Kbolt", "Tra Veler", START - 50)
      assert.is_true(ns.Ratings.addRideLog(lock.engine.db, "Dar Kbolt", id, START - 50, "Tra Veler", now()))
      c.engine:query("Dar Kbolt")
      w:advance(10)
      assert.are.same({ts = START - 50, traveler = "Tra Veler"}, c.engine.db.rideLogs["Dar Kbolt"][id])
    end)
  end)

  describe("using replies", function()
    local c
    before_each(function() c = add("Cy New") end)

    local function record(i, extra)
      local r = {kind = "trust", rater = "Rat Er" .. i, stars = 4, id = "r" .. i, ts = now()}
      for k, v in pairs(extra or {}) do r[k] = v end
      return r
    end

    it("ignores a reply to a query that was never sent", function()
      hear(c, "Bo Lee", "QUERY_R", {target = "Dar Kbolt", records = {record(1)}}, "WHISPER")
      assert.are.same({}, trust(c.engine.db, "Dar Kbolt"))
    end)

    it("ignores replies after the query window closes", function()
      c.engine:query("Dar Kbolt")
      w:advance(ns.Config.QUERY_COOLDOWN)
      hear(c, "Bo Lee", "QUERY_R", {target = "Dar Kbolt", records = {record(1)}}, "WHISPER")
      assert.are.same({}, trust(c.engine.db, "Dar Kbolt"))
    end)

    it("keeps a relayed record with the replier as relayer, and the rater's own as direct", function()
      c.engine:query("Dar Kbolt")
      hear(c, "Bo Lee", "QUERY_R", {target = "Dar Kbolt", records = {record(1), record(2, {rater = "Bo Lee"})}}, "WHISPER")
      local list = trust(c.engine.db, "Dar Kbolt")
      assert.are.equal(2, #list)
      assert.are.same({["Bo Lee"] = true}, list[1].via)
      assert.are.equal("Bo Lee", list[2].rater)
      assert.is_nil(list[2].via)
      assert.is_true(c.engine.dirty)
    end)

    it("uses at most QUERY_MAX_REPLIES replies per query", function()
      c.engine:query("Dar Kbolt")
      for i = 1, ns.Config.QUERY_MAX_REPLIES + 1 do
        hear(c, "Rel Ayer" .. i, "QUERY_R", {target = "Dar Kbolt", records = {record(i)}}, "WHISPER")
      end
      assert.are.equal(ns.Config.QUERY_MAX_REPLIES, #trust(c.engine.db, "Dar Kbolt"))
    end)

    it("uses one reply per replier per query", function()
      c.engine:query("Dar Kbolt")
      hear(c, "Bo Lee", "QUERY_R", {target = "Dar Kbolt", records = {record(1)}}, "WHISPER")
      hear(c, "Bo Lee", "QUERY_R", {target = "Dar Kbolt", records = {record(2)}}, "WHISPER")
      assert.are.equal(1, #trust(c.engine.db, "Dar Kbolt"))
    end)

    it("uses at most QUERY_MAX_RECORDS records of a reply (R14)", function()
      c.engine:query("Dar Kbolt")
      local records = {}
      for i = 1, ns.Config.QUERY_MAX_RECORDS + 10 do records[i] = record(i) end
      c.engine:handle({type = "QUERY_R", msgId = "m1", v = 1, target = "Dar Kbolt", records = records}, "Bo Lee", "WHISPER")
      assert.are.equal(ns.Config.QUERY_MAX_RECORDS, #trust(c.engine.db, "Dar Kbolt"))
    end)

    it("takes ride logs only from the warlock about itself", function()
      local id = ns.Ride.makeId("Dar Kbolt", "Tra Veler", START)
      c.engine:query("Dar Kbolt")
      hear(c, "Bo Lee", "QUERY_R", {target = "Dar Kbolt", records = {
        {kind = "ridelog", rater = "Bo Lee", id = id, ts = START, other = "Tra Veler"},
        {kind = "ridelog", rater = "Dar Kbolt", id = id, ts = START, other = "Tra Veler"},
      }}, "WHISPER")
      assert.are.same({}, c.engine.db.rideLogs)
    end)
  end)

  describe("deaths", function()
    local id
    before_each(function() id = ns.Ride.makeId("Dar Kbolt", "Vic Tim", now()) end)

    -- The observer heard the victim's ride start and arrival.
    local function rode(p)
      hear(p, "Vic Tim", "RIDE_START", {rideId = id, warlock = "Dar Kbolt"})
      hear(p, "Vic Tim", "ARRIVED", {rideId = id, warlock = "Dar Kbolt"})
    end

    -- A Hardcore victim who arrived on Dar Kbolt's ride a moment ago.
    local function victim()
      local v = add("Vic Tim")
      v.engine.witness:rideStarted(id, "Vic Tim", "Dar Kbolt", now(), "Vic Tim")
      v.engine.witness:arrived(id, "Vic Tim", now(), "Vic Tim")
      return v
    end

    local function deathsFrom(name)
      return ofType(wire(name), "DEATH")
    end

    it("the player's own death is reported while the engine is muted for /taxi sim (R62)", function()
      local v = victim()
      v.engine:mute(true)
      w:advance(5)
      v.dead = true
      v.engine:onGame("PLAYER_DIED")
      w:advance(2)
      local sent = deathsFrom("Vic Tim")
      assert.are.equal(1, #sent)
      assert.are.same({id, "Vic Tim", "Dar Kbolt", "self"}, {sent[1].rideId, sent[1].victim, sent[1].warlock, sent[1].source})
    end)

    it("a death report already queued survives the sim muting the engine just after it (R62)", function()
      local v = victim()
      w:advance(5)
      v.dead = true
      v.engine:onGame("PLAYER_DIED") -- the DEATH is queued, not yet on the bus
      v.engine:mute(true)
      w:advance(2)
      assert.are.equal(1, #deathsFrom("Vic Tim"))
    end)

    it("an HC_DEATH within the window after arrival is a heavy observed death", function()
      rode(b)
      w:advance(30)
      b.engine:onGame("HC_DEATH", "Vic Tim")
      local d = b.engine.db.deaths["Dar Kbolt"][id]
      assert.are.same({true, "observed", "Vic Tim"}, {d.heavy, d.source, d.victim})
      assert.is_true(b.engine.dirty)
    end)

    it("an HC_DEATH after the window records nothing", function()
      rode(b)
      w:advance(ns.Config.DEATH_WINDOW + 1)
      b.engine:onGame("HC_DEATH", "Vic Tim")
      assert.is_nil(b.engine.db.deaths["Dar Kbolt"])
    end)

    it("ignores an HC_DEATH naming the player itself", function()
      local v = add("Vic Tim")
      v.engine.witness:rideStarted(id, "Vic Tim", "Dar Kbolt", now(), "Vic Tim")
      v.engine.witness:arrived(id, "Vic Tim", now(), "Vic Tim")
      v.engine:onGame("HC_DEATH", "Vic Tim")
      assert.is_nil(v.engine.db.deaths["Dar Kbolt"])
    end)

    it("does not use MEMBER_DIED (R36)", function()
      rode(b)
      b.engine:onGame("MEMBER_DIED", "Vic Tim")
      assert.is_nil(b.engine.db.deaths["Dar Kbolt"])
    end)

    it("records no deaths and sees no liars outside Hardcore (R35)", function()
      local soft = add("Sof Tee", {hardcore = false})
      rode(soft)
      soft.engine:onGame("HC_DEATH", "Vic Tim")
      hear(soft, "Vic Tim", "DEATH", {rideId = id, victim = "Vic Tim", warlock = "Dar Kbolt", secs = 5, source = "self"})
      soft.engine:query("Dar Kbolt")
      hear(soft, "Bo Lee", "QUERY_R", {target = "Dar Kbolt", records = {{kind = "death", rater = "Vic Tim", id = id, ts = now(), other = "Vic Tim"}}}, "WHISPER")
      assert.are.same({}, soft.engine.db.deaths)
      -- A self-reported death on file (from a Hardcore session on this account, say)
      -- is not taken back on this ruleset either.
      assert.is_not_nil(soft.engine.witness:deathReported({rideId = id, victim = "Vic Tim", warlock = "Dar Kbolt", secs = 5}, "Vic Tim", now()))
      w:advance(ns.Config.ALIVE_GRACE + 1)
      hear(soft, "Vic Tim", "QUERY", {target = "Zed Zed"})
      assert.are.same({}, soft.engine.db.liars)
      soft.engine:onGame("PLAYER_DIED")
      assert.are.same({}, ofType(wire("Sof Tee"), "DEATH"))
    end)

    local function died(p, secs)
      hear(p, "Vic Tim", "DEATH", {rideId = id, victim = "Vic Tim", warlock = "Dar Kbolt", secs = secs or 5, source = "self"})
    end

    it("a victim's own DEATH is a light death with source self until the warlock's RIDE_LOG backs it (R48)", function()
      hear(b, "Vic Tim", "RIDE_START", {rideId = id, warlock = "Dar Kbolt"})
      died(b)
      local d = b.engine.db.deaths["Dar Kbolt"][id]
      assert.are.same({false, "self", nil}, {d.heavy, d.source, d.via})
      assert.is_true(b.engine.dirty)
      b.engine.dirty = false
      -- A log that does not name the ride's traveler is refused: nothing changes.
      hear(b, "Dar Kbolt", "RIDE_LOG", {rideId = id, traveler = "Mal Ory"})
      assert.is_false(b.engine.db.deaths["Dar Kbolt"][id].heavy)
      -- The warlock's log naming the victim backs the report: the death is heavy now.
      hear(b, "Dar Kbolt", "RIDE_LOG", {rideId = id, traveler = "Vic Tim"})
      d = b.engine.db.deaths["Dar Kbolt"][id]
      assert.are.same({true, "self"}, {d.heavy, d.source})
      assert.is_true(b.engine.dirty)
      assert.are.equal(1, b.engine:summary("Dar Kbolt", "trust").deathsReported)
    end)

    it("a DEATH that follows the warlock's RIDE_LOG is heavy at once (R48)", function()
      hear(b, "Vic Tim", "RIDE_START", {rideId = id, warlock = "Dar Kbolt"})
      hear(b, "Dar Kbolt", "RIDE_LOG", {rideId = id, traveler = "Vic Tim"})
      died(b)
      assert.are.same({true, "self"}, {b.engine.db.deaths["Dar Kbolt"][id].heavy, b.engine.db.deaths["Dar Kbolt"][id].source})
    end)

    it("a ride log in the warlock's own query reply backs the death too (R48)", function()
      hear(b, "Vic Tim", "RIDE_START", {rideId = id, warlock = "Dar Kbolt"})
      died(b)
      assert.is_true(b.engine:query("Dar Kbolt"))
      hear(b, "Bo Lee", "QUERY_R", {target = "Dar Kbolt", records = {
        {kind = "ridelog", rater = "Bo Lee", id = id, ts = now(), other = "Vic Tim"},   -- not the warlock's own
      }}, "WHISPER")
      assert.is_false(b.engine.db.deaths["Dar Kbolt"][id].heavy)
      hear(b, "Dar Kbolt", "QUERY_R", {target = "Dar Kbolt", records = {
        {kind = "ridelog", rater = "Dar Kbolt", id = id, ts = now(), other = "Vic Tim"},
      }}, "WHISPER")
      assert.is_true(b.engine.db.deaths["Dar Kbolt"][id].heavy)
    end)

    it("a victim's own report is never heavy by itself: a silent throwaway identity moves the score by W_ONE_SIDED (R48)", function()
      hear(b, "Vic Tim", "RIDE_START", {rideId = id, warlock = "Dar Kbolt"})
      died(b)
      local s = b.engine:summary("Dar Kbolt", "trust")
      assert.are.equal(1, s.deathsReported)
      assert.is_true(s.isNew)
      assert.is_true(math.abs(s.score - (5 * 3.5 + 0.3) / (5 + 0.3)) < 1e-9)
    end)

    it("a DEATH message is not proof of life; any other message is (R37)", function()
      hear(b, "Vic Tim", "RIDE_START", {rideId = id, warlock = "Dar Kbolt"})
      hear(b, "Dar Kbolt", "RIDE_LOG", {rideId = id, traveler = "Vic Tim"})
      hear(b, "Vic Tim", "DEATH", {rideId = id, victim = "Vic Tim", warlock = "Dar Kbolt", secs = 5, source = "self"})
      assert.is_true(b.engine.db.deaths["Dar Kbolt"][id].heavy)
      w:advance(ns.Config.ALIVE_GRACE + 1)
      hear(b, "Vic Tim", "DEATH", {rideId = id, victim = "Vic Tim", warlock = "Dar Kbolt", secs = 5, source = "self"})
      assert.are.same({}, b.engine.db.liars)
      hear(b, "Vic Tim", "QUERY", {target = "Zed Zed"})
      assert.is_truthy(b.engine.db.liars["Vic Tim"])
      assert.is_nil(b.engine.db.deaths["Dar Kbolt"])
    end)

    -- Vic announces his ride and arrives, recording both in his own witness the
    -- way the traveler side does (his channel messages never come back to him).
    local function onOwnRide(v)
      v.engine.witness:rideStarted(id, "Vic Tim", "Dar Kbolt", now(), "Vic Tim")
      v.engine:send("RIDE_START", {rideId = id, warlock = "Dar Kbolt"}, "CHANNEL")
      w:advance(2)
      v.engine.witness:arrived(id, "Vic Tim", now(), "Vic Tim")
      v.engine:send("ARRIVED", {rideId = id, warlock = "Dar Kbolt"}, "CHANNEL")
      w:advance(2)
    end

    it("my death off Hardcore sends no DEATH, keeps my queue and lets me go on sending (R35)", function()
      local v = add("Vic Tim", {hardcore = false})
      onOwnRide(v)
      local before = #wire("Vic Tim")
      for i = 1, 5 do v.engine:send("QUERY", {target = "Que Ry" .. i}, "CHANNEL") end
      w:kill("Vic Tim")
      assert.is_true(v.game:isDead())
      assert.are.equal(5, v.engine.transport:queued())
      assert.is_string(v.engine:send("QUERY", {target = "Aft Er"}, "CHANNEL"))
      w:advance(10)
      local after = wire("Vic Tim")
      assert.are.equal(before + 6, #after)
      assert.are.same({}, ofType(after, "DEATH"))
      assert.are.same({}, v.engine.db.deaths)
      assert.is_true(v.engine:query("Dar Kbolt"))
    end)

    it("my own death on Hardcore sends DEATH{source=\"self\"}, drops my queue and silences me (R37)", function()
      local v = add("Vic Tim")
      onOwnRide(v)
      local before = #wire("Vic Tim")
      for i = 1, 5 do v.engine:send("QUERY", {target = "Que Ry" .. i}, "CHANNEL") end
      w:kill("Vic Tim")
      assert.are.equal(1, v.engine.transport:queued()) -- the DEATH report alone
      w:advance(5)
      local after = wire("Vic Tim")
      assert.are.equal(before + 1, #after)
      local death = after[#after]
      assert.are.same({"DEATH", id, "Vic Tim", "Dar Kbolt", "self", "CHANNEL"},
        {death.type, death.rideId, death.victim, death.warlock, death.source, death.dist})
      assert.is_true(death.secs >= 0 and death.secs <= 3)
      assert.is_true(v.engine.dirty)
      assert.are.same({nil, "dead"}, {v.engine:send("QUERY", {target = "Que Ry"}, "CHANNEL")})
      assert.is_false(v.engine:query("Dar Kbolt"))
      -- Bo saw it twice over: the server's notice and Vic's own report.
      local d = b.engine.db.deaths["Dar Kbolt"][id]
      assert.are.same({true, "observed"}, {d.heavy, d.source})
    end)

    it("dying off a ride sends nothing at all", function()
      local v = add("Vic Tim")
      v.engine:send("QUERY", {target = "Que Ry"}, "CHANNEL")
      w:kill("Vic Tim")
      w:advance(5)
      assert.are.same({}, wire("Vic Tim"))
    end)

    it("takes a death from a reply through the witness, so the relayer is struck when the victim lives (R38)", function()
      rode(b)
      w:advance(30)
      b.engine:onGame("HC_DEATH", "Vic Tim")
      local c = add("Cy New")
      c.engine:query("Dar Kbolt")
      w:advance(10)
      local d = c.engine.db.deaths["Dar Kbolt"][id]
      assert.are.same({false, "relayed", {["Bo Lee"] = true}}, {d.heavy, d.source, d.via})
      w:advance(ns.Config.ALIVE_GRACE)
      hear(c, "Vic Tim", "QUERY", {target = "Zed Zed"})
      assert.are.equal(1, c.engine.db.strikes["Bo Lee"])
      assert.is_nil(c.engine.db.deaths["Dar Kbolt"])
      assert.is_true(b.engine.db.deaths["Dar Kbolt"][id].heavy) -- Bo's own sighting is never undone
    end)
  end)

  it("query returns false while the channel is down", function()
    local off = add("Off Line", {channelsFull = true})
    assert.is_false(off.engine:query("Dar Kbolt"))
  end)
end)
