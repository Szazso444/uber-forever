describe("SummonGuard", function()
  local ns, G

  before_each(function()
    ns = Taxi.load()
    G = ns.SummonGuard
  end)

  -- A ride where everything matches: the verdict is GREEN.
  local function ok()
    return {
      hasRide = true, agreedWarlock = "Ana Smith", summoner = "Ana Smith", areaName = "Gadgetzan",
      standZone = "Tanaris", standSubzone = "Gadgetzan", standZoneLocal = "Tanaris",
      warlockInGroup = true, warlockMapID = 1446, standMapID = 1446, warlockDistance = 10,
      crewInCombat = {}, zoneMin = 40, playerLevel = 45, standChanged = false,
      trustScore = 4.6, trustIsNew = false,
    }
  end

  -- ok() with some facts overridden. A fact cannot be set to nil through a
  -- table constructor (pairs() skips nil values), so `without` drops facts.
  local function with(t)
    local f = ok()
    for k, v in pairs(t) do f[k] = v end
    return f
  end

  local function without(...)
    local f = ok()
    for _, k in ipairs({ ... }) do f[k] = nil end
    return f
  end

  local function check(verdict, id)
    for _, c in ipairs(verdict.checks) do
      if c.id == id then return c end
    end
    error("no check with id " .. id)
  end

  local function failedIds(verdict)
    local ids = {}
    for _, c in ipairs(verdict.checks) do
      if not c.ok then ids[#ids + 1] = c.id end
    end
    return ids
  end

  it("green when all match", function()
    assert.are.equal("GREEN", G.evaluate(ok()).level)
  end)

  it("wrong summoner sharing a first name", function() -- RF1
    assert.are.equal("RED", G.evaluate(with{ summoner = "Ana Jones" }).level)
  end)

  it("wrong area", function()
    assert.are.equal("RED", G.evaluate(with{ areaName = "Searing Gorge" }).level)
  end)

  it("localized area name", function() -- RF2
    assert.are.equal("GREEN", G.evaluate(with{ areaName = "Tanaris", standZone = "Tanaris", standSubzone = "Gadgetzan", standZoneLocal = "Tanaris" }).level)
    assert.are.equal("GREEN", G.evaluate(with{ areaName = "Eisenschmiede", standZone = "Ironforge", standSubzone = "Die Halle", standZoneLocal = "Eisenschmiede" }).level)
  end)

  it("warlock far away or missing", function()
    assert.are.equal("RED", G.evaluate(with{ warlockDistance = 41 }).level)
    assert.are.equal("RED", G.evaluate(with{ warlockInGroup = false, warlockDistance = nil }).level)
  end)

  it("crew in combat", function()
    assert.are.equal("RED", G.evaluate(with{ crewInCombat = { "C One" } }).level)
  end)

  it("yellow warnings", function()
    assert.are.equal("YELLOW", G.evaluate(with{ playerLevel = 30 }).level)
    assert.are.equal("YELLOW", G.evaluate(with{ standChanged = true }).level)
    assert.are.equal("YELLOW", G.evaluate(with{ trustIsNew = true }).level)
  end)

  it("no ride", function() -- RF3
    local v = G.evaluate({ hasRide = false, summoner = "Ana Jones", areaName = "Searing Gorge" })
    assert.are.equal("YELLOW", v.level)
    assert.are.equal("noride", v.checks[1].id)
  end)

  it("lists every check in order", function()
    local ids = {}
    for _, c in ipairs(G.evaluate(ok()).checks) do ids[#ids + 1] = c.id end
    assert.are.same({ "summoner", "area", "position", "combat", "level", "changed", "trust" }, ids)
  end)

  describe("check items", function()
    it("carry id, ok, the level a failure causes, and text", function()
      local expected = {
        summoner = "RED", area = "RED", position = "RED", combat = "RED",
        level = "YELLOW", changed = "YELLOW", trust = "YELLOW",
      }
      for _, c in ipairs(G.evaluate(ok()).checks) do
        assert.is_true(c.ok, c.id)
        assert.are.equal(expected[c.id], c.level, c.id)
        assert.are.equal("string", type(c.text), c.id)
        assert.is_true(c.text ~= "", c.id)
      end
    end)

    it("keep their failure level when they pass or fail", function()
      local v = G.evaluate(with{ summoner = "Ana Jones", standChanged = true })
      assert.are.equal("RED", check(v, "summoner").level)
      assert.are.equal("YELLOW", check(v, "changed").level)
    end)

    it("fail only the check that is wrong", function()
      assert.are.same({ "summoner" }, failedIds(G.evaluate(with{ summoner = "Ana Jones" })))
      assert.are.same({ "area" }, failedIds(G.evaluate(with{ areaName = "Searing Gorge" })))
      assert.are.same({ "position" }, failedIds(G.evaluate(with{ warlockDistance = 41 })))
      assert.are.same({ "combat" }, failedIds(G.evaluate(with{ crewInCombat = { "C One" } })))
      assert.are.same({ "level" }, failedIds(G.evaluate(with{ playerLevel = 30 })))
      assert.are.same({ "changed" }, failedIds(G.evaluate(with{ standChanged = true })))
      assert.are.same({ "trust" }, failedIds(G.evaluate(with{ trustIsNew = true })))
    end)
  end)

  describe("summoner", function()
    it("a RED line names both people", function()
      local c = check(G.evaluate(with{ summoner = "Ana Jones" }), "summoner")
      assert.is_false(c.ok)
      assert.are.equal("Summoner: Ana Jones (agreed: Ana Smith)", c.text)
    end)

    it("the OK line names the summoner", function()
      assert.are.equal("Summoner: Ana Smith", check(G.evaluate(ok()), "summoner").text)
    end)

    it("no summoner is RED and does not raise", function()
      local v = G.evaluate(without("summoner"))
      assert.are.equal("RED", v.level)
      assert.is_false(check(v, "summoner").ok)
      assert.is_truthy(check(v, "summoner").text:find("(agreed: Ana Smith)", 1, true))
    end)

    it("a blank summoner is RED", function()
      assert.are.equal("RED", G.evaluate(with{ summoner = "   " }).level)
      assert.are.equal("RED", G.evaluate(with{ summoner = "" }).level)
    end)

    it("no agreed warlock is RED, even when the summoner is also missing", function()
      assert.are.equal("RED", G.evaluate(without("agreedWarlock")).level)
      assert.are.equal("RED", G.evaluate(without("agreedWarlock", "summoner")).level)
    end)

    it("a first name alone never matches", function()
      assert.are.equal("RED", G.evaluate(with{ summoner = "Ana" }).level)
    end)

    it("surrounding whitespace does not matter", function()
      assert.are.equal("GREEN", G.evaluate(with{ summoner = "  Ana Smith " }).level)
    end)
  end)

  describe("area", function()
    it("a RED line shows the destination and the agreed place", function()
      local c = check(G.evaluate(with{ areaName = "Searing Gorge" }), "area")
      assert.is_false(c.ok)
      assert.are.equal("Destination: Searing Gorge (agreed: Tanaris)", c.text)
    end)

    it("the OK line names the destination", function()
      assert.are.equal("Destination: Gadgetzan", check(G.evaluate(ok()), "area").text)
    end)

    it("matches the English zone alone", function()
      local f = without("standZoneLocal", "standSubzone")
      f.areaName, f.standZone = "Ironforge", "Ironforge"
      assert.are.equal("GREEN", G.evaluate(f).level)
    end)

    it("ignores the wire zone when the stand's map has a local name (R65)", function()
      -- A stand on the Searing Gorge map whose message says "Ironforge".
      local v = G.evaluate(with{ areaName = "Ironforge", standZone = "Ironforge",
        standZoneLocal = "Searing Gorge", standSubzone = "Thorium Point" })
      assert.are.equal("RED", v.level)
      assert.are.equal("Destination: Ironforge (agreed: Searing Gorge)", check(v, "area").text)
      assert.are.equal("GREEN", G.evaluate(with{ areaName = "Searing Gorge", standZone = "Ironforge",
        standZoneLocal = "Searing Gorge", standSubzone = "Thorium Point" }).level)
    end)

    it("matches the subzone alone", function()
      local f = without("standZone", "standZoneLocal")
      f.areaName, f.standSubzone = "Gadgetzan", "Gadgetzan"
      assert.are.equal("GREEN", G.evaluate(f).level)
    end)

    it("ignores whitespace around the area", function()
      assert.are.equal("GREEN", G.evaluate(with{ areaName = "  Gadgetzan  " }).level)
    end)

    it("is an exact match, not a case-insensitive or partial one", function()
      assert.are.equal("RED", G.evaluate(with{ areaName = "gadgetzan", standZone = "Tanaris", standSubzone = "Gadgetzan", standZoneLocal = "Tanaris" }).level)
      assert.are.equal("RED", G.evaluate(with{ areaName = "Tana" }).level)
    end)

    it("no area name is RED", function()
      local v = G.evaluate(without("areaName"))
      assert.are.equal("RED", v.level)
      assert.is_false(check(v, "area").ok)
    end)

    it("a blank area name is RED", function()
      assert.are.equal("RED", G.evaluate(with{ areaName = "   " }).level)
      assert.are.equal("RED", G.evaluate(with{ areaName = "" }).level)
    end)

    it("a blank area is RED even when the stand has blank places", function()
      assert.are.equal("RED", G.evaluate(with{ areaName = "", standZone = "", standSubzone = "", standZoneLocal = "" }).level)
    end)

    it("missing stand places never match", function()
      local f = without("standZone", "standSubzone", "standZoneLocal")
      assert.are.equal("RED", G.evaluate(f).level)
      f = without("areaName", "standZone", "standSubzone", "standZoneLocal")
      assert.are.equal("RED", G.evaluate(f).level)
    end)

    it("an area line still renders when the agreed place is unknown", function()
      local c = check(G.evaluate(without("standZone", "standSubzone", "standZoneLocal")), "area")
      assert.are.equal("Destination: Gadgetzan (agreed: unknown)", c.text)
    end)
  end)

  describe("position", function()
    it("exactly the guard radius passes, just beyond fails", function()
      assert.are.equal(40, ns.Config.GUARD_YARDS)
      assert.are.equal("GREEN", G.evaluate(with{ warlockDistance = 40 }).level)
      assert.are.equal("RED", G.evaluate(with{ warlockDistance = 40.01 }).level)
    end)

    it("reads the radius from Config", function()
      ns.Config.GUARD_YARDS = 10
      assert.are.equal("GREEN", G.evaluate(with{ warlockDistance = 10 }).level)
      assert.are.equal("RED", G.evaluate(with{ warlockDistance = 11 }).level)
    end)

    it("distance 0 passes", function()
      assert.are.equal("GREEN", G.evaluate(with{ warlockDistance = 0 }).level)
    end)

    it("an unknown distance fails even when the warlock is in the group", function()
      local v = G.evaluate(without("warlockDistance"))
      assert.are.equal("RED", v.level)
      assert.is_false(check(v, "position").ok)
    end)

    it("a warlock outside the group fails even when close", function()
      assert.are.equal("RED", G.evaluate(with{ warlockInGroup = false, warlockDistance = 5 }).level)
    end)

    it("an unknown group state fails", function()
      assert.are.equal("RED", G.evaluate(without("warlockInGroup")).level)
    end)

    it("NaN and infinite distances fail", function()
      assert.are.equal("RED", G.evaluate(with{ warlockDistance = 0 / 0 }).level)
      assert.are.equal("RED", G.evaluate(with{ warlockDistance = math.huge }).level)
      assert.are.equal("RED", G.evaluate(with{ warlockDistance = -math.huge }).level)
    end)

    it("a negative distance is nonsense and fails", function()
      assert.are.equal("RED", G.evaluate(with{ warlockDistance = -1 }).level)
    end)

    it("a distance that is not a number fails", function()
      assert.are.equal("RED", G.evaluate(with{ warlockDistance = "10" }).level)
    end)

    it("a different map fails even at distance 0", function()
      assert.are.equal("RED", G.evaluate(with{ warlockMapID = 1447, warlockDistance = 0 }).level)
    end)

    it("an unknown map never matches", function()
      assert.are.equal("RED", G.evaluate(without("warlockMapID")).level)
      assert.are.equal("RED", G.evaluate(without("standMapID")).level)
      assert.are.equal("RED", G.evaluate(without("warlockMapID", "standMapID")).level)
    end)

    it("has fixed OK and BAD lines", function()
      assert.are.equal("Warlock is at the stand", check(G.evaluate(ok()), "position").text)
      assert.are.equal("Warlock is not at the agreed spot", check(G.evaluate(with{ warlockDistance = 41 }), "position").text)
    end)
  end)

  describe("combat", function()
    it("a RED line names everyone in combat", function()
      local c = check(G.evaluate(with{ crewInCombat = { "C One", "D Two" } }), "combat")
      assert.is_false(c.ok)
      assert.are.equal("In combat: C One, D Two", c.text)
    end)

    it("an unknown crew state fails rather than passes", function()
      local v = G.evaluate(without("crewInCombat"))
      assert.are.equal("RED", v.level)
      assert.is_false(check(v, "combat").ok)
    end)

    it("the OK line says nobody is in combat", function()
      assert.are.equal("Nobody in combat", check(G.evaluate(ok()), "combat").text)
    end)
  end)

  describe("level", function()
    it("passes when the zone has no level data", function()
      assert.are.equal("GREEN", G.evaluate(without("zoneMin")).level)
      assert.are.equal("GREEN", G.evaluate(without("zoneMin", "playerLevel")).level)
    end)

    it("passes at exactly the zone minimum", function()
      assert.are.equal("GREEN", G.evaluate(with{ zoneMin = 40, playerLevel = 40 }).level)
    end)

    it("fails one level below the zone minimum", function()
      local v = G.evaluate(with{ zoneMin = 40, playerLevel = 39 })
      assert.are.equal("YELLOW", v.level)
      assert.is_false(check(v, "level").ok)
    end)

    it("an unknown player level is a YELLOW warning when the zone has a minimum", function()
      local v = G.evaluate(without("playerLevel"))
      assert.are.equal("YELLOW", v.level)
      assert.is_false(check(v, "level").ok)
    end)

    it("the BAD line says how far off you are", function()
      assert.are.equal("Zone is level 40+, you are 30", check(G.evaluate(with{ playerLevel = 30 }), "level").text)
    end)

    it("a non-numeric zone minimum is not trusted", function()
      assert.are.equal("YELLOW", G.evaluate(with{ zoneMin = "40" }).level)
      assert.are.equal("YELLOW", G.evaluate(with{ zoneMin = 0 / 0 }).level)
    end)

    it("a NaN player level fails", function()
      assert.are.equal("YELLOW", G.evaluate(with{ playerLevel = 0 / 0 }).level)
    end)

    it("the OK line says the level is fine", function()
      assert.are.equal("Zone level is fine", check(G.evaluate(ok()), "level").text)
    end)
  end)

  describe("changed", function()
    it("a moved stand is YELLOW", function()
      local v = G.evaluate(with{ standChanged = true })
      assert.are.equal("YELLOW", v.level)
      assert.are.equal("Stand moved after you requested", check(v, "changed").text)
    end)

    it("an unknown stand state is not trusted", function()
      local v = G.evaluate(without("standChanged"))
      assert.are.equal("YELLOW", v.level)
      assert.is_false(check(v, "changed").ok)
    end)

    it("the OK line says the stand has not moved", function()
      assert.are.equal("Stand hasn't moved", check(G.evaluate(ok()), "changed").text)
    end)
  end)

  describe("trust", function()
    it("a missing score is YELLOW", function()
      local v = G.evaluate(without("trustScore"))
      assert.are.equal("YELLOW", v.level)
      assert.is_false(check(v, "trust").ok)
    end)

    it("a score below the threshold is YELLOW, exactly at it is fine", function()
      assert.are.equal(3.0, ns.Config.GUARD_LOW_TRUST)
      assert.are.equal("YELLOW", G.evaluate(with{ trustScore = 2.99 }).level)
      assert.are.equal("GREEN", G.evaluate(with{ trustScore = 3.0 }).level)
    end)

    it("a NaN score is YELLOW", function()
      assert.are.equal("YELLOW", G.evaluate(with{ trustScore = 0 / 0 }).level)
    end)

    it("a new warlock is YELLOW even with a high score", function()
      assert.are.equal("YELLOW", G.evaluate(with{ trustScore = 5, trustIsNew = true }).level)
    end)

    it("an unknown new/established state is not trusted", function()
      assert.are.equal("YELLOW", G.evaluate(without("trustIsNew")).level)
    end)

    it("has fixed OK and BAD lines", function()
      assert.are.equal("Trust rating OK", check(G.evaluate(ok()), "trust").text)
      assert.are.equal("Low or new Trust rating", check(G.evaluate(with{ trustIsNew = true }), "trust").text)
    end)
  end)

  describe("verdict level", function()
    it("RED beats YELLOW when both kinds fail", function()
      local v = G.evaluate(with{ summoner = "Ana Jones", playerLevel = 30, standChanged = true, trustIsNew = true })
      assert.are.equal("RED", v.level)
      assert.are.same({ "summoner", "level", "changed", "trust" }, failedIds(v))
    end)

    it("RED beats YELLOW whatever the order the checks fail in", function()
      assert.are.equal("RED", G.evaluate(with{ playerLevel = 30, crewInCombat = { "C One" } }).level)
      assert.are.equal("RED", G.evaluate(with{ trustIsNew = true, warlockDistance = 100 }).level)
    end)

    it("several YELLOW failures stay YELLOW", function()
      local v = G.evaluate(with{ playerLevel = 30, standChanged = true, trustIsNew = true })
      assert.are.equal("YELLOW", v.level)
      assert.are.same({ "level", "changed", "trust" }, failedIds(v))
    end)

    it("several RED failures are RED", function()
      local v = G.evaluate(with{ summoner = "Ana Jones", areaName = "Searing Gorge", warlockDistance = 99, crewInCombat = { "C One" } })
      assert.are.equal("RED", v.level)
      assert.are.same({ "summoner", "area", "position", "combat" }, failedIds(v))
    end)

    it("empty facts never produce GREEN", function()
      assert.are_not.equal("GREEN", G.evaluate({ hasRide = true }).level)
      assert.are.equal("RED", G.evaluate({ hasRide = true }).level)
    end)
  end)

  describe("no ride", function()
    it("is the only check", function()
      local v = G.evaluate({ hasRide = false, summoner = "Ana Jones", areaName = "Searing Gorge" })
      assert.are.equal(1, #v.checks)
      local c = v.checks[1]
      assert.are.equal("noride", c.id)
      assert.is_false(c.ok)
      assert.are.equal("YELLOW", c.level)
      assert.are.equal("Not a Taxi ride: Ana Jones \226\134\146 Searing Gorge", c.text)
    end)

    it("ignores every other fact, even a perfect-looking set", function()
      local v = G.evaluate(with{ hasRide = false })
      assert.are.equal("YELLOW", v.level)
      assert.are.equal(1, #v.checks)
    end)

    it("an unknown summoner or place still renders a line", function()
      local v = G.evaluate({ hasRide = false })
      assert.are.equal("YELLOW", v.level)
      assert.are.equal("Not a Taxi ride: unknown \226\134\146 unknown", v.checks[1].text)
    end)

    it("no facts at all is the same as no ride", function()
      local v = G.evaluate(nil)
      assert.are.equal("YELLOW", v.level)
      assert.are.equal("noride", v.checks[1].id)
    end)
  end)

  describe("locale", function()
    it("defines every guard string", function()
      local keys = {
        "GUARD_NO_RIDE", "GUARD_SUMMONER_OK", "GUARD_SUMMONER_BAD", "GUARD_AREA_OK", "GUARD_AREA_BAD",
        "GUARD_POS_OK", "GUARD_POS_BAD", "GUARD_COMBAT_OK", "GUARD_COMBAT_BAD", "GUARD_LEVEL_OK",
        "GUARD_LEVEL_BAD", "GUARD_LEVEL_UNKNOWN", "GUARD_CHANGED_OK", "GUARD_CHANGED_BAD",
        "GUARD_TRUST_OK", "GUARD_TRUST_BAD", "GUARD_UNKNOWN",
      }
      for _, key in ipairs(keys) do
        assert.are.equal("string", type(rawget(ns.L, key)), key)
      end
    end)
  end)
end)
