describe("Store", function()
  local ns, S

  before_each(function()
    ns = Taxi.load()
    S = ns.Store
  end)

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

  local TABLES = { "ratings", "given", "deaths", "rideLogs", "receipts", "rides", "liars", "strikes", "settings" }

  it("fresh", function()
    local db = S.init(nil)
    assert.are.equal(1, db.version)
    assert.are.same({}, db.given)
  end)

  it("fills missing tables without wiping data", function()
    local db = S.init({version=1, ratings={X={trust={{rater="A B", stars=5, ts=1}}}}})
    assert.are.equal(1, #db.ratings.X.trust)
    assert.are.same({}, db.liars)
  end)

  it("leaves newer data alone", function()
    local db = S.init({version=9, foo=1})
    assert.is_true(db._newer)
    assert.are.equal(1, db.foo)
  end)

  it("caps at 500, oldest first, never prunes given", function()
    local db = S.init(nil)
    local l = S.ratingList(db, "X", "trust")
    for i = 1, 520 do l[i] = {rater="R"..i, stars=5, ts=i} end
    for i = 1, 600 do db.given[i] = {ts=i} end
    S.prune(db)
    assert.are.equal(500, #l)
    assert.are.equal(21, l[1].ts)
    assert.are.equal(600, #db.given)
  end)

  describe("init", function()
    it("is at schema version 1", function()
      assert.are.equal(1, S.VERSION)
    end)

    it("guarantees every table on a fresh db", function()
      local db = S.init(nil)
      for _, name in ipairs(TABLES) do
        assert.are.same({}, db[name], name)
      end
      assert.is_nil(db._newer)
    end)

    it("mutates and returns the table it was given", function()
      local saved = { version = 1 }
      local db = S.init(saved)
      assert.are.equal(saved, db)
      assert.are.same({}, saved.strikes)
    end)

    it("keeps every existing table and its contents", function()
      local saved = { version = 1 }
      for _, name in ipairs(TABLES) do
        saved[name] = { [name] = { name } }
      end
      local before = deepCopy(saved)
      assert.are.same(before, S.init(saved))
    end)

    it("is safe to run again on its own result", function()
      local db = S.init(nil)
      S.ratingList(db, "Dar Kbolt", "share")[1] = { rater = "A B", stars = 4, ts = 7 }
      db.liars["X Y"] = 12
      local before = deepCopy(db)
      assert.are.same(before, S.init(db))
    end)

    it("treats a missing or invalid version as the current one, keeping the data", function()
      for _, bad in ipairs({ "none", "1", 0, -3, 0.5, 0 / 0 }) do
        local saved = { strikes = { ["A B"] = 2 } }
        if bad ~= "none" then
          saved.version = bad
        end
        local db = S.init(saved)
        assert.are.equal(1, db.version, tostring(bad))
        assert.are.equal(2, db.strikes["A B"])
        assert.is_nil(db._newer)
      end
    end)

    it("starts over with a new table when the saved value is not a table", function()
      assert.are.equal(1, S.init("garbage").version)
      assert.are.equal(1, S.init(42).version)
    end)

    it("replaces a schema slot that holds something other than a table", function()
      local db = S.init({ version = 1, given = "oops", ratings = { X = { trust = {} } } })
      assert.are.same({}, db.given)
      assert.are.same({ X = { trust = {} } }, db.ratings)
    end)

    describe("with a newer version", function()
      it("changes nothing but the flag", function()
        local saved = { version = 9, foo = 1, ratings = { X = { trust = { { ts = 1 } } } } }
        local before = deepCopy(saved)
        local db = S.init(saved)
        assert.are.equal(saved, db)
        assert.is_true(db._newer)
        db._newer = nil
        assert.are.same(before, db)
        assert.is_nil(db.given)
      end)

      it("does not run any migration", function()
        local ran = false
        S.migrations[1] = function() ran = true end
        S.init({ version = 9 })
        assert.is_false(ran)
      end)

      it("clears a stale flag once the version matches again", function()
        local db = S.init({ version = 1, _newer = true })
        assert.is_nil(db._newer)
      end)
    end)

    describe("migrations", function()
      it("starts with none, so a current db is never migrated", function()
        assert.are.same({}, S.migrations)
      end)

      it("runs the step for each version below the current one, in order", function()
        S.VERSION = 4
        local order = {}
        for v = 1, 3 do
          S.migrations[v] = function(db)
            order[#order + 1] = v
            assert.are.equal(v, db.version, "db.version is the version being migrated from")
          end
        end
        local db = S.init({ version = 2, ratings = { X = {} } })
        assert.are.same({ 2, 3 }, order)
        assert.are.equal(4, db.version)
        assert.are.same({ X = {} }, db.ratings)
      end)

      it("does not run a step at or above the saved version", function()
        S.VERSION = 3
        local ran = {}
        for v = 1, 3 do
          S.migrations[v] = function() ran[v] = true end
        end
        S.init({ version = 3 })
        assert.are.same({}, ran)
      end)

      it("lets a step reshape data, then fills the tables it left out", function()
        S.VERSION = 2
        S.migrations[1] = function(db)
          db.strikes = db.oldStrikes
          db.oldStrikes = nil
        end
        local db = S.init({ version = 1, oldStrikes = { ["A B"] = 1 } })
        assert.are.same({ ["A B"] = 1 }, db.strikes)
        assert.is_nil(db.oldStrikes)
        assert.are.same({}, db.settings)
        assert.are.equal(2, db.version)
      end)

      it("skips a version that needs no step but still advances", function()
        S.VERSION = 3
        local db = S.init({ version = 1 })
        assert.are.equal(3, db.version)
      end)

      it("keeps the version of the last finished step when one fails, so it can be retried", function()
        S.VERSION = 3
        S.migrations[1] = function() end
        S.migrations[2] = function() error("boom") end
        local saved = { version = 1, given = { { ts = 1 } } }
        assert.has_error(function() S.init(saved) end)
        assert.are.equal(2, saved.version)
        assert.are.same({ { ts = 1 } }, saved.given)
      end)
    end)
  end)

  describe("ratingList", function()
    it("creates the target entry and the list on demand", function()
      local db = S.init(nil)
      local l = S.ratingList(db, "Dar Kbolt", "trust")
      assert.are.same({}, l)
      assert.are.equal(l, db.ratings["Dar Kbolt"].trust)
    end)

    it("creates only the list that was asked for", function()
      local db = S.init(nil)
      S.ratingList(db, "Dar Kbolt", "share")
      assert.are.same({ share = {} }, db.ratings["Dar Kbolt"])
    end)

    it("returns the same list every time and keeps what is in it", function()
      local db = S.init(nil)
      local l = S.ratingList(db, "Dar Kbolt", "trust")
      l[1] = { rater = "A B", stars = 5, ts = 1 }
      assert.are.equal(l, S.ratingList(db, "Dar Kbolt", "trust"))
      assert.are.equal(1, #S.ratingList(db, "Dar Kbolt", "trust"))
    end)

    it("keeps the two kinds and the targets apart", function()
      local db = S.init(nil)
      local trust = S.ratingList(db, "Dar Kbolt", "trust")
      trust[1] = { ts = 1 }
      assert.are.same({}, S.ratingList(db, "Dar Kbolt", "share"))
      assert.are.same({}, S.ratingList(db, "Ana Smith", "trust"))
      assert.are.equal(trust, db.ratings["Dar Kbolt"].trust)
    end)

    it("finds a list that was loaded from disk", function()
      local db = S.init({ version = 1, ratings = { X = { trust = { { ts = 1 } } } } })
      assert.are.equal(db.ratings.X.trust, S.ratingList(db, "X", "trust"))
      assert.are.equal(1, #S.ratingList(db, "X", "trust"))
    end)

    it("only knows the kinds trust and share", function()
      local db = S.init(nil)
      assert.has_error(function() S.ratingList(db, "X", "trusts") end)
      assert.has_error(function() S.ratingList(db, "X", nil) end)
      assert.are.same({}, db.ratings)
    end)

    it("gives a newer db nothing to write to, and leaves it as it was", function()
      local db = S.init({ version = 9, ratings = { X = { trust = { { ts = 1 } } } } })
      local before = deepCopy(db)
      S.ratingList(db, "X", "trust")[2] = { ts = 2 }
      S.ratingList(db, "Y", "share")[1] = { ts = 3 }
      assert.are.same(before, db)
    end)
  end)

  describe("prune", function()
    it("takes the cap from Config", function()
      assert.are.equal(500, ns.Config.RATING.CAP_PER_KIND)
      ns.Config.RATING.CAP_PER_KIND = 3
      local db = S.init(nil)
      local l = S.ratingList(db, "X", "trust")
      for i = 1, 5 do l[i] = { ts = i } end
      S.prune(db)
      assert.are.same({ { ts = 3 }, { ts = 4 }, { ts = 5 } }, l)
    end)

    it("keeps the newest even when the list is out of order", function()
      ns.Config.RATING.CAP_PER_KIND = 3
      local db = S.init(nil)
      local l = S.ratingList(db, "X", "trust")
      for i, ts in ipairs({ 50, 10, 40, 20, 30 }) do l[i] = { ts = ts } end
      S.prune(db)
      assert.are.same({ { ts = 30 }, { ts = 40 }, { ts = 50 } }, l)
    end)

    it("counts a record with a missing or invalid ts as the oldest", function()
      ns.Config.RATING.CAP_PER_KIND = 3
      local db = S.init(nil)
      local l = S.ratingList(db, "X", "trust")
      l[1] = { rater = "no ts" }
      l[2] = { ts = 1 }
      l[3] = { ts = "later" }
      l[4] = { ts = 2 }
      l[5] = { ts = 3 }
      S.prune(db)
      assert.are.same({ { ts = 1 }, { ts = 2 }, { ts = 3 } }, l)
    end)

    it("keeps the earlier-listed record when timestamps tie", function()
      ns.Config.RATING.CAP_PER_KIND = 2
      local db = S.init(nil)
      local l = S.ratingList(db, "X", "trust")
      l[1] = { rater = "first", ts = 5 }
      l[2] = { rater = "second", ts = 5 }
      l[3] = { rater = "third", ts = 5 }
      S.prune(db)
      assert.are.same({ { rater = "second", ts = 5 }, { rater = "third", ts = 5 } }, l)
    end)

    it("drops relayed records before direct ones, oldest first within each group", function()
      ns.Config.RATING.CAP_PER_KIND = 3
      local db = S.init(nil)
      local l = S.ratingList(db, "X", "trust")
      l[1] = { rater = "d5", ts = 5 }
      l[2] = { rater = "d1", ts = 1 }
      l[3] = { rater = "r2", ts = 2, via = { ["Rel Ay"] = true } }
      l[4] = { rater = "r9", ts = 9, via = { ["Rel Ay"] = true } }
      l[5] = { rater = "r3", ts = 3, via = { ["Rel Ay"] = true } }
      S.prune(db)
      assert.are.equal(3, #l)
      -- The relayed ts 2 and ts 3 go; what stays is ordered oldest to newest.
      assert.are.same({ "d1", "d5", "r9" }, { l[1].rater, l[2].rater, l[3].rater })
    end)

    it("keeps an old direct record when newer relayed ones fill the list", function()
      ns.Config.RATING.CAP_PER_KIND = 3
      local db = S.init(nil)
      local l = S.ratingList(db, "X", "trust")
      l[1] = { rater = "direct", ts = 1 }
      for i = 1, 5 do
        l[#l + 1] = { rater = "relayed" .. i, ts = 10 + i, via = { ["Rel Ay"] = true } }
      end
      S.prune(db)
      assert.are.same({ "direct", "relayed4", "relayed5" }, { l[1].rater, l[2].rater, l[3].rater })
    end)

    it("drops the oldest direct records once no relayed ones are left", function()
      ns.Config.RATING.CAP_PER_KIND = 1
      local db = S.init(nil)
      local l = S.ratingList(db, "X", "trust")
      l[1] = { rater = "d5", ts = 5 }
      l[2] = { rater = "d1", ts = 1 }
      l[3] = { rater = "r2", ts = 2, via = { ["Rel Ay"] = true } }
      S.prune(db)
      assert.are.same({ { rater = "d5", ts = 5 } }, l)
    end)

    it("keeps the real record when 500 relayed ones dated far ahead arrive", function()
      local db = S.init(nil)
      local l = S.ratingList(db, "X", "trust")
      l[1] = { rater = "real", stars = 1, ts = 100 }
      for i = 1, 500 do
        l[#l + 1] = { rater = "fake" .. i, stars = 5, ts = 2e9 + i, via = { ["Rel Ay"] = true } }
      end
      S.prune(db)
      assert.are.equal(500, #l)
      assert.are.equal("real", l[1].rater)
      assert.are.equal("fake2", l[2].rater, "the oldest relayed record went")
    end)

    it("walks every target and both kinds", function()
      ns.Config.RATING.CAP_PER_KIND = 2
      local db = S.init(nil)
      for _, target in ipairs({ "A A", "B B" }) do
        for _, kind in ipairs({ "trust", "share" }) do
          local l = S.ratingList(db, target, kind)
          for i = 1, 4 do l[i] = { ts = i } end
        end
      end
      S.prune(db)
      for _, target in ipairs({ "A A", "B B" }) do
        for _, kind in ipairs({ "trust", "share" }) do
          local l = db.ratings[target][kind]
          assert.are.equal(2, #l, target .. " " .. kind)
          assert.are.equal(3, l[1].ts)
        end
      end
    end)

    it("leaves a list at or under the cap exactly as it is", function()
      ns.Config.RATING.CAP_PER_KIND = 3
      local db = S.init(nil)
      local l = S.ratingList(db, "X", "trust")
      for i, ts in ipairs({ 9, 1, 5 }) do l[i] = { ts = ts } end
      local first = l[1]
      S.prune(db)
      assert.are.same({ { ts = 9 }, { ts = 1 }, { ts = 5 } }, l)
      assert.are.equal(first, l[1])
    end)

    it("leaves everything but the rating lists alone", function()
      ns.Config.RATING.CAP_PER_KIND = 2
      local db = S.init(nil)
      local l = S.ratingList(db, "X", "trust")
      for i = 1, 4 do
        l[i] = { ts = i }
        db.given[i] = { ts = i }
        db.deaths[i] = { ts = i }
        db.rides[i] = { ts = i }
      end
      db.liars["A B"] = 1
      local others = {}
      for _, name in ipairs({ "given", "deaths", "rides", "liars", "strikes", "settings", "rideLogs", "receipts" }) do
        others[name] = deepCopy(db[name])
      end
      S.prune(db)
      for name, copy in pairs(others) do
        assert.are.same(copy, db[name], name)
      end
    end)

    it("skips entries that are not rating tables instead of failing", function()
      ns.Config.RATING.CAP_PER_KIND = 1
      local db = S.init({ version = 1, ratings = { X = "junk", Y = { trust = "junk" }, Z = { trust = { { ts = 1 }, { ts = 2 } } } } })
      S.prune(db)
      assert.are.same({ { ts = 2 } }, db.ratings.Z.trust)
      assert.are.equal("junk", db.ratings.X)
      assert.are.equal("junk", db.ratings.Y.trust)
    end)

    describe("deaths", function()
      local function ids(byId)
        local out = {}
        for id in pairs(byId) do
          out[#out + 1] = tostring(id)
        end
        table.sort(out)
        return out
      end

      it("caps a warlock's deaths at the Config cap by default", function()
        local db = S.init(nil)
        db.deaths.X = {}
        for i = 1, 502 do
          db.deaths.X["r" .. i] = { ts = i, heavy = false }
        end
        S.prune(db)
        local n = 0
        for _ in pairs(db.deaths.X) do
          n = n + 1
        end
        assert.are.equal(500, n)
        assert.is_nil(db.deaths.X.r1)
        assert.is_nil(db.deaths.X.r2)
        assert.is_not_nil(db.deaths.X.r3)
      end)

      it("drops light deaths before heavy ones, oldest first within each group", function()
        ns.Config.RATING.CAP_PER_KIND = 3
        local db = S.init(nil)
        db.deaths.X = {
          lateLight = { ts = 5, heavy = false },
          oldLight = { ts = 1, heavy = false },
          oldHeavy = { ts = 2, heavy = true },
          newHeavy = { ts = 9, heavy = true },
          midLight = { ts = 3, heavy = false },
        }
        S.prune(db)
        assert.are.same({ "lateLight", "newHeavy", "oldHeavy" }, ids(db.deaths.X))
      end)

      it("drops the oldest heavy deaths only when no light one is left", function()
        ns.Config.RATING.CAP_PER_KIND = 2
        local db = S.init(nil)
        db.deaths.X = {
          h1 = { ts = 1, heavy = true },
          h2 = { ts = 2, heavy = true },
          h3 = { ts = 3, heavy = true },
          l = { ts = 99, heavy = false },
        }
        S.prune(db)
        assert.are.same({ "h2", "h3" }, ids(db.deaths.X))
      end)

      it("caps each warlock on its own and leaves a short list alone", function()
        ns.Config.RATING.CAP_PER_KIND = 2
        local db = S.init(nil)
        db.deaths.X = { a = { ts = 1 }, b = { ts = 2 }, c = { ts = 3 } }
        db.deaths.Y = { a = { ts = 1 }, b = { ts = 2 } }
        S.prune(db)
        assert.are.same({ "b", "c" }, ids(db.deaths.X))
        assert.are.same({ "a", "b" }, ids(db.deaths.Y))
      end)

      it("breaks a timestamp tie by id, so the result is the same every time", function()
        ns.Config.RATING.CAP_PER_KIND = 1
        local db = S.init(nil)
        db.deaths.X = { a = { ts = 5 }, b = { ts = 5 }, c = { ts = 5 } }
        S.prune(db)
        assert.are.same({ "c" }, ids(db.deaths.X))
      end)

      it("counts a row with a missing or invalid ts, or that is not a table, as the oldest light one", function()
        ns.Config.RATING.CAP_PER_KIND = 2
        local db = S.init(nil)
        db.deaths.X = {
          junk = "junk",
          noTs = {},
          badTs = { ts = "later", heavy = false },
          a = { ts = 1, heavy = false },
          b = { ts = 2, heavy = false },
        }
        S.prune(db)
        assert.are.same({ "a", "b" }, ids(db.deaths.X))
      end)

      it("skips entries that are not death tables, and numeric ids", function()
        ns.Config.RATING.CAP_PER_KIND = 2
        local db = S.init({ version = 1, deaths = { X = "junk", Y = { { ts = 1 }, { ts = 2 }, { ts = 3 } } } })
        S.prune(db)
        assert.are.equal("junk", db.deaths.X)
        assert.are.same({ "2", "3" }, ids(db.deaths.Y))
      end)

      it("does not modify a newer db", function()
        local saved = { version = 9, deaths = { X = {} } }
        for i = 1, 520 do
          saved.deaths.X["r" .. i] = { ts = i }
        end
        local db = S.init(saved)
        local before = deepCopy(db)
        S.prune(db)
        assert.are.same(before, db)
      end)
    end)

    it("does not modify a newer db", function()
      local saved = { version = 9, ratings = { X = { trust = {} } } }
      for i = 1, 520 do saved.ratings.X.trust[i] = { ts = i } end
      local db = S.init(saved)
      local before = deepCopy(db)
      S.prune(db)
      assert.are.equal(520, #db.ratings.X.trust)
      assert.are.same(before, db)
    end)
  end)
end)
