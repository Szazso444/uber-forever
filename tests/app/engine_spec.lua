describe("Engine", function()
  local ns, world
  before_each(function() ns = Taxi.load(); world = ns.World.new{seed=1, start=10000} end)
  after_each(function() assert.are.same({}, world.errors) end) -- nothing logged (R15)
  it("channel join failure disables actions", function()                         -- Review Focus 4
    local p = world:addPlayer{name="Ana Smith", class="PRIEST", level=30, place="ironforge", channelsFull=true}
    assert.is_true(p.engine.disabled); assert.are.equal("STATUS", p.events[1][1]); assert.are.equal("STATUS_CHANNEL_FULL", p.events[1][2])
    assert.are.same({nil, "disabled"}, {p.engine:requestRide("s1", 0)})
  end)
  it("update available once", function()
    local p = world:addPlayer{name="Ana Smith", class="PRIEST", level=30, place="ironforge"}
    p.engine.transport:receive("TaxiFvr", "ab:1/1:2^STAND^ab", "CHANNEL", "Bo Lee")
    p.engine.transport:receive("TaxiFvr", "ac:1/1:2^STAND^ac", "CHANNEL", "Bo Lee")
    local n = 0; for _, ev in ipairs(p.events) do if ev[2] == "STATUS_UPDATE" then n = n + 1 end end; assert.are.equal(1, n)
  end)
end)

-- Beyond the brief --------------------------------------------------------------

