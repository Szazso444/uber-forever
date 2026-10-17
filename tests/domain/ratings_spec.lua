describe("Ratings", function()
  local ns, R, db

  local DAY = 86400
  local T0 = 1000 * DAY -- the start of a day

  before_each(function()
    ns = Taxi.load()
    R = ns.Ratings
    db = ns.Store.init(nil)
  end)

  local function round1(x)
    return math.floor(x * 10 + 0.5) / 10
  end

  -- score and stars are floats: compare with a small tolerance.
  local function near(expected, actual, message)
    assert.is_true(
      type(actual) == "number" and math.abs(expected - actual) < 1e-9,
      (message or "") .. " expected " .. tostring(expected) .. ", got " .. tostring(actual)
    )
  end

  -- Recursive copy, so a test can prove a table was left exactly as it was.
  local function deepCopy(v)
    if type(v) ~= "table" then
      return v
    end
    local out = {}
    for k, x in pairs(v) do
      out[k] = deepCopy(x)
    end
    return out
  end

  -- A trust rating of "Ana Smith". Every helper below uses T0 unless told otherwise.
  local function trust(rater, stars, id, ts)
    return { kind = "trust", rater = rater, target = "Ana Smith", stars = stars, id = id, ts = ts or T0 }
  end

  local function share(rater, stars, id, ts)
    return { kind = "share", rater = rater, target = "Ana Smith", stars = stars, id = id, ts = ts or T0 }
  end

  -- Add a direct rating the way its rater would send it.
  local function direct(rec)
    return R.addDirect(db, rec, rec.rater)
  end

  local function trustSummary()
    return R.summary(db, "Ana Smith", "trust")
  end

  local function shareSummary()
    return R.summary(db, "Ana Smith", "share")
  end

  local function trustList()
    return db.ratings["Ana Smith"].trust
  end

  describe("addDirect", function()
    it("rejects not_rater", function()
      local ok, why = R.addDirect(db, trust("Bob Jones", 5, "r1"), "Eve Mallory")
      assert.is_nil(ok)
      assert.are.equal("not_rater", why)
      assert.is_nil(db.ratings["Ana Smith"])
    end)

    it("takes a missing sender, or a first name alone, for not_rater", function()
      local _, why = R.addDirect(db, trust("Bob Jones", 5, "r1"), nil)
      assert.are.equal("not_rater", why)
      _, why = R.addDirect(db, trust("Bob Jones", 5, "r1"), "Bob")
      assert.are.equal("not_rater", why)
      _, why = R.addDirect(db, trust("Bob Jones", 5, "r1"), "")
      assert.are.equal("not_rater", why)
    end)

    it("accepts a rating sent by its rater", function()
      assert.is_true(R.addDirect(db, trust("Bob Jones", 5, "r1"), "Bob Jones"))
      assert.are.equal(1, #trustList())
      local stored = trustList()[1]
      assert.are.equal("trust", stored.kind)
      assert.are.equal("Bob Jones", stored.rater)
      assert.are.equal("Ana Smith", stored.target)
      assert.are.equal(5, stored.stars)
      assert.are.equal("r1", stored.id)
      assert.are.equal(T0, stored.ts)
      assert.is_nil(stored.via)
    end)

    it("rejects bad_stars for 0, 6 and 4.5, and for anything that is not a whole number", function()
      for _, bad in ipairs({ 0, 6, 4.5, -1, "5", true, 0 / 0, math.huge }) do
        local ok, why = direct(trust("Bob Jones", bad, "r1"))
        assert.is_nil(ok, tostring(bad))
        assert.are.equal("bad_stars", why, tostring(bad))
      end
      local ok, why = direct(trust("Bob Jones", nil, "r1"))
      assert.is_nil(ok)
      assert.are.equal("bad_stars", why)
      assert.is_nil(db.ratings["Ana Smith"])
    end)

    it("accepts every whole number of stars from 1 to 5", function()
      for stars = 1, 5 do
        assert.is_true(direct(trust("Rater " .. stars, stars, "r" .. stars)))
      end
      assert.are.equal(5, #trustList())
    end)

    it("rejects a record missing its kind, rater or target as bad_record", function()
      local function without(field)
        local rec = trust("Bob Jones", 5, "r1")
        rec[field] = nil
        return rec
      end
      for _, field in ipairs({ "kind", "rater", "target" }) do
        local ok, why = R.addDirect(db, without(field), "Bob Jones")
        assert.is_nil(ok, field)
        assert.are.equal("bad_record", why, field)
      end
      local ok, why = R.addDirect(db, nil, "Bob Jones")
      assert.is_nil(ok)
      assert.are.equal("bad_record", why)
      ok, why = R.addDirect(db, "trust", "Bob Jones")
      assert.is_nil(ok)
      assert.are.equal("bad_record", why)
    end)

    it("rejects a kind that is not trust or share, a blank name, a bad id or a bad ts as bad_record", function()
      local cases = {
        function(r) r.kind = "death" end,
        function(r) r.kind = "ridelog" end,
        function(r) r.kind = 7 end,
        function(r) r.target = "" end,
        function(r) r.id = "" end,
        function(r) r.id = 12 end,
        function(r) r.id = false end,
        function(r) r.id = nil end,
        function(r) r.ts = nil end,
        function(r) r.ts = "now" end,
        function(r) r.ts = 0 / 0 end,
        function(r) r.ts = math.huge end,
      }
      for i, change in ipairs(cases) do
        local rec = trust("Bob Jones", 5, "r1")
        change(rec)
        local ok, why = R.addDirect(db, rec, "Bob Jones")
        assert.is_nil(ok, "case " .. i)
        assert.are.equal("bad_record", why, "case " .. i)
      end
      local ok, why = R.addDirect(db, trust("   ", 5, "r1"), "   ")
      assert.is_nil(ok)
      assert.are.equal("bad_record", why)
      assert.is_nil(db.ratings["Ana Smith"])
    end)

    it("rejects a warlock rating themselves", function()
      local rec = trust("Ana Smith", 5, "r1")
      local ok, why = direct(rec)
      assert.is_nil(ok)
      assert.are.equal("bad_record", why)
      assert.is_nil(db.ratings["Ana Smith"])
    end)

    it("rejects a rater marked as a liar", function()
      R.markLiar(db, "Bob Jones", T0)
      local ok, why = direct(trust("Bob Jones", 5, "r1"))
      assert.is_nil(ok)
      assert.are.equal("liar", why)
      assert.is_nil(db.ratings["Ana Smith"])
    end)

    it("stores names normalized, so spacing never makes a second warlock", function()
      local rec = trust(" Bob   Jones ", 4, "r1")
      rec.target = " Ana  Smith "
      assert.is_true(R.addDirect(db, rec, "Bob Jones"))
      assert.are.equal(1, #trustList())
      assert.are.equal("Bob Jones", trustList()[1].rater)
      assert.are.equal("Ana Smith", trustList()[1].target)
      assert.is_true(direct(trust("Bob Jones", 2, "r1", T0 + 60)))
      assert.are.equal(1, #trustList())
      assert.are.equal(2, trustList()[1].stars)
      assert.are.equal(2, R.summary(db, "  Ana   Smith", "trust").stars)
    end)

    it("does not keep the caller's table", function()
      local rec = trust("Bob Jones", 5, "r1")
      assert.is_true(direct(rec))
      rec.stars = 1
      rec.via = { ["Eve Mallory"] = true }
      assert.are.equal(5, trustList()[1].stars)
      assert.is_nil(trustList()[1].via)
    end)

    it("one per day keeps newest", function()
      assert.is_true(direct(trust("Bob Jones", 5, "r1", T0 + 100)))
      assert.is_true(direct(trust("Bob Jones", 2, "r2", T0 + 500)))
      assert.are.equal(1, #trustList())
      assert.are.equal(2, trustList()[1].stars)
      assert.are.equal("r2", trustList()[1].id)
    end)

    it("keeps the newer rating when an older one arrives afterwards", function()
      assert.is_true(direct(trust("Bob Jones", 2, "r2", T0 + 500)))
      assert.is_true(direct(trust("Bob Jones", 5, "r1", T0 + 100)))
      assert.are.equal(1, #trustList())
      assert.are.equal(2, trustList()[1].stars)
      assert.are.equal("r2", trustList()[1].id)
    end)

    it("keeps ratings from different days, raters and kinds apart", function()
      assert.is_true(direct(trust("Bob Jones", 5, "r1", T0)))
      assert.is_true(direct(trust("Bob Jones", 4, "r2", T0 + DAY)))
      assert.is_true(direct(trust("Cal Dunn", 3, "r3", T0)))
      assert.is_true(direct(share("Bob Jones", 2, "r1", T0)))
      assert.are.equal(3, #trustList())
      assert.are.equal(1, #db.ratings["Ana Smith"].share)
    end)

    it("replaces the same ride id on re-send", function()
      assert.is_true(direct(trust("Bob Jones", 5, "r1", T0)))
      assert.is_true(direct(trust("Bob Jones", 3, "r1", T0 + 10)))
      assert.are.equal(1, #trustList())
      assert.are.equal(3, trustList()[1].stars)
    end)

    it("keeps share amounts, and only on share ratings", function()
      local rec = share("Cal Dunn", 4, "r1")
      rec.owed, rec.received, rec.pct = 100, 90, 25
      assert.is_true(direct(rec))
      local stored = db.ratings["Ana Smith"].share[1]
      assert.are.equal(100, stored.owed)
      assert.are.equal(90, stored.received)
      assert.are.equal(25, stored.pct)

      local t = trust("Bob Jones", 4, "r2")
      t.owed = 100
      assert.is_true(direct(t))
      assert.is_nil(trustList()[1].owed)
    end)

    it("rejects share amounts that are negative, not finite or not numbers", function()
      for _, field in ipairs({ "owed", "received", "pct" }) do
        for _, bad in ipairs({ -1, 0 / 0, math.huge, "10", true }) do
          local rec = share("Cal Dunn", 4, "r1")
          rec[field] = bad
          local ok, why = direct(rec)
          assert.is_nil(ok, field .. " " .. tostring(bad))
          assert.are.equal("bad_record", why, field .. " " .. tostring(bad))
        end
      end
      assert.is_nil(db.ratings["Ana Smith"])
    end)

    it("accepts share amounts of zero", function()
      local rec = share("Cal Dunn", 4, "r1")
      rec.owed, rec.received, rec.pct = 0, 0, 0
      assert.is_true(direct(rec))
    end)
  end)

  describe("addRelayed", function()
    it("takes a relayed rating at low weight", function()
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Ay"))
      assert.are.same({ ["Rel Ay"] = true }, trustList()[1].via)
      local s = trustSummary()
      assert.are.equal(5, s.stars)
      near((5 * 3.5 + 0.2 * 5) / (5 + 0.2), s.score, "score")
    end)

    it("relayed low weight: a relayed 5 star counts 0.2 next to a one-sided 1 star at 0.3", function()
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Ay"))
      assert.is_true(direct(trust("Bob Jones", 1, "r2")))
      local s = trustSummary()
      near(round1((0.2 * 5 + 0.3 * 1) / 0.5), s.stars, "stars")
      near(2.6, s.stars, "stars")
      near((5 * 3.5 + 0.2 * 5 + 0.3 * 1) / (5 + 0.5), s.score, "score")
    end)

    it("three relayers of the same record give 0.5", function()
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Ay"))
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Bee"))
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Cee"))
      assert.are.equal(1, #trustList())
      assert.is_true(direct(trust("Bob Jones", 1, "r2")))
      local s = trustSummary()
      near(round1((0.5 * 5 + 0.3 * 1) / 0.8), s.stars, "stars")
      near(3.5, s.stars, "stars")
      near((5 * 3.5 + 0.5 * 5 + 0.3 * 1) / (5 + 0.8), s.score, "score")
    end)

    it("two relayers are still 0.2", function()
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Ay"))
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Bee"))
      assert.is_true(direct(trust("Bob Jones", 1, "r2")))
      near(2.6, trustSummary().stars, "stars")
    end)

    it("counts one relayer once, however often it repeats itself", function()
      for _ = 1, 4 do
        assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Ay"))
      end
      assert.is_true(direct(trust("Bob Jones", 1, "r2")))
      near(2.6, trustSummary().stars, "stars")
    end)

    it("upgrade: a relayed record followed by the same direct one leaves via nil", function()
      assert.is_true(R.addRelayed(db, trust("Bob Jones", 4, "r1"), "Rel Ay"))
      assert.is_true(direct(trust("Bob Jones", 4, "r1")))
      assert.are.equal(1, #trustList())
      assert.is_nil(trustList()[1].via)
      near((5 * 3.5 + 0.3 * 4) / (5 + 0.3), trustSummary().score, "now a direct one-sided rating")
      assert.is_nil(db.strikes["Rel Ay"])
    end)

    it("contradiction strikes: relayed 5 star via Rel Ay, then the direct 1 star", function()
      assert.is_true(R.addRelayed(db, trust("Bob Jones", 5, "r1"), "Rel Ay"))
      assert.is_true(direct(trust("Bob Jones", 1, "r1")))
      assert.are.equal(1, db.strikes["Rel Ay"])
      assert.are.equal(1, #trustList())
      assert.is_nil(trustList()[1].via)
      assert.are.equal(1, trustSummary().stars)
    end)

    it("strikes every relayer of a contradicted copy", function()
      assert.is_true(R.addRelayed(db, trust("Bob Jones", 5, "r1"), "Rel Ay"))
      assert.is_true(R.addRelayed(db, trust("Bob Jones", 5, "r1"), "Rel Bee"))
      assert.is_true(R.addRelayed(db, trust("Bob Jones", 5, "r1"), "Rel Cee"))
      assert.is_true(direct(trust("Bob Jones", 2, "r1")))
      assert.are.equal(1, db.strikes["Rel Ay"])
      assert.are.equal(1, db.strikes["Rel Bee"])
      assert.are.equal(1, db.strikes["Rel Cee"])
    end)

    it("rejects a relayed copy that contradicts a direct one, and strikes the relayer", function()
      assert.is_true(direct(trust("Bob Jones", 1, "r1")))
      local ok, why = R.addRelayed(db, trust("Bob Jones", 5, "r1"), "Rel Ay")
      assert.is_nil(ok)
      assert.are.equal("contradicts_direct", why)
      assert.are.equal(1, db.strikes["Rel Ay"])
      assert.are.equal(1, #trustList())
      assert.are.equal(1, trustList()[1].stars)
    end)

    it("rejects a relayed copy of a direct record as has_direct, without a strike", function()
      assert.is_true(direct(trust("Bob Jones", 4, "r1")))
      local ok, why = R.addRelayed(db, trust("Bob Jones", 4, "r1"), "Rel Ay")
      assert.is_nil(ok)
      assert.are.equal("has_direct", why)
      assert.is_nil(db.strikes["Rel Ay"])
      assert.is_nil(trustList()[1].via)
    end)

    it("rejects a relayed copy for a day the rater already rated directly", function()
      assert.is_true(direct(trust("Bob Jones", 4, "r1", T0)))
      local ok, why = R.addRelayed(db, trust("Bob Jones", 1, "r9", T0 + 60), "Rel Ay")
      assert.is_nil(ok)
      assert.are.equal("has_direct", why)
      assert.is_nil(db.strikes["Rel Ay"])
      assert.are.equal(1, #trustList())
    end)

    it("keeps the first relayed version when another has different stars, with no strike", function()
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Ay"))
      local ok, why = R.addRelayed(db, trust("Dan Eve", 1, "r1"), "Rel Bee")
      assert.is_nil(ok)
      assert.are.equal("conflict", why)
      assert.is_nil(db.strikes["Rel Ay"])
      assert.is_nil(db.strikes["Rel Bee"])
      assert.are.equal(1, #trustList())
      assert.are.equal(5, trustList()[1].stars)
      assert.are.same({ ["Rel Ay"] = true }, trustList()[1].via)
    end)

    it("keeps one relayed record per rater and day", function()
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1", T0), "Rel Ay"))
      local ok, why = R.addRelayed(db, trust("Dan Eve", 5, "r2", T0 + 60), "Rel Bee")
      assert.is_nil(ok)
      assert.are.equal("conflict", why)
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r3", T0 + DAY), "Rel Bee"))
      assert.are.equal(2, #trustList())
    end)

    it("takes a direct rating over a relayed one of the same day", function()
      assert.is_true(R.addRelayed(db, trust("Bob Jones", 5, "r1", T0), "Rel Ay"))
      assert.is_true(direct(trust("Bob Jones", 2, "r2", T0 + 60)))
      assert.are.equal(1, #trustList())
      assert.are.equal("r2", trustList()[1].id)
      assert.is_nil(db.strikes["Rel Ay"])
    end)

    it("takes a rater relaying their own rating as a direct one", function()
      assert.is_true(R.addRelayed(db, trust("Bob Jones", 4, "r1"), "Bob Jones"))
      assert.is_nil(trustList()[1].via)
    end)

    it("three strikes ignored: a struck relayer is refused and its relays stop counting", function()
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Ay"))
      assert.are.equal(5, trustSummary().stars)
      R.strike(db, "Rel Ay")
      R.strike(db, "Rel Ay")
      assert.are.equal(5, trustSummary().stars)
      assert.is_true(R.addRelayed(db, trust("Gus Hill", 5, "r2"), "Rel Ay"))
      R.strike(db, "Rel Ay")
      assert.are.equal(3, db.strikes["Rel Ay"])

      local ok, why = R.addRelayed(db, trust("Hal Ward", 5, "r3"), "Rel Ay")
      assert.is_nil(ok)
      assert.are.equal("struck", why)

      local s = trustSummary()
      assert.is_nil(s.stars)
      assert.are.equal(0, s.count)
      near(3.5, s.score, "score")
      assert.are.equal(2, #trustList(), "the records are kept, only their influence goes")
    end)

    it("three contradicted relays make a relayer struck", function()
      for i = 1, 3 do
        assert.is_true(R.addRelayed(db, trust("Rater " .. i, 5, "r" .. i), "Rel Ay"))
        assert.is_true(direct(trust("Rater " .. i, 1, "r" .. i)))
      end
      assert.are.equal(3, db.strikes["Rel Ay"])
      local ok, why = R.addRelayed(db, trust("Dan Eve", 5, "r9"), "Rel Ay")
      assert.is_nil(ok)
      assert.are.equal("struck", why)
    end)

    it("takes a struck relayer out of via, so a corroborated record falls back to 0.2", function()
      for _, relayer in ipairs({ "Rel Ay", "Rel Bee", "Rel Cee" }) do
        assert.is_true(R.addRelayed(db, trust("Dan Eve", 5, "r1"), relayer))
      end
      assert.is_true(direct(trust("Bob Jones", 1, "r2")))
      near(3.5, trustSummary().stars, "three live relayers")
      for _ = 1, 3 do
        R.strike(db, "Rel Cee")
      end
      near(2.6, trustSummary().stars, "two live relayers")
      R.markLiar(db, "Rel Bee", T0)
      R.markLiar(db, "Rel Ay", T0)
      assert.are.equal(1, trustSummary().stars, "no live relayer: only the direct rating is left")
    end)

    it("rejects a liar as rater or relayer", function()
      R.markLiar(db, "Dan Eve", T0)
      local ok, why = R.addRelayed(db, trust("Dan Eve", 5, "r1"), "Rel Ay")
      assert.is_nil(ok)
      assert.are.equal("liar", why)

      R.markLiar(db, "Rel Bee", T0)
      ok, why = R.addRelayed(db, trust("Gus Hill", 5, "r2"), "Rel Bee")
      assert.is_nil(ok)
      assert.are.equal("liar", why)
      assert.is_nil(db.ratings["Ana Smith"])
    end)

    it("rejects bad stars, bad records and a missing relayer", function()
      local ok, why = R.addRelayed(db, trust("Dan Eve", 7, "r1"), "Rel Ay")
      assert.is_nil(ok)
      assert.are.equal("bad_stars", why)
      ok, why = R.addRelayed(db, trust("Dan Eve", 5, ""), "Rel Ay")
      assert.is_nil(ok)
      assert.are.equal("bad_record", why)
      ok, why = R.addRelayed(db, trust("Dan Eve", 5, "r1"), nil)
      assert.is_nil(ok)
      assert.are.equal("bad_record", why)
      ok, why = R.addRelayed(db, nil, "Rel Ay")
      assert.is_nil(ok)
      assert.are.equal("bad_record", why)
      assert.is_nil(db.ratings["Ana Smith"])
    end)

    it("takes relayed share ratings at 0.2 too", function()
      assert.is_true(R.addRelayed(db, share("Dan Eve", 5, "r1"), "Rel Ay"))
      assert.is_true(direct(share("Cal Dunn", 1, "r2")))
      near(round1((0.2 * 5 + 1.0 * 1) / 1.2), shareSummary().stars, "stars")
    end)
  end)

  describe("summary", function()
    it("two-sided weight: a ride log makes the rating count 1.0, otherwise 0.3", function()
      assert.is_true(R.addRideLog(db, "Ana Smith", "r1", T0, "Bob Jones"))
      assert.is_true(direct(trust("Bob Jones", 5, "r1")))
      assert.is_true(direct(trust("Cal Dunn", 1, "r2")))
      local s = trustSummary()
      near(round1((5 * 1.0 + 1 * 0.3) / 1.3), s.stars, "stars")
      near(4.1, s.stars, "stars")
      near((5 * 3.5 + 5 * 1.0 + 1 * 0.3) / (5 + 1.3), s.score, "score")
      assert.are.equal(2, s.count)
    end)

    it("prior: a single 5 star two-sided rating scores 3.75 and is New", function()
      assert.is_true(R.addRideLog(db, "Ana Smith", "r1", T0, "Bob Jones"))
      assert.is_true(direct(trust("Bob Jones", 5, "r1")))
      local s = trustSummary()
      near((5 * 3.5 + 5) / (5 + 1), s.score, "score")
      near(3.75, s.score, "score")
      assert.are.equal(5, s.stars)
      assert.is_true(s.isNew)
      assert.are.equal(1, s.count)
      assert.are.equal(0, s.deathsReported)
    end)

    it("shows no stars and the prior mean for a warlock nobody rated", function()
      local s = R.summary(db, "Nobody Here", "trust")
      assert.is_nil(s.stars)
      near(3.5, s.score, "score")
      assert.are.equal(0, s.count)
      assert.is_true(s.isNew)
      assert.are.equal(0, s.deathsReported)
    end)

    it("creates nothing when it reads", function()
      local before = deepCopy(db)
      R.summary(db, "Nobody Here", "trust")
      R.summary(db, "Nobody Here", "share")
      assert.are.same(before, db)
      assert.is_nil(db.ratings["Nobody Here"])
    end)

    it("refuses a kind that is not trust or share", function()
      assert.has_error(function()
        R.summary(db, "Ana Smith", "death")
      end)
    end)

    it("is not New from five ratings up", function()
      for i = 1, 4 do
        assert.is_true(direct(trust("Rater " .. i, 4, "r" .. i)))
      end
      assert.is_true(trustSummary().isNew)
      assert.is_true(direct(trust("Rater 5", 4, "r5")))
      assert.is_false(trustSummary().isNew)
      assert.are.equal(5, trustSummary().count)
    end)

    it("liar ignored: markLiar on a rater removes their records from the summary", function()
      assert.is_true(direct(trust("Bob Jones", 5, "r1")))
      assert.is_true(direct(trust("Cal Dunn", 1, "r2")))
      assert.is_true(direct(share("Bob Jones", 5, "r3")))
      assert.is_true(R.addRelayed(db, trust("Bob Jones", 5, "r4", T0 + DAY), "Rel Ay"))
      R.markLiar(db, "Bob Jones", T0 + 5)
      local s = trustSummary()
      assert.are.equal(1, s.stars)
      assert.are.equal(1, s.count)
      assert.is_nil(shareSummary().stars)
      assert.are.equal(0, shareSummary().count)
      assert.are.equal(4, #trustList() + #db.ratings["Ana Smith"].share, "nothing is deleted")
    end)

    it("scores share ratings at 1.0 for a direct one, whatever the ride logs say", function()
      assert.is_true(direct(share("Cal Dunn", 5, "r1")))
      assert.is_true(direct(share("Eve Gray", 3, "r2")))
      local s = shareSummary()
      near(4.0, s.stars, "stars")
      near((5 * 3.5 + 5 + 3) / (5 + 2), s.score, "score")
      assert.are.equal(2, s.count)
      assert.is_true(s.isNew)
      assert.are.equal(0, s.deathsReported)
    end)

    it("ignores the other kind", function()
      assert.is_true(direct(trust("Bob Jones", 5, "r1")))
      assert.is_nil(shareSummary().stars)
      assert.are.equal(0, shareSummary().count)
    end)

    it("count includes receipts: distinct ids across ratings, deaths and receipts", function()
      assert.is_true(direct(trust("Bob Jones", 5, "r1")))
      assert.is_true(R.addDeath(db, { target = "Ana Smith", victim = "Cal Dunn", id = "r2", ts = T0, heavy = true }))
      assert.is_true(R.addReceipt(db, "Ana Smith", "r1", T0))
      assert.is_true(R.addReceipt(db, "Ana Smith", "r3", T0))
      assert.is_true(R.addReceipt(db, "Ana Smith", "r4", T0))
      local s = trustSummary()
      assert.are.equal(4, s.count)
      assert.is_true(s.isNew)
    end)

    it("does not let receipts make a warlock less New", function()
      for i = 1, 4 do
        assert.is_true(direct(trust("Rater " .. i, 4, "r" .. i)))
      end
      for i = 5, 7 do
        assert.is_true(R.addReceipt(db, "Ana Smith", "r" .. i, T0))
      end
      local s = trustSummary()
      assert.are.equal(7, s.count)
      assert.is_true(s.isNew)
    end)

    it("keeps receipts out of the share count", function()
      assert.is_true(R.addReceipt(db, "Ana Smith", "r1", T0))
      assert.are.equal(0, shareSummary().count)
      assert.are.equal(1, trustSummary().count)
    end)
  end)

  describe("deaths", function()
    local function death(fields)
      local d = { target = "Ana Smith", victim = "Cal Dunn", id = "r1", ts = T0, heavy = true }
      for k, v in pairs(fields or {}) do
        d[k] = v
      end
      return d
    end

    it("heavy death: one heavy death and no ratings gives 1 star", function()
      assert.is_true(R.addDeath(db, death()))
      local s = trustSummary()
      assert.are.equal(1, s.stars)
      near((5 * 3.5 + 5.0 * 1) / (5 + 5.0), s.score, "score")
      near(2.25, s.score, "score")
      assert.are.equal(1, s.deathsReported)
      assert.are.equal(1, s.count)
      assert.is_true(s.isNew)
    end)

    it("weighs a heavy death at 5 against a two-sided 5 star rating", function()
      assert.is_true(R.addRideLog(db, "Ana Smith", "r2", T0, "Bob Jones"))
      assert.is_true(direct(trust("Bob Jones", 5, "r2")))
      assert.is_true(R.addDeath(db, death()))
      local s = trustSummary()
      near(round1((5 * 1.0 + 1 * 5.0) / 6.0), s.stars, "stars")
      near(1.7, s.stars, "stars")
    end)

    it("light death: counts at 0.2", function()
      assert.is_true(R.addRideLog(db, "Ana Smith", "r2", T0, "Bob Jones"))
      assert.is_true(direct(trust("Bob Jones", 5, "r2")))
      assert.is_true(R.addDeath(db, death({ heavy = false, via = { ["Rel Ay"] = true } })))
      local s = trustSummary()
      near(round1((5 * 1.0 + 1 * 0.2) / 1.2), s.stars, "stars")
      near(4.3, s.stars, "stars")
      near((5 * 3.5 + 5 * 1.0 + 1 * 0.2) / (5 + 1.2), s.score, "score")
      assert.are.equal(1, s.deathsReported)
    end)

    it("counts a light death with no relayer, which this client saw itself, at 0.2", function()
      assert.is_true(R.addRideLog(db, "Ana Smith", "r2", T0, "Bob Jones"))
      assert.is_true(direct(trust("Bob Jones", 5, "r2")))
      assert.is_true(R.addDeath(db, death({ heavy = false })))
      near(4.3, trustSummary().stars, "stars")
    end)

    it("heavy replaces light", function()
      assert.is_true(R.addDeath(db, death({ heavy = false, via = { ["Rel Ay"] = true } })))
      assert.is_true(R.addDeath(db, death({ heavy = true })))
      local d = db.deaths["Ana Smith"].r1
      assert.is_true(d.heavy)
      assert.is_nil(d.via)
      near((5 * 3.5 + 5.0) / (5 + 5.0), trustSummary().score, "score")
      assert.are.equal(1, trustSummary().deathsReported)
    end)

    it("never lets a light death replace a heavy one", function()
      assert.is_true(R.addDeath(db, death({ heavy = true })))
      assert.is_true(R.addDeath(db, death({ heavy = false, via = { ["Rel Ay"] = true } })))
      assert.is_true(db.deaths["Ana Smith"].r1.heavy)
      near(2.25, trustSummary().score, "score")
    end)

    it("adds up the relayers of a light death", function()
      assert.is_true(R.addDeath(db, death({ heavy = false, via = { ["Rel Ay"] = true } })))
      assert.is_true(R.addDeath(db, death({ heavy = false, via = { ["Rel Bee"] = true } })))
      assert.are.same({ ["Rel Ay"] = true, ["Rel Bee"] = true }, db.deaths["Ana Smith"].r1.via)
      for _ = 1, 3 do
        R.strike(db, "Rel Ay")
      end
      assert.are.equal(1, trustSummary().deathsReported, "Rel Bee still stands behind it")
    end)

    it("ignores a light death whose relayers are struck or liars", function()
      assert.is_true(R.addDeath(db, death({ heavy = false, via = { ["Rel Ay"] = true } })))
      assert.is_true(R.addDeath(db, death({ id = "r2", heavy = false, via = { ["Rel Bee"] = true } })))
      for _ = 1, 3 do
        R.strike(db, "Rel Ay")
      end
      R.markLiar(db, "Rel Bee", T0)
      local s = trustSummary()
      assert.is_nil(s.stars)
      assert.are.equal(0, s.deathsReported)
      assert.are.equal(0, s.count)
      assert.is_not_nil(db.deaths["Ana Smith"].r1, "kept, only ignored")
    end)

    it("ignores a death reported by a victim who is a liar", function()
      assert.is_true(R.addDeath(db, death()))
      R.markLiar(db, "Cal Dunn", T0)
      local s = trustSummary()
      assert.is_nil(s.stars)
      assert.are.equal(0, s.deathsReported)
    end)

    it("keeps deaths out of share summaries", function()
      assert.is_true(R.addDeath(db, death()))
      assert.are.equal(0, shareSummary().deathsReported)
      assert.is_nil(shareSummary().stars)
    end)

    it("removeDeath takes a death back", function()
      assert.is_true(R.addDeath(db, death()))
      assert.is_true(R.addDeath(db, death({ id = "r2" })))
      assert.is_true(R.removeDeath(db, "Ana Smith", "r1"))
      assert.is_nil(db.deaths["Ana Smith"].r1)
      assert.are.equal(1, trustSummary().deathsReported)
      assert.is_true(R.removeDeath(db, "Ana Smith", "r2"))
      assert.is_nil(db.deaths["Ana Smith"])
      assert.is_false(R.removeDeath(db, "Ana Smith", "r2"))
      assert.is_false(R.removeDeath(db, "Nobody Here", "r1"))
      assert.is_false(R.removeDeath(db, "Ana Smith", nil))
      assert.are.equal(0, trustSummary().deathsReported)
    end)

    it("stores names normalized and rejects a malformed death", function()
      assert.is_true(R.addDeath(db, death({ target = " Ana  Smith ", victim = "Cal   Dunn " })))
      assert.are.equal("Cal Dunn", db.deaths["Ana Smith"].r1.victim)
      for _, change in ipairs({
        { target = "" }, { victim = "  " }, { id = "" }, { id = 4 }, { ts = "now" }, { ts = 0 / 0 }, { via = "Rel Ay" },
      }) do
        local ok, why = R.addDeath(db, death(change))
        assert.is_nil(ok)
        assert.are.equal("bad_record", why)
      end
      local ok, why = R.addDeath(db, nil)
      assert.is_nil(ok)
      assert.are.equal("bad_record", why)
    end)
  end)

  describe("ride logs and receipts", function()
    it("stores a ride log", function()
      assert.is_true(R.addRideLog(db, "Ana Smith", "r1", T0, "Bob Jones"))
      assert.are.same({ ts = T0, traveler = "Bob Jones" }, db.rideLogs["Ana Smith"].r1)
    end)

    it("stores a receipt", function()
      assert.is_true(R.addReceipt(db, "Ana Smith", "r1", T0))
      assert.are.equal(T0, db.receipts["Ana Smith"].r1)
    end)

    it("normalizes names and rejects malformed input", function()
      assert.is_true(R.addRideLog(db, " Ana  Smith", "r1", T0, "Bob   Jones "))
      assert.are.same({ ts = T0, traveler = "Bob Jones" }, db.rideLogs["Ana Smith"].r1)
      assert.is_true(R.addReceipt(db, "Ana  Smith ", "r1", T0))
      assert.are.equal(T0, db.receipts["Ana Smith"].r1)

      assert.is_nil(R.addRideLog(db, "", "r2", T0, "Bob Jones"))
      assert.is_nil(R.addRideLog(db, "Ana Smith", "", T0, "Bob Jones"))
      assert.is_nil(R.addRideLog(db, "Ana Smith", "r2", "now", "Bob Jones"))
      assert.is_nil(R.addRideLog(db, "Ana Smith", "r2", T0, nil))
      assert.is_nil(R.addReceipt(db, "Ana Smith", 7, T0))
      assert.is_nil(R.addReceipt(db, "Ana Smith", "r2", 0 / 0))
      assert.is_nil(db.rideLogs["Ana Smith"].r2)
      assert.is_nil(db.receipts["Ana Smith"].r2)
    end)
  end)

  describe("strike and markLiar", function()
    it("counts strikes by normalized name", function()
      assert.are.equal(1, R.strike(db, "Rel Ay"))
      assert.are.equal(2, R.strike(db, " Rel  Ay "))
      assert.are.equal(2, db.strikes["Rel Ay"])
    end)

    it("marks a liar with the time", function()
      R.markLiar(db, " Dan   Eve", T0)
      assert.are.equal(T0, db.liars["Dan Eve"])
    end)

    it("still marks a liar when no time is given", function()
      R.markLiar(db, "Dan Eve", nil)
      assert.is_not_nil(db.liars["Dan Eve"])
      local ok, why = direct(trust("Dan Eve", 5, "r1"))
      assert.is_nil(ok)
      assert.are.equal("liar", why)
    end)

    it("ignores a blank name", function()
      assert.is_nil(R.strike(db, "  "))
      assert.is_nil(R.strike(db, nil))
      R.markLiar(db, nil, T0)
      R.markLiar(db, "", T0)
      assert.are.same({}, db.strikes)
      assert.are.same({}, db.liars)
    end)
  end)

  describe("give", function()
    it("appends to given and adds the rating as a direct one", function()
      local rec = share("Bob Jones", 4, "r1")
      rec.owed, rec.received, rec.pct = 100, 90, 25
      assert.is_true(R.give(db, rec))
      assert.are.equal(1, #db.given)
      assert.are.equal("Bob Jones", db.given[1].rater)
      assert.are.equal("Ana Smith", db.given[1].target)
      assert.are.equal("share", db.given[1].kind)
      assert.are.equal(4, db.given[1].stars)
      assert.are.equal(100, db.given[1].owed)
      assert.are.equal(1, #db.ratings["Ana Smith"].share)
      assert.is_nil(db.ratings["Ana Smith"].share[1].via)
    end)

    it("keeps every rating the player gave, even when one replaces another", function()
      assert.is_true(R.give(db, trust("Bob Jones", 5, "r1", T0)))
      assert.is_true(R.give(db, trust("Bob Jones", 2, "r2", T0 + 60)))
      assert.are.equal(2, #db.given)
      assert.are.equal(1, #trustList())
    end)

    it("gives its own copy, so later changes to the rating leave given alone", function()
      assert.is_true(R.give(db, trust("Bob Jones", 5, "r1")))
      db.given[1].stars = 1
      assert.are.equal(5, trustList()[1].stars)
    end)

    it("writes nothing for a rating addDirect refuses", function()
      local ok, why = R.give(db, trust("Bob Jones", 9, "r1"))
      assert.is_nil(ok)
      assert.are.equal("bad_stars", why)
      ok, why = R.give(db, nil)
      assert.is_nil(ok)
      assert.are.equal("bad_record", why)
      assert.are.same({}, db.given)
      assert.is_nil(db.ratings["Ana Smith"])
    end)
  end)

  describe("replyRecords", function()
    local PROTOCOL_FIELDS

    before_each(function()
      PROTOCOL_FIELDS = {}
      for _, field in ipairs(ns.Protocol.RECORD) do
        PROTOCOL_FIELDS[field] = true
      end
    end)

    -- Ana Smith's reputation: two direct ratings, a relayed one, two deaths and
    -- two ride logs of her own, plus a ride log of another warlock.
    local function populate()
      assert.is_true(direct(trust("Bob Jones", 5, "r1", T0 + 10)))
      local rec = share("Cal Dunn", 4, "r2", T0 + 20)
      rec.owed, rec.received, rec.pct = 100, 90, 25
      assert.is_true(direct(rec))
      assert.is_true(R.addRelayed(db, trust("Dan Eve", 3, "r3", T0 + 30), "Rel Ay"))
      assert.is_true(R.addDeath(db, { target = "Ana Smith", victim = "Eve Gray", id = "r4", ts = T0 + 40, heavy = true }))
      assert.is_true(R.addDeath(db, {
        target = "Ana Smith", victim = "Fay Moss", id = "r5", ts = T0 + 50, heavy = false, via = { ["Rel Ay"] = true },
      }))
      assert.is_true(R.addRideLog(db, "Ana Smith", "r1", T0 + 5, "Bob Jones"))
      assert.is_true(R.addRideLog(db, "Ana Smith", "r6", T0 + 60, "Gus Hill"))
      assert.is_true(R.addRideLog(db, "Hal Ward", "r7", T0 + 70, "Ira Cole"))
    end

    it("replyRecords excludes relayed and includes own ride logs when target is me", function()
      populate()
      local recs = R.replyRecords(db, "Ana Smith", "Ana Smith", 50)
      assert.are.equal(5, #recs)
      assert.are.same({ kind = "ridelog", rater = "Ana Smith", id = "r6", ts = T0 + 60, other = "Gus Hill" }, recs[1])
      assert.are.same({ kind = "death", rater = "Eve Gray", id = "r4", ts = T0 + 40, other = "Eve Gray" }, recs[2])
      assert.are.same(
        { kind = "share", rater = "Cal Dunn", stars = 4, id = "r2", ts = T0 + 20, owed = 100, received = 90, pct = 25 },
        recs[3]
      )
      assert.are.same({ kind = "trust", rater = "Bob Jones", stars = 5, id = "r1", ts = T0 + 10 }, recs[4])
      assert.are.same({ kind = "ridelog", rater = "Ana Smith", id = "r1", ts = T0 + 5, other = "Bob Jones" }, recs[5])
      for _, rec in ipairs(recs) do
        assert.are_not.equal("r3", rec.id, "the relayed rating is not passed on")
        assert.are_not.equal("r5", rec.id, "the light death is not passed on")
      end
    end)

    it("leaves out ride logs when the target is not me", function()
      populate()
      local recs = R.replyRecords(db, "Ana Smith", "Zed Quux", 50)
      assert.are.equal(3, #recs)
      for _, rec in ipairs(recs) do
        assert.are_not.equal("ridelog", rec.kind)
      end
      assert.are.same({ "death", "share", "trust" }, { recs[1].kind, recs[2].kind, recs[3].kind })
    end)

    it("answers with the queried warlock's own ride logs only", function()
      populate()
      local recs = R.replyRecords(db, "Hal Ward", "Hal Ward", 50)
      assert.are.same({ { kind = "ridelog", rater = "Hal Ward", id = "r7", ts = T0 + 70, other = "Ira Cole" } }, recs)
      assert.are.same({}, R.replyRecords(db, "Hal Ward", "Ana Smith", 50))
    end)

    it("compares target and me as names", function()
      populate()
      assert.are.equal(5, #R.replyRecords(db, " Ana  Smith", "Ana Smith ", 50))
    end)

    it("sends at most max records, newest first", function()
      populate()
      local recs = R.replyRecords(db, "Ana Smith", "Ana Smith", 2)
      assert.are.equal(2, #recs)
      assert.are.equal("r6", recs[1].id)
      assert.are.equal("r4", recs[2].id)
      assert.are.same({}, R.replyRecords(db, "Ana Smith", "Ana Smith", 0))
    end)

    it("uses the reply limit from the config when no max is given", function()
      for i = 1, ns.Config.QUERY_MAX_RECORDS + 5 do
        assert.is_true(R.addRideLog(db, "Ana Smith", "r" .. i, T0 + i, "Bob Jones"))
      end
      assert.are.equal(ns.Config.QUERY_MAX_RECORDS, #R.replyRecords(db, "Ana Smith", "Ana Smith"))
    end)

    it("leaves out records from liars", function()
      populate()
      R.markLiar(db, "Bob Jones", T0)
      R.markLiar(db, "Eve Gray", T0)
      local recs = R.replyRecords(db, "Ana Smith", "Zed Quux", 50)
      assert.are.equal(1, #recs)
      assert.are.equal("share", recs[1].kind)
    end)

    it("uses only protocol fields, which Protocol can encode", function()
      populate()
      local recs = R.replyRecords(db, "Ana Smith", "Ana Smith", 50)
      for _, rec in ipairs(recs) do
        for field in pairs(rec) do
          assert.is_true(PROTOCOL_FIELDS[field], field)
        end
      end
      local wire = ns.Protocol.encode("QUERY_R", "m1", { target = "Ana Smith", records = recs })
      local msg = ns.Protocol.decode(wire)
      assert.is_not_nil(msg)
      assert.are.same(recs, msg.records)
    end)

    it("creates nothing when it reads", function()
      local before = deepCopy(db)
      assert.are.same({}, R.replyRecords(db, "Nobody Here", "Nobody Here", 50))
      assert.are.same({}, R.replyRecords(db, "Nobody Here", "Ana Smith", 50))
      assert.are.same({}, R.replyRecords(db, nil, "Ana Smith", 50))
      assert.are.same(before, db)
      assert.is_nil(db.ratings["Nobody Here"])
    end)
  end)

  describe("a db written by a newer addon", function()
    it("is never written to", function()
      local newer = ns.Store.init({ version = 9, ratings = {}, liars = {}, strikes = {} })
      assert.is_true(newer._newer)
      local before = deepCopy(newer)

      local ok, why = R.addDirect(newer, trust("Bob Jones", 5, "r1"), "Bob Jones")
      assert.is_nil(ok)
      assert.are.equal("readonly", why)
      ok, why = R.addRelayed(newer, trust("Dan Eve", 5, "r1"), "Rel Ay")
      assert.is_nil(ok)
      assert.are.equal("readonly", why)
      ok, why = R.give(newer, trust("Bob Jones", 5, "r1"))
      assert.is_nil(ok)
      assert.are.equal("readonly", why)
      assert.is_nil(R.addDeath(newer, { target = "Ana Smith", victim = "Cal Dunn", id = "r1", ts = T0, heavy = true }))
      assert.is_nil(R.addRideLog(newer, "Ana Smith", "r1", T0, "Bob Jones"))
      assert.is_nil(R.addReceipt(newer, "Ana Smith", "r1", T0))
      R.removeDeath(newer, "Ana Smith", "r1")
      R.strike(newer, "Rel Ay")
      R.markLiar(newer, "Dan Eve", T0)

      assert.are.same(before, newer)
    end)

    it("is not read either, because its records may be laid out differently", function()
      local newer = ns.Store.init({
        version = 9,
        ratings = { ["Ana Smith"] = { trust = { { rater = "Bob Jones", stars = 5, id = "r1", ts = T0 } } } },
      })
      local s = R.summary(newer, "Ana Smith", "trust")
      assert.is_nil(s.stars)
      assert.are.equal(0, s.count)
      assert.are.same({}, R.replyRecords(newer, "Ana Smith", "Ana Smith", 50))
    end)
  end)
end)
