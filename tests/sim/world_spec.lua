describe("World", function()
  local ns, w
  before_each(function() ns = Taxi.load(); w = ns.World.new{seed = 5, start = 50000} end)
  after_each(function() assert.are.same({}, w.errors) end)

  -- Records the given game events as each engine receives them: {me, event, ...}.
  -- Register before adding players (the handlers are shared by every Engine).
  local function listen(...)
    local seen = {}
    for _, event in ipairs({...}) do
      ns.Engine.gameHandlers[event] = function(e, ...) seen[#seen + 1] = {e.me, event, ...} end
    end
    return seen
  end

  local function add(name, o)
    o = o or {}
    o.name = name
    o.class = o.class or "PRIEST"
    o.level = o.level or 30
    o.place = o.place or "ironforge"
    return w:addPlayer(o)
  end

  it("owns a clock that starts at start, and a bus", function()
    assert.are.equal(50000, w.clock:now())
    assert.is_function(w.bus.attach)
  end)

  it("lists the places, with the Deadmines as an instance", function()
    local P = ns.World.PLACES
    assert.are.same({mapID = 1455, zone = "Ironforge", subzone = "The Commons", wx = 0, wy = 0, levels = {1, 60}}, P.ironforge)
    assert.are.same({mapID = 1446, zone = "Tanaris", subzone = "Gadgetzan", wx = 5000, wy = 5000, levels = {40, 50}}, P.gadgetzan)
    assert.are.same({mapID = 1427, zone = "Searing Gorge", subzone = "Thorium Point", wx = -3000, wy = 900, levels = {43, 50}}, P.searing)
    assert.are.same({mapID = 1453, zone = "Stormwind City", subzone = "Trade District", wx = -8000, wy = 600, levels = {1, 60}}, P.stormwind)
    assert.are.same({mapID = 291, zone = "The Deadmines", subzone = "", wx = 0, wy = 0, levels = {15, 25}, inInstance = true}, P.deadmines)
    -- Every portal an Alliance mage learns ends in a place of this world (the in-game sim steps through them).
    for _, portal in ipairs(ns.Config.PORTALS) do
      if portal.key == "stormwind" or portal.key == "ironforge" or portal.key == "darnassus" then
        assert.is_table(P[portal.key], portal.key)
        assert.are.equal(portal.mapID, P[portal.key].mapID, portal.key)
      end
    end
  end)

  describe("addPlayer", function()
    it("gives a started engine on the player's game, and an empty event list", function()
      local p = add("Ana Smith", {class = "PRIEST", level = 30, guild = "Wolves", money = 1234})
      assert.are.equal("Ana Smith", p.engine.me)
      assert.are.equal(p.game, p.engine.game)
      assert.are.same({}, p.events)
      assert.is_false(p.engine.disabled)
      local g = p.game
      assert.are.equal("Ana Smith", g:me())
      assert.are.equal("Alliance", g:faction())
      assert.are.equal(30, g:level())
      assert.are.equal("PRIEST", g:class())
      assert.is_true(g:isHardcore())
      assert.is_false(g:isDead())
      assert.are.equal(1234, g:money())
      assert.is_true(g:joinChannel("TaxiForever"))
    end)

    it("takes a faction, hardcore=false and channelsFull", function()
      local p = add("Hal Orc", {faction = "Horde", hardcore = false, channelsFull = true})
      assert.are.equal("Horde", p.game:faction())
      assert.is_false(p.game:isHardcore())
      assert.are.same({nil, "full"}, {p.game:joinChannel("TaxiForever")})
    end)

    it("records the events the engine emits while it starts", function()
      local p = add("Ana Smith", {channelsFull = true})
      assert.are.equal("STATUS", p.events[1][1])
      assert.are.equal("STATUS_CHANNEL_FULL", p.events[1][2])
    end)

    it("gives the engine a random generator that replays with the seed", function()
      local function draws(seed)
        local world = ns.World.new{seed = seed, start = 0}
        local p = world:addPlayer{name = "Ana Smith", class = "PRIEST", level = 30, place = "ironforge"}
        local out = {}
        for i = 1, 5 do
          out[i] = p.engine.rng()
          assert.is_true(out[i] > 0 and out[i] < 1)
        end
        return out
      end
      assert.are.same(draws(9), draws(9))
      assert.are_not.same(draws(9), draws(10))
    end)

    it("refuses an unknown place", function()
      assert.has_error(function() add("Ana Smith", {place = "atlantis"}) end)
    end)
  end)

  describe("location", function()
    it("follows the place and the offsets", function()
      local p = add("Ana Smith", {place = "gadgetzan"})
      w:moveTo("Ana Smith", "gadgetzan", 3, -4)
      local loc = p.game:location()
      assert.are.equal(1446, loc.mapID)
      assert.are.equal(5003, loc.wx)
      assert.are.equal(4996, loc.wy)
      assert.are.equal("Tanaris", loc.zone)
      assert.are.equal("Gadgetzan", loc.subzone)
      assert.is_false(loc.inInstance)
      assert.is_number(loc.x)
      assert.is_number(loc.y)
    end)

    it("names maps in the player's language and gives zone levels", function()
      local de = add("Ute Berg", {locale = "deDE"})
      local en = add("Ana Smith")
      assert.are.equal("Eisenschmiede", de.game:mapName(1455))
      assert.are.equal("Eisenschmiede", de.game:location().zone)
      assert.are.equal("Ironforge", en.game:mapName(1455))
      assert.are.equal("Tanaris", de.game:mapName(1446)) -- no translation known: the English name
      assert.is_nil(en.game:mapName(9999))
      assert.are.same({40, 50}, {en.game:zoneLevels(1446)})
      assert.are.same({}, {en.game:zoneLevels(9999)})
    end)

    it("moveTo sends MOVED and locks the player down while in an instance", function()
      local seen = listen("MOVED")
      local p = add("Ana Smith")
      w:moveTo("Ana Smith", "deadmines")
      assert.are.same({{"Ana Smith", "MOVED"}}, seen)
      assert.is_true(p.game:location().inInstance)
      assert.is_true(w.bus.players["Ana Smith"].locked)
      w:moveTo("Ana Smith", "ironforge")
      assert.is_false(w.bus.players["Ana Smith"].locked)
    end)

    it("starts a player added in an instance locked down", function()
      add("Ana Smith", {place = "deadmines"})
      assert.is_true(w.bus.players["Ana Smith"].locked)
    end)
  end)

  describe("groups", function()
    it("invite and acceptInvite make a party, and both members hear GROUP_CHANGED", function()
      local seen = listen("GROUP_CHANGED")
      local a, b = add("Ana Smith"), add("Bo Lee", {place = "gadgetzan"})
      a.game:invite("Bo Lee")
      assert.is_true(w:acceptInvite("Bo Lee"))
      assert.are.same({{"Ana Smith", "GROUP_CHANGED"}, {"Bo Lee", "GROUP_CHANGED"}}, seen)
      assert.are.same({"Ana Smith", "Bo Lee"}, a.game:groupNames())
      assert.are.equal(2, b.game:groupSize())
      assert.is_false(a.game:isRaid())
      assert.are.equal("player", a.game:unitFor("Ana Smith"))
      assert.are.equal("party1", a.game:unitFor("Bo Lee"))
      assert.are.equal("party1", b.game:unitFor("Ana Smith"))
      assert.is_nil(a.game:unitFor("Cy Dane"))
      assert.are.same({5000, 5000, 1446}, {a.game:unitPos("party1")})
      assert.are.same({0, 0, 1455}, {a.game:unitPos("player")})
      assert.is_nil(a.game:unitPos("party2"))
    end)

    it("is solo before any invite, and acceptInvite fails without one", function()
      local a = add("Ana Smith")
      add("Bo Lee")
      assert.are.same({}, a.game:groupNames())
      assert.are.equal(0, a.game:groupSize())
      assert.is_false(w:acceptInvite("Bo Lee"))
    end)

    it("puts group members on one bus group", function()
      local a = add("Ana Smith")
      add("Bo Lee")
      a.game:invite("Bo Lee"); w:acceptInvite("Bo Lee")
      assert.is_not_nil(w.bus.players["Ana Smith"].group)
      assert.are.equal(w.bus.players["Ana Smith"].group, w.bus.players["Bo Lee"].group)
    end)

    it("fills a party at five; convertToRaid makes room and raid unit ids", function()
      local seen = listen("GROUP_CHANGED")
      local lead = add("Lea Der")
      for i = 1, 5 do add("Mem Ber" .. i) end
      for i = 1, 4 do lead.game:invite("Mem Ber" .. i); assert.is_true(w:acceptInvite("Mem Ber" .. i)) end
      lead.game:invite("Mem Ber5")
      assert.is_false(w:acceptInvite("Mem Ber5"))
      for i = #seen, 1, -1 do seen[i] = nil end
      lead.game:convertToRaid()
      -- R53: as in the game, the conversion itself lands on the next step
      assert.is_false(lead.game:isRaid())
      assert.are.equal(0, #seen)
      w:advance(0.2) -- game events caused by the player's own API calls arrive on the next frame
      assert.are.equal(5, #seen)
      assert.is_true(lead.game:isRaid())
      lead.game:invite("Mem Ber5")
      assert.is_true(w:acceptInvite("Mem Ber5"))
      assert.are.equal(6, lead.game:groupSize())
      assert.are.equal("raid6", lead.game:unitFor("Mem Ber5"))
      assert.are.equal("player", lead.game:unitFor("Lea Der"))
      assert.are.same({0, 0, 1455}, {lead.game:unitPos("raid6")})
    end)

    it("leaveGroup leaves, and a group of one disbands", function()
      local seen = listen("GROUP_CHANGED")
      local a, b, c = add("Ana Smith"), add("Bo Lee"), add("Cy Dane")
      a.game:invite("Bo Lee"); w:acceptInvite("Bo Lee")
      a.game:invite("Cy Dane"); w:acceptInvite("Cy Dane")
      for i = #seen, 1, -1 do seen[i] = nil end
      c.game:leaveGroup()
      w:advance(0.2)
      assert.are.equal(3, #seen)
      assert.are.same({"Ana Smith", "Bo Lee"}, a.game:groupNames())
      assert.are.same({}, c.game:groupNames())
      b.game:leaveGroup()
      w:advance(0.2)
      assert.are.same({}, a.game:groupNames())
      assert.is_nil(w.bus.players["Ana Smith"].group)
    end)
  end)

  describe("combat and death", function()
    it("setCombat tells the player and their group, and shows in unitInCombat", function()
      local seen = listen("COMBAT_CHANGED")
      local a = add("Ana Smith")
      add("Bo Lee"); add("Cy Dane")
      a.game:invite("Bo Lee"); w:acceptInvite("Bo Lee")
      w:setCombat("Bo Lee", true)
      assert.are.same({{"Ana Smith", "COMBAT_CHANGED", "Bo Lee", true}, {"Bo Lee", "COMBAT_CHANGED", "Bo Lee", true}}, seen)
      assert.is_true(a.game:unitInCombat("party1"))
      w:setCombat("Bo Lee", false)
      assert.is_false(a.game:unitInCombat("party1"))
    end)

    it("kill sends PLAYER_DIED to the victim, then HC_DEATH to every player, the victim included", function()
      local seen = listen("PLAYER_DIED", "HC_DEATH", "MEMBER_DIED")
      local a = add("Ana Smith")
      add("Bo Lee"); add("Cy Soft", {hardcore = false})
      a.game:invite("Bo Lee"); w:acceptInvite("Bo Lee")
      w:kill("Ana Smith")
      assert.are.same({
        {"Ana Smith", "PLAYER_DIED"},
        {"Ana Smith", "HC_DEATH", "Ana Smith"},
        {"Bo Lee", "HC_DEATH", "Ana Smith"},
        {"Cy Soft", "HC_DEATH", "Ana Smith"},
      }, seen) -- never MEMBER_DIED (R36); each engine decides what HC_DEATH means to it
      assert.is_true(a.game:isDead())
      assert.is_true(w:player("Bo Lee").game:unitDead("party1"))
    end)

    describe("the victim's own DEATH report (D6)", function()
      -- Vic heard his own ride start and arrive, as the traveler side records it.
      local function onRide()
        local v = add("Vic Tim")
        add("Bo Lee")
        local id = ns.Ride.makeId("Dar Kbolt", "Vic Tim", w.clock:now())
        v.engine.witness:rideStarted(id, "Vic Tim", "Dar Kbolt", w.clock:now(), "Vic Tim")
        w:advance(5)
        v.engine.witness:arrived(id, "Vic Tim", w.clock:now(), "Vic Tim")
        w:advance(5)
        return v, id
      end

      -- The DEATH messages Vic put on the bus.
      local function deathsSent()
        local out = {}
        for _, sent in ipairs(w.bus:sent()) do
          local msg = sent.sender == "Vic Tim" and ns.Protocol.decode(sent.text:match("^[^:]+:1/1:(.*)$") or "")
          if msg and msg.type == "DEATH" then out[#out + 1] = msg end
        end
        return out
      end

      it("goes out when kill brings PLAYER_DIED and then his own HC_DEATH", function()
        local _, id = onRide()
        w:kill("Vic Tim")
        w:advance(2)
        local sent = deathsSent()
        assert.are.equal(1, #sent)
        assert.are.same({id, "Vic Tim", "Dar Kbolt", "self"}, {sent[1].rideId, sent[1].victim, sent[1].warlock, sent[1].source})
      end)

      it("still goes out when his own HC_DEATH arrives before PLAYER_DIED", function()
        local v, id = onRide()
        v.dead = true
        w:fire(v, "HC_DEATH", "Vic Tim")
        w:fire(v, "PLAYER_DIED")
        w:advance(2)
        local sent = deathsSent()
        assert.are.equal(1, #sent)
        assert.are.same({id, "self"}, {sent[1].rideId, sent[1].source})
      end)
    end)
  end)

  describe("summons and portals", function()
    it("offerSummon names the summoner and the area in the traveler's language; acceptSummon moves them", function()
      local seen = listen("SUMMON_OFFERED", "MOVED")
      add("Dar Kbolt", {class = "WARLOCK", level = 45, place = "ironforge"})
      local t = add("Ute Berg", {place = "gadgetzan", locale = "deDE"})
      w:moveTo("Dar Kbolt", "ironforge", 10, 20)
      for i = #seen, 1, -1 do seen[i] = nil end
      w:offerSummon("Dar Kbolt", "Ute Berg")
      assert.are.same({{"Ute Berg", "SUMMON_OFFERED"}}, seen)
      assert.are.same({summoner = "Dar Kbolt", areaName = "Eisenschmiede"}, t.game:summonFacts())
      assert.is_true(w:acceptSummon("Ute Berg"))
      assert.are.same({"Ute Berg", "MOVED"}, seen[2])
      local loc = t.game:location()
      assert.are.same({1455, 10, 20}, {loc.mapID, loc.wx, loc.wy})
      assert.is_nil(t.game:summonFacts())
      assert.is_false(w:acceptSummon("Ute Berg"))
    end)

    it("cancelSummon clears the offer and sends SUMMON_GONE", function()
      local seen = listen("SUMMON_GONE")
      add("Dar Kbolt", {class = "WARLOCK", level = 45})
      local t = add("Tra Veler", {place = "gadgetzan"})
      w:offerSummon("Dar Kbolt", "Tra Veler")
      t.game:cancelSummon()
      assert.is_nil(t.game:summonFacts())
      w:advance(0.2)
      assert.are.same({{"Tra Veler", "SUMMON_GONE"}}, seen)
      assert.are.equal("gadgetzan", t.place)
    end)

    it("knownPortals lists a level 40 mage's faction portals", function()
      local mage = add("Mia Ge", {class = "MAGE", level = 40})
      local horde = add("Ora Mage", {class = "MAGE", level = 60, faction = "Horde"})
      local young = add("Nu Mage", {class = "MAGE", level = 39})
      local priest = add("Ana Smith", {level = 60})
      assert.are.same({{spellId = 10059, key = "stormwind"}, {spellId = 11416, key = "ironforge"}, {spellId = 11419, key = "darnassus"}},
        mage.game:knownPortals())
      assert.are.equal("orgrimmar", horde.game:knownPortals()[1].key)
      assert.are.same({}, young.game:knownPortals())
      assert.are.same({}, priest.game:knownPortals())
    end)

    it("castPortal and usePortal take a traveler at the mage's spot to the destination", function()
      local seen = listen("MOVED")
      add("Mia Ge", {class = "MAGE", level = 40, place = "ironforge"})
      local t = add("Tra Veler", {place = "gadgetzan"})
      assert.is_false(w:castPortal("Mia Ge", "orgrimmar")) -- not a portal she knows
      assert.is_true(w:castPortal("Mia Ge", "stormwind"))
      assert.is_false(w:usePortal("Tra Veler", "stormwind")) -- not at the portal
      w:moveTo("Tra Veler", "ironforge", 2, 2)
      assert.is_false(w:usePortal("Tra Veler", "ironforge")) -- no such portal open
      assert.is_true(w:usePortal("Tra Veler", "stormwind"))
      assert.are.equal(1453, t.game:location().mapID)
      assert.are.same({"Tra Veler", "MOVED"}, seen[#seen])
    end)
  end)

  describe("trade and money", function()
    it("trade moves copper and sends TRADE_DONE to both sides", function()
      local seen = listen("TRADE_DONE")
      local t = add("Tra Veler", {money = 50000})
      local d = add("Dar Kbolt", {class = "WARLOCK", level = 45})
      assert.is_true(w:trade("Tra Veler", "Dar Kbolt", 10000))
      assert.are.equal(40000, t.game:money())
      assert.are.equal(10000, d.game:money())
      assert.are.same({{"Tra Veler", "TRADE_DONE", "Dar Kbolt", 10000, 0}, {"Dar Kbolt", "TRADE_DONE", "Tra Veler", 0, 10000}}, seen)
    end)

    it("refuses a trade the giver can't pay", function()
      local seen = listen("TRADE_DONE")
      local t = add("Tra Veler", {money = 100})
      add("Dar Kbolt", {class = "WARLOCK", level = 45})
      assert.is_false(w:trade("Tra Veler", "Dar Kbolt", 101))
      assert.are.equal(100, t.game:money())
      assert.are.same({}, seen)
    end)

    it("openTrade and trySetTradeMoney are recorded", function()
      local t = add("Tra Veler", {money = 50000})
      add("Dar Kbolt", {class = "WARLOCK", level = 45})
      assert.is_true(t.game:openTrade("Dar Kbolt"))
      assert.is_true(t.game:trySetTradeMoney(5000))
      assert.are.equal("Dar Kbolt", t.tradeWith)
      assert.are.equal(5000, t.tradeMoney)
      assert.is_false(t.game:openTrade("Nobody Here"))
    end)

    it("tradeOpenWith is true for the player a trade was opened with, and only then (R64)", function()
      local t = add("Tra Veler", {money = 50000})
      add("Dar Kbolt", {class = "WARLOCK", level = 45})
      add("Cee One")
      assert.is_false(t.game:tradeOpenWith("Dar Kbolt"))
      t.game:openTrade("Dar Kbolt")
      assert.is_true(t.game:tradeOpenWith("Dar Kbolt"))
      assert.is_false(t.game:tradeOpenWith("Cee One"))
      assert.is_false(t.game:tradeOpenWith(nil))
    end)
  end)

  it("knows guildmates and soul shards", function()
    local a = add("Ana Smith", {guild = "Wolves"})
    add("Bo Lee", {guild = "Wolves"}); add("Cy Dane", {guild = "Bears"}); add("Di Solo")
    local lock = add("Dar Kbolt", {class = "WARLOCK", level = 45})
    assert.is_true(a.game:isGuildmate("Bo Lee"))
    assert.is_false(a.game:isGuildmate("Cy Dane"))
    assert.is_false(a.game:isGuildmate("Di Solo"))
    assert.is_false(w:player("Di Solo").game:isGuildmate("Ana Smith"))
    assert.is_true(lock.game:soulShards() > 0)
    assert.are.equal(0, a.game:soulShards())
  end)

  describe("advance and removePlayer", function()
    -- Records who heard each QUERY message: {me, sender}.
    local function hearQueries()
      local heard = {}
      ns.Engine.handlers.QUERY = function(e, _, sender) heard[#heard + 1] = {e.me, sender} end
      return heard
    end

    it("advance runs the clock and carries engine messages", function()
      local heard = hearQueries()
      local a = add("Ana Smith")
      add("Bo Lee")
      a.engine:send("QUERY", {target = "Dar Kbolt"}, "CHANNEL")
      w:advance(1)
      assert.is_true(math.abs(w.clock:now() - 50001) < 1e-6)
      assert.are.equal(1, #w.bus:sent())
      assert.are.same({{"Bo Lee", "Ana Smith"}}, heard)
    end)

    it("removePlayer takes a player offline; a new player of that name gets a fresh db unless one is passed", function()
      local heard = hearQueries()
      local a = add("Ana Smith")
      local b = add("Bo Lee")
      a.db.settings.marker = true
      w:removePlayer("Ana Smith")
      assert.has_error(function() w:player("Ana Smith") end)
      b.engine:send("QUERY", {target = "Dar Kbolt"}, "WHISPER", "Ana Smith")
      w:advance(1)
      assert.are.same({}, heard)
      local again = add("Ana Smith")
      assert.is_nil(again.db.settings.marker)
      w:removePlayer("Ana Smith")
      local kept = add("Ana Smith", {db = a.db})
      assert.is_true(kept.db.settings.marker)
    end)

    it("removePlayer takes a grouped player out of the group; the others hear GROUP_CHANGED", function()
      local seen = listen("GROUP_CHANGED")
      local a = add("Ana Smith")
      add("Bo Lee"); add("Cy Dane")
      a.game:invite("Bo Lee"); w:acceptInvite("Bo Lee")
      a.game:invite("Cy Dane"); w:acceptInvite("Cy Dane")
      for i = #seen, 1, -1 do seen[i] = nil end
      assert.has_no.errors(function() w:removePlayer("Cy Dane") end)
      assert.is_nil(w.players["Cy Dane"])
      assert.is_nil(w.bus.players["Cy Dane"])
      assert.are.same({{"Ana Smith", "GROUP_CHANGED"}, {"Bo Lee", "GROUP_CHANGED"}}, seen)
      assert.are.same({"Ana Smith", "Bo Lee"}, a.game:groupNames())
      assert.is_nil(a.game:unitFor("Cy Dane"))
      -- The last two: removing one breaks the group up.
      w:removePlayer("Bo Lee")
      assert.are.same({}, a.game:groupNames())
      assert.is_nil(w.bus.players["Ana Smith"].group)
    end)

    it("a removed player's engine stops sending", function()
      local a = add("Ana Smith")
      add("Bo Lee")
      w:removePlayer("Ana Smith")
      a.engine:send("QUERY", {target = "Dar Kbolt"}, "CHANNEL")
      w:advance(1)
      assert.are.equal(0, #w.bus:sent())
    end)
  end)
end)