describe("Engine core", function()
  local ns, w
  before_each(function() ns = Taxi.load(); w = ns.World.new{seed = 4, start = 40000} end)

  local function add(name, o)
    o = o or {}
    o.name = name
    o.class = o.class or "PRIEST"
    o.level = o.level or 30
    o.place = o.place or "ironforge"
    return w:addPlayer(o)
  end

  -- p's engine handles a message from sender exactly as it would come off the wire.
  local function hear(p, sender, msgType, fields, dist)
    local msg = assert(ns.Protocol.decode(ns.Protocol.encode(msgType, "t1", fields)))
    p.engine:handle(msg, sender, dist or "CHANNEL")
  end

  -- The events p's engine emitted with this name.
  local function emitted(p, event)
    local out = {}
    for _, ev in ipairs(p.events) do
      if ev[1] == event then out[#out + 1] = ev end
    end
    return out
  end

  -- Decoded single-chunk messages on the bus, optionally only from one sender.
  local function wire(sender)
    local out = {}
    for _, sent in ipairs(w.bus:sent()) do
      local text = sent.text:match("^[^:]+:1/1:(.*)$")
      if text and (sender == nil or sent.sender == sender) then
        local msg = ns.Protocol.decode(text)
        msg.dist, msg.to = sent.dist, sent.target
        out[#out + 1] = msg
      end
    end
    return out
  end

  local function stand(id, extra)
    local f = {standId = id, kind = "lock", faction = "Alliance", mapID = 1446, x = 0.5, y = 0.5, wx = 5000, wy = 5000,
      zone = "Tanaris", subzone = "Gadgetzan", seatsFree = 3, clickers = 2, clickerPct = 25, portals = {}, note = "hi"}
    for k, v in pairs(extra or {}) do f[k] = v end
    return f
  end

  it("has the status strings", function()
    assert.are.equal("Taxi needs a free chat channel. Leave one (e.g. /leave 5) and /reload.", rawget(ns.L, "STATUS_CHANNEL_FULL"))
    assert.are.equal("Paused (instance)", rawget(ns.L, "STATUS_LOCKDOWN"))
    assert.are.equal("A newer Taxi version is in use. Please update.", rawget(ns.L, "STATUS_UPDATE"))
  end)

  it("starts with its state tables and the player's name", function()
    local p = add("Ana Smith")
    local e = p.engine
    assert.are.equal("Ana Smith", e.me)
    assert.are.same({}, ns.Board.list(e.board))
    assert.are.same({}, e.rides)
    assert.are.same({}, e.ledgers)
    assert.is_nil(e.stand)
    assert.is_table(e.witness)
    assert.is_false(e.dirty)
    assert.are.equal(p.db, e.db)
    assert.are.equal(p.charDb, e.charDb)
  end)

  describe("dispatch", function()
    after_each(function() assert.are.same({}, w.errors) end)

    it("runs every handler registered for a type, in the order they were registered", function()
      local calls = {}
      ns.Engine.handlers.TIP = function(e, msg, sender, dist) calls[#calls + 1] = {"first", e.me, msg.rideId, msg.amount, sender, dist} end
      ns.Engine.handlers.TIP = function() calls[#calls + 1] = {"second"} end
      local p = add("Ana Smith")
      hear(p, "Bo Lee", "TIP", {rideId = "r1", amount = 500}, "PARTY")
      assert.are.same({{"first", "Ana Smith", "r1", 500, "Bo Lee", "PARTY"}, {"second"}}, calls)
    end)

    it("runs every game handler for an event, with the event's arguments", function()
      local calls = {}
      ns.Engine.gameHandlers.TRADE_DONE = function(e, partner, gave, got) calls[#calls + 1] = {e.me, partner, gave, got} end
      ns.Engine.gameHandlers.TRADE_DONE = function() calls[#calls + 1] = {"second"} end
      local p = add("Ana Smith")
      p.engine:onGame("TRADE_DONE", "Bo Lee", 0, 500)
      p.engine:onGame("NO_SUCH_EVENT", 1)
      assert.are.same({{"Ana Smith", "Bo Lee", 0, 500}, {"second"}}, calls)
    end)

    it("refuses a handler that is not a function", function()
      assert.has_error(function() ns.Engine.handlers.TIP = "oops" end)
      assert.has_error(function() ns.Engine.gameHandlers.MOVED = 42 end)
    end)

    it("drops a message missing a required field before any handler runs (R13)", function()
      local calls = 0
      ns.Engine.handlers.TIP = function() calls = calls + 1 end
      ns.Engine.handlers.DECLINE = function() calls = calls + 1 end
      local p = add("Ana Smith")
      hear(p, "Bo Lee", "TIP", {rideId = "r1"}, "PARTY")
      hear(p, "Bo Lee", "STAND", stand("Bo Lee@40000", {zone = ""}))
      assert.are.equal(0, calls)
      assert.is_nil(ns.Board.get(p.engine.board, "Bo Lee@40000"))
      hear(p, "Bo Lee", "DECLINE", {standId = "s1"}, "WHISPER") -- the reason is optional
      assert.are.equal(1, calls)
      hear(p, "Bo Lee", "STAND", stand("Bo Lee@40000")) -- with its zone, the same stand is taken
      assert.is_not_nil(ns.Board.get(p.engine.board, "Bo Lee@40000"))
    end)

    it("takes a STAND without a status, as a paused one (R69)", function()
      local p = add("Ana Smith")
      hear(p, "Bo Lee", "STAND", stand("Bo Lee@40000"))
      assert.are.equal("paused", ns.Board.get(p.engine.board, "Bo Lee@40000").status)
      hear(p, "Bo Lee", "STAND", stand("Bo Lee@40000", {status = "live"}))
      assert.are.equal("live", ns.Board.get(p.engine.board, "Bo Lee@40000").status)
    end)

    it("has a REQUIRED entry for every protocol type, naming fields of its schema only", function()
      for msgType, schema in pairs(ns.Protocol.SCHEMAS) do
        local required = ns.Engine.REQUIRED[msgType]
        assert.is_table(required, msgType)
        local fields = {}
        for _, field in ipairs(schema) do fields[field[1]] = true end
        for _, name in ipairs(required) do assert.is_true(fields[name], msgType .. "." .. name) end
      end
      for msgType in pairs(ns.Engine.REQUIRED) do assert.is_table(ns.Protocol.SCHEMAS[msgType], msgType) end
    end)

    it("ignores the player's own messages", function()
      local calls = 0
      ns.Engine.handlers.TIP = function() calls = calls + 1 end
      local p = add("Ana Smith")
      hear(p, "Ana Smith", "TIP", {rideId = "r1", amount = 5}, "PARTY")
      hear(p, " Ana  Smith ", "STAND", stand("Ana Smith@40000"))
      assert.are.equal(0, calls)
      assert.is_nil(ns.Board.get(p.engine.board, "Ana Smith@40000"))
    end)

    it("takes messages off the wire with the sender the server stamped", function()
      local heard = {}
      ns.Engine.handlers.TIP = function(_, msg, sender, dist) heard[#heard + 1] = {msg.amount, sender, dist} end
      local a = add("Ana Smith")
      add("Bo Lee")
      a.game:invite("Bo Lee"); w:acceptInvite("Bo Lee")
      a.engine:send("TIP", {rideId = "r1", amount = 700}, "PARTY")
      w:advance(1)
      assert.are.same({{700, "Ana Smith", "PARTY"}}, heard) -- Bo heard it; Ana never hears herself
    end)
  end)

  describe("errors (R15)", function()
    it("logs a raising handler and still runs the others", function()
      local calls = 0
      ns.Engine.handlers.TIP = function() error("boom") end
      ns.Engine.handlers.TIP = function() calls = calls + 1 end
      local p = add("Ana Smith")
      hear(p, "Bo Lee", "TIP", {rideId = "r1", amount = 5}, "PARTY")
      assert.are.equal(1, calls)
      assert.are.equal(1, #w.errors)
      assert.is_truthy(w.errors[1]:find("Ana Smith", 1, true))
      assert.is_truthy(w.errors[1]:find("TIP", 1, true))
      assert.is_truthy(w.errors[1]:find("boom", 1, true))
    end)

    it("logs a raising game handler and still runs the others", function()
      local calls = 0
      ns.Engine.gameHandlers.COMBAT_CHANGED = function() error("bang") end
      ns.Engine.gameHandlers.COMBAT_CHANGED = function() calls = calls + 1 end
      local p = add("Ana Smith")
      assert.has_no.errors(function() p.engine:onGame("COMBAT_CHANGED", "Ana Smith", true) end)
      assert.are.equal(1, calls)
      assert.are.equal(1, #w.errors)
      assert.is_truthy(w.errors[1]:find("bang", 1, true))
    end)

    it("logs a raising listener without stopping the other listeners or the handler", function()
      local p = add("Ana Smith")
      local heard = 0
      p.engine:on("BOARD_CHANGED", function() error("ui bug") end)
      p.engine:on("BOARD_CHANGED", function() heard = heard + 1 end)
      hear(p, "Bo Lee", "STAND", stand("Bo Lee@40000"))
      assert.are.equal(1, heard)
      assert.is_not_nil(ns.Board.get(p.engine.board, "Bo Lee@40000"))
      assert.are.equal(1, #w.errors)
      assert.is_truthy(w.errors[1]:find("ui bug", 1, true))
    end)

    it("keeps the clock and the transport going after a handler raises", function()
      local amounts = {}
      ns.Engine.handlers.TIP = function(_, msg) if msg.amount == 1 then error("first one") end amounts[#amounts + 1] = msg.amount end
      local a = add("Ana Smith")
      add("Bo Lee")
      a.game:invite("Bo Lee"); w:acceptInvite("Bo Lee")
      a.engine:send("TIP", {rideId = "r1", amount = 1}, "PARTY")
      a.engine:send("TIP", {rideId = "r2", amount = 2}, "PARTY")
      assert.has_no.errors(function() w:advance(2) end)
      assert.are.same({2}, amounts)
      assert.are.equal(1, #w.errors)
    end)

    it("discards errors when no log sink is given", function()
      ns.Engine.handlers.TIP = function() error("nobody listens") end
      local p = add("Ana Smith")
      local quiet = ns.Engine.new{game = p.game, clock = w.clock, db = ns.Store.init(nil),
        transport = ns.Transport.new{backend = {send = function() return 0 end, inLockdown = function() return false end},
          clock = w.clock, prefix = "TaxiFvr"}}
      local msg = ns.Protocol.decode(ns.Protocol.encode("TIP", "m1", {rideId = "r1", amount = 5}))
      assert.has_no.errors(function() quiet:handle(msg, "Bo Lee", "PARTY") end)
      assert.are.same({}, w.errors)
    end)
  end)

  describe("events", function()
    it("on and emit pass every argument to the listeners", function()
      local p = add("Ana Smith")
      local got
      p.engine:on("RIDE_CHANGED", function(...) got = {...} end)
      p.engine:emit("RIDE_CHANGED", "a", 2, false)
      assert.are.same({"a", 2, false}, got)
      assert.are.same({"RIDE_CHANGED", "a", 2, false}, p.events[#p.events])
    end)
  end)

  describe("start and sending", function()
    after_each(function() assert.are.same({}, w.errors) end)

    it("joins the channel and emits nothing on a normal start", function()
      local p = add("Ana Smith")
      assert.is_false(p.engine.disabled)
      assert.are.same({}, p.events)
    end)

    it("pumps its transport on its own", function()
      local p = add("Ana Smith")
      add("Bo Lee")
      p.engine:send("QUERY", {target = "Dar Kbolt"}, "CHANNEL")
      w.clock:advance(0.3) -- the clock alone: no World pumping
      assert.are.equal(1, #w.bus:sent())
    end)

    it("send returns the transport's msgId", function()
      local p = add("Ana Smith")
      assert.is_string(p.engine:send("QUERY", {target = "Dar Kbolt"}, "CHANNEL"))
    end)

    it("a muted engine (the UI's /taxi sim) sends nothing, drops what was queued, and sends again when unmuted", function()
      local p = add("Ana Smith")
      add("Bo Lee")
      assert.is_string(p.engine:send("QUERY", {target = "Dar Kbolt"}, "CHANNEL")) -- queued, not yet sent
      p.engine:mute(true)
      assert.are.same({nil, "muted"}, {p.engine:send("QUERY", {target = "Dar Kbolt"}, "CHANNEL")})
      assert.are.same({nil, "muted"}, {p.engine:send("QUERY", {target = "Dar Kbolt"}, "WHISPER", "Bo Lee")})
      w:advance(2)
      assert.are.equal(0, #w.bus:sent())
      p.engine:mute(false)
      assert.is_string(p.engine:send("QUERY", {target = "Dar Kbolt"}, "CHANNEL"))
      w:advance(2)
      assert.are.equal(1, #w.bus:sent())
    end)

    it("a muted engine still sends a DEATH report, and nothing else (R62)", function()
      local p = add("Ana Smith")
      add("Bo Lee")
      local fields = {rideId = "Dar Kbolt@Ana Smith@1", victim = "Ana Smith", warlock = "Dar Kbolt", secs = 5, source = "self"}
      p.engine:mute(true)
      assert.are.same({nil, "muted"}, {p.engine:send("RATING", {kind = "trust", target = "Dar Kbolt", stars = 5, id = "r1", ts = w.clock:now()}, "CHANNEL")})
      assert.is_string(p.engine:send("DEATH", fields, "CHANNEL"))
      w:advance(2)
      assert.are.equal(1, #w.bus:sent())
    end)

    it("refuses every public action and every channel message while disabled; whispers still go", function()
      local p = add("Ana Smith", {channelsFull = true})
      add("Bo Lee")
      assert.are.same({nil, "disabled"}, {p.engine:openStand{kind = "lock"}})
      assert.are.same({nil, "disabled"}, {p.engine:applyClicker("s1", 25)})
      assert.are.same({nil, "disabled"}, {p.engine:send("QUERY", {target = "Dar Kbolt"}, "CHANNEL")})
      assert.is_string(p.engine:send("QUERY", {target = "Dar Kbolt"}, "WHISPER", "Bo Lee"))
      w:advance(1)
      assert.are.equal(1, #w.bus:sent())
      assert.are.equal("WHISPER", w.bus:sent()[1].dist)
    end)

    it("Engine.action passes the arguments through while enabled", function()
      ns.Engine.testAction = ns.Engine.action(function(e, a, b) return e.me, a, b end)
      local on = add("Ana Smith")
      local off = add("Bo Lee", {channelsFull = true})
      assert.are.same({"Ana Smith", 1, "x"}, {on.engine:testAction(1, "x")})
      assert.are.same({nil, "disabled"}, {off.engine:testAction(1, "x")})
    end)

    it("Engine.action refuses with dead for a dead Hardcore player only (R35, R37)", function()
      ns.Engine.testAction = ns.Engine.action(function(e) return e.me end)
      local hc = add("Ana Smith")
      local soft = add("Bo Lee", {hardcore = false})
      assert.are.same({"Ana Smith"}, {hc.engine:testAction()})
      w:kill("Ana Smith")
      w:kill("Bo Lee")
      assert.are.same({nil, "dead"}, {hc.engine:testAction()})
      assert.are.same({"Bo Lee"}, {soft.engine:testAction()}) -- off Hardcore a death is not final
    end)
  end)

  describe("group helpers", function()
    after_each(function() assert.are.same({}, w.errors) end)

    it("groupDist is RAID in a raid and PARTY otherwise", function()
      local a = add("Ana Smith")
      add("Bo Lee")
      assert.are.equal("PARTY", a.engine:groupDist())
      a.game:invite("Bo Lee")
      assert.is_true(w:acceptInvite("Bo Lee"))
      assert.are.equal("PARTY", a.engine:groupDist())
      a.game:convertToRaid()
      w:advance(0.2) -- the conversion lands on the next step (R53)
      assert.are.equal("RAID", a.engine:groupDist())
    end)

    it("inGroup is true only for another member of my group, by full name", function()
      local a = add("Ana Smith")
      add("Bo Lee")
      add("Cy Dane")
      assert.is_false(a.engine:inGroup("Bo Lee"))
      a.game:invite("Bo Lee")
      assert.is_true(w:acceptInvite("Bo Lee"))
      assert.is_true(a.engine:inGroup("Bo Lee"))
      assert.is_true(a.engine:inGroup(" Bo  Lee "))
      assert.is_false(a.engine:inGroup("Bo"))
      assert.is_false(a.engine:inGroup("Ana Smith")) -- not myself
      assert.is_false(a.engine:inGroup("Cy Dane"))
      assert.is_false(a.engine:inGroup(nil))
    end)
  end)

  describe("stands on the board (R18, R41)", function()
    after_each(function() assert.are.same({}, w.errors) end)

    local DAR = "Dar Kbolt@40000" -- stand ids are owner@seconds

    it("puts a heard stand on the board under its sender and emits BOARD_CHANGED", function()
      local p = add("Ana Smith")
      hear(p, "Dar Kbolt", "STAND", stand(DAR))
      local view = ns.Board.get(p.engine.board, DAR)
      assert.are.equal("Dar Kbolt", view.owner)
      assert.are.equal("Tanaris", view.zone)
      assert.are.equal(40000, view.seenAt)
      assert.are.equal(1, #emitted(p, "BOARD_CHANGED"))
    end)

    it("drops a STAND whose id does not start with its sender's name and \"@\" (R41)", function()
      local p = add("Ana Smith")
      hear(p, "Mal Ory", "STAND", stand(DAR))             -- another player's id
      hear(p, "Mal Ory", "STAND", stand("Mal Oryx@40000")) -- a longer name that starts like the sender's
      hear(p, "Mal Ory", "STAND", stand("Mal Ory40000"))   -- no "@"
      hear(p, "Mal Ory", "STAND", stand("s1"))
      assert.are.same({}, ns.Board.list(p.engine.board))
      assert.are.same({}, emitted(p, "BOARD_CHANGED"))
      hear(p, " Mal  Ory ", "STAND", stand("Mal Ory@40000")) -- the sender's name is tidied first
      assert.are.equal(1, #ns.Board.list(p.engine.board))
    end)

    it("never lets another player take over a stand id, even after it expires (R18)", function()
      local p = add("Ana Smith")
      hear(p, "Dar Kbolt", "STAND", stand(DAR))
      w:advance(10)
      hear(p, "Mal Ory", "STAND", stand(DAR, {wx = 9999}))
      local view = ns.Board.get(p.engine.board, DAR)
      assert.are.equal("Dar Kbolt", view.owner)
      assert.are.equal(5000, view.wx)
      assert.are.equal(1, #emitted(p, "BOARD_CHANGED"))
      hear(p, "Dar Kbolt", "STAND", stand(DAR)) -- the owner's heartbeat
      assert.are.equal(2, #emitted(p, "BOARD_CHANGED"))
      w:advance(ns.Config.STAND_TTL + 40)
      assert.is_nil(ns.Board.get(p.engine.board, DAR))
      hear(p, "Mal Ory", "STAND", stand(DAR, {wx = 9999}))
      assert.is_nil(ns.Board.get(p.engine.board, DAR))
    end)

    it("removes a stand only on its owner's STAND_END", function()
      local p = add("Ana Smith")
      hear(p, "Dar Kbolt", "STAND", stand(DAR))
      hear(p, "Mal Ory", "STAND_END", {standId = DAR})
      assert.is_not_nil(ns.Board.get(p.engine.board, DAR))
      assert.are.equal(1, #emitted(p, "BOARD_CHANGED"))
      hear(p, "Dar Kbolt", "STAND_END", {standId = DAR})
      assert.is_nil(ns.Board.get(p.engine.board, DAR))
      assert.are.equal(2, #emitted(p, "BOARD_CHANGED"))
      hear(p, "Dar Kbolt", "STAND_END", {standId = "Dar Kbolt@1"}) -- not on the board
      assert.are.equal(2, #emitted(p, "BOARD_CHANGED"))
    end)

    it("drops a stand that went quiet within 30 s after STAND_TTL, with BOARD_CHANGED", function()
      local p = add("Ana Smith")
      hear(p, "Dar Kbolt", "STAND", stand(DAR))
      w:advance(ns.Config.STAND_TTL)
      assert.is_not_nil(ns.Board.get(p.engine.board, DAR))
      w:advance(30)
      assert.is_nil(ns.Board.get(p.engine.board, DAR))
      assert.are.equal(2, #emitted(p, "BOARD_CHANGED"))
    end)
  end)

  it("sweeps the board and the witness every Engine.TICK_INTERVAL seconds", function()
    assert.are.equal(30, ns.Engine.TICK_INTERVAL)
  end)

  describe("instances", function()
    after_each(function() assert.are.same({}, w.errors) end)

    local LOCKDOWN = {"STATUS", "STATUS_LOCKDOWN", "Paused (instance)"}

    it("emits STATUS_LOCKDOWN once per instance visit", function()
      local p = add("Ana Smith")
      w:moveTo("Ana Smith", "deadmines")
      w:moveTo("Ana Smith", "deadmines", 5, 5)
      assert.are.same({LOCKDOWN}, emitted(p, "STATUS"))
      w:moveTo("Ana Smith", "ironforge")
      w:moveTo("Ana Smith", "deadmines")
      assert.are.same({LOCKDOWN, LOCKDOWN}, emitted(p, "STATUS"))
    end)

    it("emits STATUS_LOCKDOWN at start inside an instance", function()
      local p = add("Ana Smith", {place = "deadmines"})
      assert.are.same({LOCKDOWN}, p.events)
    end)

    it("closes my stand on entering an instance; STAND_END goes out after leaving it", function()
      local p = add("Dar Kbolt", {class = "WARLOCK", level = 45})
      local b = add("Bo Lee")
      local mine = ns.Stand.new{standId = "Dar Kbolt@40000", owner = "Dar Kbolt", kind = "lock", faction = "Alliance",
        mapID = 1455, x = 0.5, y = 0.5, wx = 0, wy = 0, zone = "Ironforge", subzone = "The Commons", now = 40000}
      p.engine.stand = mine
      hear(b, "Dar Kbolt", "STAND", ns.Stand.toFields(mine))
      w:moveTo("Dar Kbolt", "deadmines")
      assert.is_nil(p.engine.stand)
      assert.is_true(mine.closed)
      assert.are.same({{"STAND_CHANGED", mine}}, emitted(p, "STAND_CHANGED"))
      w:advance(2)
      assert.are.same({}, wire("Dar Kbolt"))
      w:moveTo("Dar Kbolt", "ironforge")
      w:advance(2)
      local sent = wire("Dar Kbolt")
      assert.are.equal("STAND_END", sent[1].type)
      assert.are.equal("Dar Kbolt@40000", sent[1].standId)
      assert.is_nil(ns.Board.get(b.engine.board, "Dar Kbolt@40000"))
    end)
  end)
end)
