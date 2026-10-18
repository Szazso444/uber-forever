describe("Stand", function()
  local ns, S

  before_each(function()
    ns = Taxi.load()
    S = ns.Stand
  end)

  local function lock()
    return S.new{standId="s1", owner="Dar Kbolt", kind="lock", faction="Alliance", mapID=1446, wx=0, wy=0, zone="Tanaris", subzone="Gadgetzan", seats=3, clickerPct=25, now=0}
  end
  local function mage()
    return S.new{standId="m1", owner="Mia Mage", kind="mage", faction="Horde", mapID=1411, x=0.5, y=0.6, wx=10, wy=20, zone="Orgrimmar", subzone="", seats=3, portals={"stormwind", "ironforge"}, note="portals", now=0}
  end

  it("recruits until 2 clickers then lives", function()
    local s = lock(); assert.are.equal("recruiting", S.status(s))
    S.addClicker(s, "C One", 25, 1); S.addClicker(s, "C Two", 25, 1); assert.are.equal("live", S.status(s))
    S.removeClicker(s, "C Two"); assert.are.equal("paused", S.status(s))
  end)

  it("negotiated shares keep owner at 0% or above", function()
    local s = lock(); assert.is_true(S.addClicker(s, "C One", 60, 1))
    assert.are.same({nil, "over_share"}, {S.addClicker(s, "C Two", 50, 1)}); assert.are.equal(40, S.ownerPct(s))
    assert.are.same({nil, "bad_pct"}, {S.addClicker(s, "C Two", 0, 1)})
  end)

  it("needs raid above 5", function()
    local s = lock(); S.addClicker(s, "C One", 25, 1); S.addClicker(s, "C Two", 25, 1)
    S.addTraveler(s, "T One"); assert.is_false(S.needsRaid(s, 1)); S.addTraveler(s, "T Two"); assert.is_true(S.needsRaid(s, 1))
  end)

  it("moved too far", function() local s = lock(); assert.is_false(S.movedTooFar(s, 30, 40)); assert.is_true(S.movedTooFar(s, 40, 40)) end)

  it("owner comes from the sender", function() local v = S.fromFields(S.toFields(lock()), "Real Sender", 5); assert.are.equal("Real Sender", v.owner) end)

  describe("new", function()
    it("starts empty with both flags off", function()
      local s = lock()
      assert.are.equal("s1", s.standId)
      assert.are.equal("Dar Kbolt", s.owner)
      assert.are.equal("lock", s.kind)
      assert.are.same({}, s.clickers)
      assert.are.same({}, s.travelers)
      assert.are.same({combat=false, noShards=false}, s.flags)
      assert.are.equal(0, S.clickerCount(s))
      assert.are.equal(100, S.ownerPct(s))
    end)

    it("falls back to the configured seats and clicker share", function()
      local s = S.new{standId="s2", owner="A B", kind="lock", faction="Alliance", now=0}
      assert.are.equal(ns.Config.DEFAULT_SEATS, S.seatsFree(s))
      assert.are.equal(ns.Config.DEFAULT_CLICKER_PCT, s.clickerPct)
    end)

    it("does not share the caller's portals table", function()
      local portals = {"stormwind"}
      local s = S.new{standId="m2", owner="A B", kind="mage", faction="Horde", portals=portals, now=0}
      portals[2] = "ironforge"
      assert.are.same({"stormwind"}, s.portals)
    end)
  end)

  describe("clickers", function()
    it("seats at most two", function()
      local s = lock()
      assert.is_true(S.addClicker(s, "C One", 25, 1))
      assert.is_true(S.addClicker(s, "C Two", 25, 1))
      assert.are.same({nil, "full"}, {S.addClicker(s, "C Three", 10, 1)})
      assert.are.equal(2, S.clickerCount(s))
    end)

    it("records the share and join time under the full name", function()
      local s = lock()
      S.addClicker(s, "C One", 30, 7)
      assert.are.same({pct=30, joinedAt=7}, s.clickers["C One"])
      assert.are.equal(70, S.ownerPct(s))
    end)

    it("accepts whole shares from 1 to 99 and nothing else", function()
      local s = lock()
      for _, bad in ipairs({0, 100, -5, 25.5, 0/0, math.huge, "25"}) do
        assert.are.same({nil, "bad_pct"}, {S.addClicker(s, "C One", bad, 1)})
      end
      assert.are.same({nil, "bad_pct"}, {S.addClicker(s, "C One", nil, 1)})
      assert.are.equal(0, S.clickerCount(s))
      assert.is_true(S.addClicker(s, "C One", 1, 1))
      assert.is_true(S.addClicker(s, "C Two", 99, 1))
    end)

    it("lets the owner go down to exactly 0%", function()
      local s = lock()
      assert.is_true(S.addClicker(s, "C One", 50, 1))
      assert.is_true(S.addClicker(s, "C Two", 50, 1))
      assert.are.equal(0, S.ownerPct(s))
    end)

    it("refuses a share that would push the owner below 0%", function()
      local s = lock()
      S.addClicker(s, "C One", 50, 1)
      assert.are.same({nil, "over_share"}, {S.addClicker(s, "C Two", 51, 1)})
      assert.are.equal(1, S.clickerCount(s))
      assert.are.equal(50, S.ownerPct(s))
    end)

    it("a mage stand has no clickers", function()
      local s = mage()
      assert.are.same({nil, "mage"}, {S.addClicker(s, "C One", 25, 1)})
      assert.are.equal(0, S.clickerCount(s))
    end)

    it("matches names as full names, ignoring stray whitespace", function()
      local s = lock()
      S.addClicker(s, "C One", 25, 1)
      S.addClicker(s, "C Two", 25, 1)
      S.removeClicker(s, "C Three")
      S.removeClicker(s, "C")
      assert.are.equal(2, S.clickerCount(s))
      S.removeClicker(s, "  C  Two ")
      assert.are.equal(1, S.clickerCount(s))
      assert.is_nil(s.clickers["C Two"])
      assert.is_not_nil(s.clickers["C One"])
      assert.are.equal(75, S.ownerPct(s))
    end)

    it("re-adding a seated clicker renegotiates the share in place", function()
      local s = lock()
      S.addClicker(s, "C One", 25, 1)
      S.addClicker(s, "C Two", 25, 1)
      assert.is_true(S.addClicker(s, "C  One", 50, 9))
      assert.are.equal(2, S.clickerCount(s))
      assert.are.same({pct=50, joinedAt=1}, s.clickers["C One"])
      assert.are.equal(25, S.ownerPct(s))
      assert.are.same({nil, "over_share"}, {S.addClicker(s, "C One", 80, 9)})
      assert.are.equal(25, S.ownerPct(s))
    end)

    it("removeClicker ignores a non-string name", function()
      local s = lock()
      S.addClicker(s, "C One", 25, 1)
      S.removeClicker(s, nil)
      assert.are.equal(1, S.clickerCount(s))
    end)

    it("refuses a blank or missing name loudly", function()
      local s = lock()
      assert.has_error(function() S.addClicker(s, nil, 25, 1) end)
      assert.has_error(function() S.addClicker(s, "   ", 25, 1) end)
      assert.has_error(function() S.addTraveler(s, nil) end)
      assert.has_error(function() S.addTraveler(s, "") end)
      assert.are.equal(0, S.clickerCount(s))
      assert.are.same({}, s.travelers)
    end)
  end)

  describe("status", function()
    local function live()
      local s = lock()
      S.addClicker(s, "C One", 25, 1)
      S.addClicker(s, "C Two", 25, 1)
      return s
    end

    it("a lock stand with one clicker is still recruiting", function()
      local s = lock(); S.addClicker(s, "C One", 25, 1)
      assert.are.equal("recruiting", S.status(s))
      assert.is_falsy(s.wasLive)
    end)

    it("is closed whatever else is true", function()
      local s = live(); s.closed = true
      assert.are.equal("closed", S.status(s))
      local m = mage(); m.closed = true
      assert.are.equal("closed", S.status(m))
    end)

    it("sets wasLive the first time it computes live, and not before", function()
      local s = live()
      assert.is_falsy(s.wasLive)
      assert.are.equal("live", S.status(s))
      assert.is_true(s.wasLive)
    end)

    it("pauses rather than recruits once it has been live", function()
      local s = live(); S.status(s)
      S.removeClicker(s, "C One"); S.removeClicker(s, "C Two")
      assert.are.equal("paused", S.status(s))
      S.addClicker(s, "C Three", 25, 5); S.addClicker(s, "C Four", 25, 5)
      assert.are.equal("live", S.status(s))
    end)

    it("a flag pauses a live stand and clearing it brings the stand back", function()
      local s = live(); S.status(s)
      s.flags.combat = true
      assert.are.equal("paused", S.status(s))
      s.flags.combat = false; s.flags.noShards = true
      assert.are.equal("paused", S.status(s))
      s.flags.noShards = false
      assert.are.equal("live", S.status(s))
    end)

    it("a full-strength stand held by a flag is paused, and not yet wasLive", function()
      local s = live(); s.flags.noShards = true
      assert.are.equal("paused", S.status(s))
      assert.is_falsy(s.wasLive)
      s.flags.noShards = false
      assert.are.equal("live", S.status(s))
      assert.is_true(s.wasLive)
    end)

    it("a mage stand is never recruiting", function()
      local s = mage()
      assert.are.equal("live", S.status(s))
      assert.is_true(s.wasLive)
      s.flags.combat = true
      assert.are.equal("paused", S.status(s))
    end)

    it("changes nothing but wasLive", function()
      local s = live()
      local expected = ns.Util.copy(s)
      S.status(s); S.status(s)
      expected.wasLive = true
      assert.are.same(expected, s)
    end)
  end)

  describe("travelers", function()
    it("seats travelers up to the seat count", function()
      local s = lock()
      assert.are.equal(3, S.seatsFree(s))
      assert.is_true(S.addTraveler(s, "T One"))
      assert.is_true(S.addTraveler(s, "T Two"))
      assert.is_true(S.addTraveler(s, "T Three"))
      assert.are.equal(0, S.seatsFree(s))
      assert.are.same({nil, "full"}, {S.addTraveler(s, "T Four")})
      assert.are.same({"T One", "T Two", "T Three"}, s.travelers)
    end)

    it("seating the same traveler twice takes one seat", function()
      local s = lock()
      S.addTraveler(s, "T One"); assert.is_true(S.addTraveler(s, " T  One "))
      assert.are.equal(2, S.seatsFree(s))
      assert.are.same({"T One"}, s.travelers)
    end)

    it("removes by full name and frees the seat, keeping order", function()
      local s = lock()
      S.addTraveler(s, "T One"); S.addTraveler(s, "T Two"); S.addTraveler(s, "T Three")
      S.removeTraveler(s, "T")
      S.removeTraveler(s, "T Four")
      assert.are.equal(0, S.seatsFree(s))
      S.removeTraveler(s, "T Two")
      assert.are.same({"T One", "T Three"}, s.travelers)
      assert.are.equal(1, S.seatsFree(s))
    end)
  end)

  describe("group size", function()
    it("counts the owner, clickers, travelers and the extra", function()
      local s = lock()
      assert.are.equal(1, S.groupSizeWith(s, 0))
      assert.are.equal(2, S.groupSizeWith(s, 1))
      S.addClicker(s, "C One", 25, 1); S.addClicker(s, "C Two", 25, 1)
      S.addTraveler(s, "T One")
      assert.are.equal(4, S.groupSizeWith(s, 0))
      assert.are.equal(5, S.groupSizeWith(s, 1))
    end)

    it("needs a raid only above five", function()
      local s = lock()
      S.addClicker(s, "C One", 25, 1); S.addClicker(s, "C Two", 25, 1)
      S.addTraveler(s, "T One"); S.addTraveler(s, "T Two")
      assert.are.equal(5, S.groupSizeWith(s, 0))
      assert.is_false(S.needsRaid(s, 0))
      assert.is_true(S.needsRaid(s, 1))
    end)

    it("a mage stand's group is the mage and the travelers", function()
      local s = mage()
      S.addTraveler(s, "T One")
      assert.are.equal(2, S.groupSizeWith(s, 0))
    end)
  end)

  describe("movedTooFar", function()
    it("measures from the stand's own position", function()
      local s = S.new{standId="s3", owner="A B", kind="lock", faction="Alliance", wx=100, wy=200, now=0}
      assert.is_false(S.movedTooFar(s, 100, 200))
      assert.is_false(S.movedTooFar(s, 130, 240))   -- exactly 50 yards: not too far
      assert.is_true(S.movedTooFar(s, 100, 251))
      assert.is_true(S.movedTooFar(s, 60, 160))
    end)
  end)

  describe("wire fields", function()
    it("toFields yields exactly the STAND schema's fields", function()
      local expected = {}
      for _, field in ipairs(ns.Protocol.SCHEMAS.STAND) do expected[#expected + 1] = field[1] end
      local keys = {}
      for k in pairs(S.toFields(mage())) do keys[#keys + 1] = k end
      table.sort(keys); table.sort(expected)
      assert.are.same(expected, keys)
    end)

    it("toFields reports the live seat and clicker counts", function()
      local s = lock()
      S.addClicker(s, "C One", 25, 1); S.addClicker(s, "C Two", 25, 1)
      S.addTraveler(s, "T One")
      local f = S.toFields(s)
      assert.are.equal(2, f.seatsFree)
      assert.are.equal(2, f.clickers)
      assert.are.equal(25, f.clickerPct)
      assert.are.equal("s1", f.standId)
      assert.are.equal("Gadgetzan", f.subzone)
      assert.is_nil(f.owner)
    end)

    it("portals is always a table, empty for a lock stand", function()
      assert.are.same({}, S.toFields(lock()).portals)
      assert.are.same({"stormwind", "ironforge"}, S.toFields(mage()).portals)
    end)

    it("toFields carries the stand's status (R69)", function()
      local s = lock()
      assert.are.equal("recruiting", S.toFields(s).status)
      S.addClicker(s, "C One", 25, 1); S.addClicker(s, "C Two", 25, 1)
      assert.are.equal("live", S.toFields(s).status)
      S.removeClicker(s, "C Two")
      assert.are.equal("paused", S.toFields(s).status) -- it was live: toFields asked Stand.status
      assert.are.equal("live", S.toFields(mage()).status)
    end)

    it("fromFields takes recruiting, live or paused, and treats anything else as paused (R69)", function()
      local function statusOf(kind, status)
        local f = S.toFields(kind == "mage" and mage() or lock())
        f.status = status
        return S.fromFields(f, "Real Sender", 5).status
      end
      for _, status in ipairs({"recruiting", "live", "paused"}) do
        assert.are.equal(status, statusOf("lock", status), status)
      end
      assert.are.equal("paused", statusOf("lock", nil))
      assert.are.equal("paused", statusOf("lock", "closed"))
      assert.are.equal("paused", statusOf("lock", "LIVE"))
      assert.are.same({"live", "paused", "paused", "paused"},
        {statusOf("mage", "live"), statusOf("mage", "paused"), statusOf("mage", "recruiting"), statusOf("mage", nil)})
    end)

    it("toFields does not leak the stand's own portals table", function()
      local s = mage()
      local f = S.toFields(s)
      f.portals[#f.portals + 1] = "undercity"
      assert.are.same({"stormwind", "ironforge"}, s.portals)
    end)

    it("survives the wire and takes its owner from the sender", function()
      local s = mage()
      S.addTraveler(s, "T One")
      local text = ns.Protocol.encode("STAND", "id1", S.toFields(s))
      local msg = ns.Protocol.decode(text)
      local v = S.fromFields(msg, "Mia Mage", 42)
      assert.are.equal("Mia Mage", v.owner)
      assert.are.equal(42, v.seenAt)
      assert.are.equal("m1", v.standId)
      assert.are.equal("mage", v.kind)
      assert.are.equal("Horde", v.faction)
      assert.are.equal(1411, v.mapID)
      assert.are.equal(0.5, v.x)
      assert.are.equal(20, v.wy)
      assert.are.equal("Orgrimmar", v.zone)
      assert.are.equal(2, v.seatsFree)
      assert.are.equal(0, v.clickers)
      assert.are.same({"stormwind", "ironforge"}, v.portals)
      assert.are.equal("portals", v.note)
    end)

    it("fromFields carries every STAND schema field into the view", function()
      local f = {}
      for i, field in ipairs(ns.Protocol.SCHEMAS.STAND) do
        local name, kind = field[1], field[2]
        f[name] = kind == "n" and i or kind == "L" and {"p" .. i} or "v" .. i
      end
      f.kind, f.status = "lock", "recruiting" -- a status fromFields keeps for that kind (R69)
      local v = S.fromFields(f, "Real Sender", 5)
      for _, field in ipairs(ns.Protocol.SCHEMAS.STAND) do
        assert.are.same(f[field[1]], v[field[1]], field[1])
      end
    end)

    it("never trusts an owner-like value inside the message", function()
      local f = S.toFields(lock())
      f.owner = "Evil Twin"; f.sender = "Evil Twin"; f.author = "Evil Twin"; f.seenAt = 999
      local v = S.fromFields(f, "Real Sender", 5)
      assert.are.equal("Real Sender", v.owner)
      assert.are.equal(5, v.seenAt)
      assert.is_nil(v.sender)
      assert.is_nil(v.author)
    end)

    it("shows the receiver's own name for the stand's map, keeping the wire zone aside (R65)", function()
      local f = S.toFields(lock())
      f.zone = "Ironforge"
      local v = S.fromFields(f, "Real Sender", 5, "Searing Gorge")
      assert.are.same({"Searing Gorge", "Ironforge"}, {v.zone, v.wireZone})
      v = S.fromFields(f, "Real Sender", 5, nil) -- no local name for the map: the wire text
      assert.are.same({"Ironforge", "Ironforge"}, {v.zone, v.wireZone})
      v = S.fromFields(f, "Real Sender", 5, "  ") -- a blank name is no name
      assert.are.equal("Ironforge", v.zone)
    end)

    it("gives the view a table for portals even when the field is missing", function()
      local f = S.toFields(lock()); f.portals = nil
      assert.are.same({}, S.fromFields(f, "Real Sender", 5).portals)
    end)
  end)
end)
