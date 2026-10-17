describe("Bus", function()
  local ns, clock, bus, inbox, be
  before_each(function()
    ns = Taxi.load()
    clock = ns.Clock.new(1000)
    bus = ns.Bus.new{clock = clock}
    inbox, be = {}, {}
  end)
  local function join(name, faction)
    inbox[name] = {}
    be[name] = bus:attach(name, faction or "Alliance", function(prefix, text, dist, sender)
      inbox[name][#inbox[name] + 1] = {prefix = prefix, text = text, dist = dist, sender = sender, at = clock:now()}
    end)
    return be[name]
  end
  local function count(name) return #inbox[name] end

  it("gives each player a backend with send and inLockdown", function()
    local ana = join("Ana Smith")
    assert.is_function(ana.send)
    assert.is_function(ana.inLockdown)
    assert.is_false(ana.inLockdown())
  end)

  it("refuses to attach one name twice", function()
    join("Ana Smith")
    assert.has_error(function() join("Ana Smith") end)
  end)

  it("delivers a channel message to the same faction, never to the sender", function()
    join("Ana Smith"); join("Bo Lee"); join("Cy Dane"); join("Hal Orc", "Horde")
    assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "hello", "CHANNEL"))
    clock:advance(1)
    assert.are.equal(0, count("Ana Smith"))
    assert.are.equal(1, count("Bo Lee"))
    assert.are.equal(1, count("Cy Dane"))
    assert.are.equal(0, count("Hal Orc"))
  end)

  it("passes prefix, text and distribution to the receiver", function()
    join("Ana Smith"); join("Bo Lee")
    be["Ana Smith"].send("TaxiFvr", "hello", "CHANNEL")
    clock:advance(1)
    local m = inbox["Bo Lee"][1]
    assert.are.equal("TaxiFvr", m.prefix)
    assert.are.equal("hello", m.text)
    assert.are.equal("CHANNEL", m.dist)
  end)

  it("stamps the sender itself, whatever the text claims", function()
    join("Ana Smith"); join("Bo Lee"); join("Mal Ory")
    be["Mal Ory"].send("TaxiFvr", "1^RATING^m1^trust^Ana Smith^5 -- sent by Ana Smith", "CHANNEL")
    clock:advance(1)
    assert.are.equal("Mal Ory", inbox["Ana Smith"][1].sender)
    assert.are.equal("Mal Ory", inbox["Bo Lee"][1].sender)
  end)

  it("delivers after the latency, not before", function()
    join("Ana Smith"); join("Bo Lee")
    be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL")
    clock:advance(0.09)
    assert.are.equal(0, count("Bo Lee"))
    clock:advance(0.02)
    assert.are.equal(1, count("Bo Lee"))
  end)

  it("takes a different latency", function()
    bus = ns.Bus.new{clock = clock, latency = 2}
    join("Ana Smith"); join("Bo Lee")
    be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL")
    clock:advance(1.9)
    assert.are.equal(0, count("Bo Lee"))
    clock:advance(0.2)
    assert.are.equal(1, count("Bo Lee"))
    assert.are.equal(1002, inbox["Bo Lee"][1].at)
  end)

  it("takes zero latency", function()
    bus = ns.Bus.new{clock = clock, latency = 0}
    join("Ana Smith"); join("Bo Lee")
    be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL")
    clock:advance(0)
    assert.are.equal(1, count("Bo Lee"))
  end)

  describe("whispers", function()
    it("go to the target only", function()
      join("Ana Smith"); join("Bo Lee"); join("Cy Dane")
      assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "psst", "WHISPER", "Bo Lee"))
      clock:advance(1)
      assert.are.equal(1, count("Bo Lee"))
      assert.are.equal("WHISPER", inbox["Bo Lee"][1].dist)
      assert.are.equal("Ana Smith", inbox["Bo Lee"][1].sender)
      assert.are.equal(0, count("Cy Dane"))
      assert.are.equal(0, count("Ana Smith"))
    end)

    it("to an unknown target are accepted and go nowhere", function()
      join("Ana Smith"); join("Bo Lee")
      assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "psst", "WHISPER", "Nobody Here"))
      clock:advance(1)
      assert.are.equal(0, count("Bo Lee"))
    end)

    it("without a target are a general error", function()
      join("Ana Smith")
      assert.are.equal(9, be["Ana Smith"].send("TaxiFvr", "psst", "WHISPER"))
      assert.are.equal(0, #bus:sent())
    end)
  end)

  describe("groups", function()
    it("send PARTY and RAID to the sender's group members only", function()
      join("Ana Smith"); join("Bo Lee"); join("Cy Dane"); join("Di Frost")
      bus:setGroup("Ana Smith", "g1"); bus:setGroup("Bo Lee", "g1"); bus:setGroup("Cy Dane", "g2")
      assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "p", "PARTY"))
      assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "r", "RAID"))
      clock:advance(1)
      assert.are.equal(2, count("Bo Lee"))
      assert.are.equal("PARTY", inbox["Bo Lee"][1].dist)
      assert.are.equal("RAID", inbox["Bo Lee"][2].dist)
      assert.are.equal(0, count("Ana Smith"))
      assert.are.equal(0, count("Cy Dane"))
      assert.are.equal(0, count("Di Frost"))
    end)

    it("follow setGroup, including leaving (nil)", function()
      join("Ana Smith"); join("Bo Lee")
      bus:setGroup("Ana Smith", "g1"); bus:setGroup("Bo Lee", "g1")
      bus:setGroup("Bo Lee", nil)
      be["Ana Smith"].send("TaxiFvr", "p", "PARTY")
      clock:advance(1)
      assert.are.equal(0, count("Bo Lee"))
    end)

    it("are a general error for a sender in no group", function()
      join("Ana Smith"); join("Bo Lee")
      assert.are.equal(9, be["Ana Smith"].send("TaxiFvr", "p", "PARTY"))
      assert.are.equal(0, #bus:sent())
    end)

    it("do not stop channel delivery", function()
      join("Ana Smith"); join("Bo Lee")
      bus:setGroup("Ana Smith", "g1")
      be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL")
      clock:advance(1)
      assert.are.equal(1, count("Bo Lee"))
    end)
  end)

  it("rejects an unknown distribution", function()
    join("Ana Smith")
    assert.are.equal(9, be["Ana Smith"].send("TaxiFvr", "x", "GUILD"))
    assert.are.equal(9, be["Ana Smith"].send("TaxiFvr", "x", nil))
  end)

  describe("size limits", function()
    it("accept 255 bytes and refuse 256 with code 9", function()
      join("Ana Smith"); join("Bo Lee")
      assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", string.rep("x", 255), "CHANNEL"))
      assert.are.equal(9, be["Ana Smith"].send("TaxiFvr", string.rep("x", 256), "CHANNEL"))
      clock:advance(1)
      assert.are.equal(1, count("Bo Lee"))
    end)

    it("refuse a prefix over 16 characters and a non-string text", function()
      join("Ana Smith")
      assert.are.equal(0, be["Ana Smith"].send(string.rep("p", 16), "x", "CHANNEL"))
      assert.are.equal(9, be["Ana Smith"].send(string.rep("p", 17), "x", "CHANNEL"))
      assert.are.equal(9, be["Ana Smith"].send("TaxiFvr", nil, "CHANNEL"))
    end)

    it("do not use up throttle tokens", function()
      join("Ana Smith")
      for _ = 1, 50 do be["Ana Smith"].send("TaxiFvr", string.rep("x", 256), "CHANNEL") end
      for _ = 1, 10 do assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL")) end
    end)
  end)

  describe("throttle", function()
    local function burst(name, dist, target)
      local codes = {}
      for i = 1, 10 do codes[i] = be[name].send("TaxiFvr", "x", dist, target) end
      return codes
    end

    it("lets 10 through, then refuses with 8 on the channel and 3 elsewhere", function()
      join("Ana Smith"); join("Bo Lee")
      for _, code in ipairs(burst("Ana Smith", "CHANNEL")) do assert.are.equal(0, code) end
      assert.are.equal(8, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
      assert.are.equal(3, be["Ana Smith"].send("TaxiFvr", "x", "WHISPER", "Bo Lee"))
      bus:setGroup("Ana Smith", "g1")
      assert.are.equal(3, be["Ana Smith"].send("TaxiFvr", "x", "PARTY"))
    end)

    it("refills one token a second", function()
      join("Ana Smith")
      burst("Ana Smith", "CHANNEL")
      clock:advance(0.9)
      assert.are.equal(8, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
      clock:advance(0.1)
      assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
      assert.are.equal(8, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
      clock:advance(3)
      for _ = 1, 3 do assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL")) end
      assert.are.equal(8, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
    end)

    it("refills despite float error in repeated small steps", function()
      -- Ten steps of 0.2 from 0 add up to 1.9999999999999998, not 2.
      clock = ns.Clock.new(0)
      bus = ns.Bus.new{clock = clock}
      join("Ana Smith")
      burst("Ana Smith", "CHANNEL")
      for _ = 1, 10 do clock:advance(0.2) end
      assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
      assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
      assert.are.equal(8, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
    end)

    it("never holds more than 10", function()
      join("Ana Smith")
      clock:advance(1000)
      for _, code in ipairs(burst("Ana Smith", "CHANNEL")) do assert.are.equal(0, code) end
      assert.are.equal(8, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
    end)

    it("is a bucket per sender", function()
      join("Ana Smith"); join("Bo Lee")
      burst("Ana Smith", "CHANNEL")
      assert.are.equal(8, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
      assert.are.equal(0, be["Bo Lee"].send("TaxiFvr", "x", "CHANNEL"))
    end)

    it("does not deliver or record a refused message", function()
      join("Ana Smith"); join("Bo Lee")
      burst("Ana Smith", "CHANNEL")
      be["Ana Smith"].send("TaxiFvr", "refused", "CHANNEL")
      clock:advance(1)
      assert.are.equal(10, count("Bo Lee"))
      assert.are.equal(10, #bus:sent())
    end)
  end)

  describe("lockdown", function()
    it("refuses sends with 11 and reports inLockdown, for that player only", function()
      join("Ana Smith"); join("Bo Lee")
      bus:setLockdown("Ana Smith", true)
      assert.is_true(be["Ana Smith"].inLockdown())
      assert.is_false(be["Bo Lee"].inLockdown())
      assert.are.equal(11, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
      assert.are.equal(0, be["Bo Lee"].send("TaxiFvr", "y", "CHANNEL"))
      clock:advance(1)
      assert.are.equal(0, count("Bo Lee"))
      assert.are.equal(1, count("Ana Smith"))
      assert.are.equal("y", inbox["Ana Smith"][1].text)
    end)

    it("ends when cleared, and costs no throttle tokens while it lasts", function()
      join("Ana Smith"); join("Bo Lee")
      bus:setLockdown("Ana Smith", true)
      for _ = 1, 20 do be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL") end
      bus:setLockdown("Ana Smith", false)
      assert.is_false(be["Ana Smith"].inLockdown())
      for _ = 1, 10 do assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL")) end
    end)

    it("does not stop a locked-down player from receiving", function()
      join("Ana Smith"); join("Bo Lee")
      bus:setLockdown("Ana Smith", true)
      be["Bo Lee"].send("TaxiFvr", "x", "CHANNEL")
      clock:advance(1)
      assert.are.equal(1, count("Ana Smith"))
    end)
  end)

  describe("sent()", function()
    it("lists accepted sends in order with sender, dist, target and text", function()
      join("Ana Smith"); join("Bo Lee")
      be["Ana Smith"].send("TaxiFvr", "one", "CHANNEL")
      be["Bo Lee"].send("TaxiFvr", "two", "WHISPER", "Ana Smith")
      be["Ana Smith"].send("TaxiFvr", string.rep("x", 256), "CHANNEL") -- refused
      local sent = bus:sent()
      assert.are.equal(2, #sent)
      assert.are.equal("Ana Smith", sent[1].sender)
      assert.are.equal("CHANNEL", sent[1].dist)
      assert.is_nil(sent[1].target)
      assert.are.equal("one", sent[1].text)
      assert.are.equal("Bo Lee", sent[2].sender)
      assert.are.equal("WHISPER", sent[2].dist)
      assert.are.equal("Ana Smith", sent[2].target)
      assert.are.equal("two", sent[2].text)
      assert.are.equal("TaxiFvr", sent[2].prefix)
    end)
  end)

  describe("drop rate", function()
    -- 100 players on one channel and one message: returns how many copies each got.
    local function crowd(seed, rate)
      clock = ns.Clock.new(0)
      bus = ns.Bus.new{clock = clock, seed = seed}
      inbox, be = {}, {}
      join("Sender One")
      local names = {}
      for i = 1, 100 do names[i] = "Player " .. i; join(names[i]) end
      bus:setDropRate(rate)
      be["Sender One"].send("TaxiFvr", "x", "CHANNEL")
      clock:advance(1)
      local got = {}
      for i = 1, 100 do got[i] = count(names[i]) end
      return got
    end

    local function total(list)
      local n = 0
      for _, v in ipairs(list) do n = n + v end
      return n
    end

    it("drops nothing at 0 and everything at 1, though sent() still records the send", function()
      assert.are.equal(100, total(crowd(1, 0)))
      assert.are.equal(0, total(crowd(1, 1)))
      assert.are.equal(1, #bus:sent())
    end)

    it("tells the sender nothing: a dropped send still returns 0", function()
      join("Ana Smith"); join("Bo Lee")
      bus:setDropRate(1)
      assert.are.equal(0, be["Ana Smith"].send("TaxiFvr", "x", "CHANNEL"))
    end)

    it("drops about that share of deliveries", function()
      local kept = total(crowd(1, 0.5))
      assert.is_true(kept > 30 and kept < 70, "kept " .. kept)
    end)

    it("is deterministic for a seed and differs between seeds", function()
      assert.are.same(crowd(7, 0.5), crowd(7, 0.5))
      assert.are_not.same(crowd(7, 0.5), crowd(8, 0.5))
    end)

    it("does not touch the global random generator", function()
      math.randomseed(42)
      local expected = math.random()
      math.randomseed(42)
      crowd(1, 0.5)
      assert.are.equal(expected, math.random())
    end)

    it("applies to deliveries made after setDropRate", function()
      join("Ana Smith"); join("Bo Lee")
      be["Ana Smith"].send("TaxiFvr", "before", "CHANNEL")
      bus:setDropRate(1)
      be["Ana Smith"].send("TaxiFvr", "after", "CHANNEL")
      bus:setDropRate(0)
      clock:advance(1)
      assert.are.equal(1, count("Bo Lee"))
      assert.are.equal("before", inbox["Bo Lee"][1].text)
    end)
  end)

  it("raises for an unknown player in setGroup and setLockdown", function()
    assert.has_error(function() bus:setGroup("Nobody Here", "g1") end)
    assert.has_error(function() bus:setLockdown("Nobody Here", true) end)
  end)
end)
