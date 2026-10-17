describe("Witness", function()
  local ns, db, w

  local T0 = 100000
  local VICTIM = "Tom Traveler"
  local WARLOCK = "Ana Smith"
  local RELAYER = "Wit Ness"
  local RIDE = WARLOCK .. "@" .. VICTIM .. "@" .. T0 -- the id Ride.makeId would give

  before_each(function()
    ns = Taxi.load()
    db = ns.Store.init(nil)
    w = ns.Witness.new(db)
  end)

  -- A ride the victim announced at T0 and arrived on at T0 + 10.
  local ARRIVED = T0 + 10
  local function arrivedRide()
    assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
    assert.is_true(w:arrived(RIDE, VICTIM, ARRIVED, VICTIM))
  end

  local function report(fields)
    local m = { rideId = RIDE, victim = VICTIM, warlock = WARLOCK, secs = 30, source = "self" }
    for k, v in pairs(fields or {}) do
      m[k] = v
    end
    return m
  end

  local function nothingStored()
    assert.is_nil(next(db.deaths))
  end

  local function trust()
    return ns.Ratings.summary(db, WARLOCK, "trust")
  end

  describe("rideStarted", function()
    it("remembers a ride announced by the victim", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.are.same({ victim = VICTIM, warlock = WARLOCK, startTs = T0 }, w.rides[RIDE])
    end)

    it("ignores a ride start from the wrong sender", function()
      assert.is_false(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, "Mal Ice"))
      assert.is_false(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, WARLOCK))
      assert.is_nil(w.rides[RIDE])
      -- So the victim's later report has no ride start behind it.
      assert.is_nil(w:deathReported(report(), VICTIM, T0 + 40))
      nothingStored()
    end)

    it("compares full names: a first name alone is not the sender", function()
      assert.is_false(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, "Tom"))
      assert.is_false(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, nil))
      assert.is_false(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, ""))
      assert.is_nil(w.rides[RIDE])
    end)

    it("takes the sender with stray whitespace as the same player", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, "  Tom   Traveler "))
      assert.are.equal(VICTIM, w.rides[RIDE].victim)
    end)

    it("refuses malformed input", function()
      assert.is_false(w:rideStarted("", VICTIM, WARLOCK, T0, VICTIM))
      assert.is_false(w:rideStarted(nil, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_false(w:rideStarted(RIDE, nil, WARLOCK, T0, nil))
      assert.is_false(w:rideStarted(RIDE, VICTIM, "  ", T0, VICTIM))
      assert.is_false(w:rideStarted(RIDE, VICTIM, WARLOCK, nil, VICTIM))
      assert.is_false(w:rideStarted(RIDE, VICTIM, WARLOCK, 0 / 0, VICTIM))
      assert.is_false(w:rideStarted(RIDE, VICTIM, WARLOCK, math.huge, VICTIM))
      assert.is_false(w:rideStarted(RIDE, VICTIM, VICTIM, T0, VICTIM))
      assert.is_nil(next(w.rides))
    end)

    it("refuses a ride id that names other players than the ride does", function()
      assert.is_false(w:rideStarted("Ana Smith@Other Person@" .. T0, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_false(w:rideStarted("Other Person@Tom Traveler@" .. T0, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_nil(next(w.rides))
      -- An id that is not in the driver@traveler@seconds form is left alone.
      assert.is_true(w:rideStarted("ride-1", VICTIM, WARLOCK, T0, VICTIM))
    end)

    it("hearing the same start again changes nothing", function()
      arrivedRide()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0 + 500, VICTIM))
      assert.are.same({ victim = VICTIM, warlock = WARLOCK, startTs = T0, arrivedTs = ARRIVED }, w.rides[RIDE])
    end)

    it("does not let a second start move a known ride to another warlock", function()
      assert.is_true(w:rideStarted("r1", VICTIM, WARLOCK, T0, VICTIM))
      assert.is_false(w:rideStarted("r1", VICTIM, "Dar Kbolt", T0, VICTIM))
      assert.are.equal(WARLOCK, w.rides.r1.warlock)
    end)
  end)

  describe("arrived", function()
    it("sets arrivedTs", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_true(w:arrived(RIDE, VICTIM, ARRIVED, VICTIM))
      assert.are.equal(ARRIVED, w.rides[RIDE].arrivedTs)
    end)

    it("ignores an arrival from anyone but the victim", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_false(w:arrived(RIDE, VICTIM, ARRIVED, WARLOCK))
      assert.is_false(w:arrived(RIDE, VICTIM, ARRIVED, "Tom"))
      assert.is_false(w:arrived(RIDE, VICTIM, ARRIVED, nil))
      assert.is_nil(w.rides[RIDE].arrivedTs)
    end)

    it("ignores an arrival for a ride it never heard start, or for another victim", function()
      assert.is_false(w:arrived(RIDE, VICTIM, ARRIVED, VICTIM))
      assert.is_nil(w.rides[RIDE])
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_false(w:arrived(RIDE, "Mal Ice", ARRIVED, "Mal Ice"))
      assert.is_nil(w.rides[RIDE].arrivedTs)
    end)

    it("keeps the first arrival: a later one cannot stretch the window", function()
      arrivedRide()
      assert.is_true(w:arrived(RIDE, VICTIM, ARRIVED + 600, VICTIM))
      assert.are.equal(ARRIVED, w.rides[RIDE].arrivedTs)
    end)

    it("refuses a time that is not a number", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_false(w:arrived(RIDE, VICTIM, nil, VICTIM))
      assert.is_false(w:arrived(RIDE, VICTIM, 0 / 0, VICTIM))
      assert.is_nil(w.rides[RIDE].arrivedTs)
    end)
  end)

  describe("observedDeath", function()
    it("own observation within the window is heavy", function()
      arrivedRide()
      local died = ARRIVED + 119
      local death = w:observedDeath(VICTIM, died)
      assert.are.same(
        { target = WARLOCK, victim = VICTIM, id = RIDE, ts = died, heavy = true, source = "observed" },
        death
      )
      local stored = db.deaths[WARLOCK][RIDE]
      assert.is_true(stored.heavy)
      assert.are.equal(VICTIM, stored.victim)
      assert.are.equal(died, stored.ts)
      assert.is_nil(stored.via)
    end)

    it("counts against the warlock as one heavy death in the trust summary", function()
      arrivedRide()
      assert.is_not_nil(w:observedDeath(VICTIM, ARRIVED + 119))
      local s = trust()
      assert.are.equal(1, s.deathsReported)
      assert.are.equal(1, s.stars)
    end)

    it("counts the whole window, both ends", function()
      arrivedRide()
      local death = w:observedDeath(VICTIM, ARRIVED + 120)
      assert.is_true(death.heavy)
    end)

    it("outside window ignored", function()
      arrivedRide()
      assert.is_nil(w:observedDeath(VICTIM, ARRIVED + 121))
      nothingStored()
    end)

    it("ignores a death before the arrival", function()
      arrivedRide()
      assert.is_nil(w:observedDeath(VICTIM, ARRIVED - 1))
      nothingStored()
    end)

    it("observation without arrival ignored", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_nil(w:observedDeath(VICTIM, T0 + 20))
      nothingStored()
    end)

    it("ignores a death of someone who is on no ride, or of a different traveler", function()
      arrivedRide()
      assert.is_nil(w:observedDeath("Mal Ice", ARRIVED + 5))
      assert.is_nil(w:observedDeath("Tom", ARRIVED + 5))
      assert.is_nil(w:observedDeath(nil, ARRIVED + 5))
      assert.is_nil(w:observedDeath("", ARRIVED + 5))
      assert.is_nil(w:observedDeath(VICTIM, nil))
      assert.is_nil(w:observedDeath(VICTIM, 0 / 0))
      nothingStored()
    end)

    it("blames the most recent ride, and only one", function()
      arrivedRide()
      local second = "Dar Kbolt@" .. VICTIM .. "@" .. (T0 + 60)
      assert.is_true(w:rideStarted(second, VICTIM, "Dar Kbolt", T0 + 60, VICTIM))
      assert.is_true(w:arrived(second, VICTIM, ARRIVED + 60, VICTIM))
      local death = w:observedDeath(VICTIM, ARRIVED + 90)
      assert.are.equal("Dar Kbolt", death.target)
      assert.are.equal(second, death.id)
      assert.is_nil(db.deaths[WARLOCK])
      assert.is_not_nil(db.deaths["Dar Kbolt"][second])
    end)

    it("reports a death once: a second notice of the same death is not new", function()
      arrivedRide()
      assert.is_not_nil(w:observedDeath(VICTIM, ARRIVED + 50))
      assert.is_nil(w:observedDeath(VICTIM, ARRIVED + 51))
      assert.are.equal(ARRIVED + 50, db.deaths[WARLOCK][RIDE].ts)
    end)

    it("returns nil and writes nothing when the db is read-only", function()
      arrivedRide()
      db._newer = true
      assert.is_nil(w:observedDeath(VICTIM, ARRIVED + 50))
      nothingStored()
      assert.is_nil(w.rides[RIDE].deathSource)
    end)
  end)

  describe("deathReported", function()
    it("self report heavy", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      local death = w:deathReported(report(), VICTIM, T0 + 40)
      assert.are.same(
        { target = WARLOCK, victim = VICTIM, id = RIDE, ts = T0 + 40, heavy = true, source = "self" },
        death
      )
      local stored = db.deaths[WARLOCK][RIDE]
      assert.is_true(stored.heavy)
      assert.are.equal(VICTIM, stored.victim)
      assert.are.equal(T0 + 40, stored.ts)
      assert.is_nil(stored.via)
      assert.are.equal(1, trust().deathsReported)
    end)

    it("takes the window to the second", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_nil(w:deathReported(report({ secs = 121 }), VICTIM, T0 + 40))
      nothingStored()
      assert.is_true(w:deathReported(report({ secs = 120 }), VICTIM, T0 + 40).heavy)
      assert.is_true(w:deathReported(report({ secs = 0 }), VICTIM, T0 + 40).heavy)
    end)

    it("self report without heard ride start is nil", function()
      assert.is_nil(w:deathReported(report(), VICTIM, T0 + 40))
      nothingStored()
    end)

    it("is not heavy when the ride start was announced by someone else", function()
      assert.is_false(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, WARLOCK))
      assert.is_nil(w:deathReported(report(), VICTIM, T0 + 40))
      nothingStored()
    end)

    it("is nil when the victim names another warlock than the ride they announced", function()
      assert.is_true(w:rideStarted("r1", VICTIM, WARLOCK, T0, VICTIM))
      assert.is_nil(w:deathReported(report({ rideId = "r1", warlock = "Dar Kbolt" }), VICTIM, T0 + 40))
      nothingStored()
    end)

    it("third-party report is light", function()
      local death = w:deathReported(report(), RELAYER, T0 + 40)
      assert.are.same({
        target = WARLOCK,
        victim = VICTIM,
        id = RIDE,
        ts = T0 + 40,
        heavy = false,
        source = "relayed",
        via = { [RELAYER] = true },
      }, death)
      local stored = db.deaths[WARLOCK][RIDE]
      assert.is_false(stored.heavy)
      assert.are.equal(VICTIM, stored.victim)
      assert.are.same({ [RELAYER] = true }, stored.via)
      assert.are.equal(1, trust().deathsReported)
    end)

    it("is light even when the third party claims the death is its own or the ride is known", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      local death = w:deathReported(report({ source = "self" }), RELAYER, T0 + 40)
      assert.is_false(death.heavy)
      assert.are.equal("relayed", death.source)
      assert.is_false(db.deaths[WARLOCK][RIDE].heavy)
      assert.is_nil(w.rides[RIDE].deathSource)
    end)

    it("adds up the relayers of one death", function()
      assert.is_not_nil(w:deathReported(report(), RELAYER, T0 + 40))
      assert.is_not_nil(w:deathReported(report(), "Bea Cons", T0 + 41))
      assert.are.same({ [RELAYER] = true, ["Bea Cons"] = true }, db.deaths[WARLOCK][RIDE].via)
    end)

    it("never lets a relayed report weaken a first-hand one", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_not_nil(w:deathReported(report(), VICTIM, T0 + 40))
      assert.is_not_nil(w:deathReported(report(), RELAYER, T0 + 41))
      assert.is_true(db.deaths[WARLOCK][RIDE].heavy)
      assert.is_nil(db.deaths[WARLOCK][RIDE].via)
    end)

    it("upgrades a relayed death when the victim's own report arrives", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_not_nil(w:deathReported(report(), RELAYER, T0 + 40))
      assert.is_not_nil(w:deathReported(report(), VICTIM, T0 + 41))
      assert.is_true(db.deaths[WARLOCK][RIDE].heavy)
      assert.is_nil(db.deaths[WARLOCK][RIDE].via)
    end)

    it("compares the sender to the victim as full names", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      -- "Tom" is not Tom Traveler: a first-name sender is a third party.
      local death = w:deathReported(report(), "Tom", T0 + 40)
      assert.is_false(death.heavy)
      assert.are.same({ Tom = true }, death.via)
      -- Stray whitespace does not make a different player.
      assert.is_true(w:deathReported(report(), "  Tom   Traveler ", T0 + 41).heavy)
    end)

    it("refuses a ride id that does not belong to the victim and warlock it names", function()
      -- A relayed copy naming a player known to lie would mask the real death.
      assert.is_nil(w:deathReported(report({ victim = "Liar Larry" }), RELAYER, T0 + 40))
      assert.is_nil(w:deathReported(report({ warlock = "Dar Kbolt" }), RELAYER, T0 + 40))
      nothingStored()
      -- A relayed report about a ride this client knows must agree with it.
      assert.is_true(w:rideStarted("r1", VICTIM, WARLOCK, T0, VICTIM))
      assert.is_nil(w:deathReported(report({ rideId = "r1", victim = "Liar Larry" }), RELAYER, T0 + 40))
      assert.is_nil(w:deathReported(report({ rideId = "r1", warlock = "Dar Kbolt" }), RELAYER, T0 + 40))
      nothingStored()
    end)

    it("ignores a relayed report outside the window", function()
      assert.is_nil(w:deathReported(report({ secs = 121 }), RELAYER, T0 + 40))
      nothingStored()
    end)

    it("fails closed on a malformed message", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      local bad = {
        { rideId = "" },
        { rideId = 5 },
        { rideId = false },
        { victim = "" },
        { victim = "   " },
        { victim = 7 },
        { warlock = "" },
        { warlock = {} },
        { secs = -1 },
        { secs = 0 / 0 },
        { secs = math.huge },
        { secs = -math.huge },
        { secs = "30" },
      }
      for _, fields in ipairs(bad) do
        assert.is_nil(w:deathReported(report(fields), RELAYER, T0 + 40))
        assert.is_nil(w:deathReported(report(fields), VICTIM, T0 + 40))
      end
      for _, field in ipairs({ "rideId", "victim", "warlock", "secs" }) do
        local m = report()
        m[field] = nil
        assert.is_nil(w:deathReported(m, RELAYER, T0 + 40))
        assert.is_nil(w:deathReported(m, VICTIM, T0 + 40))
      end
      assert.is_nil(w:deathReported(nil, RELAYER, T0 + 40))
      assert.is_nil(w:deathReported("death", RELAYER, T0 + 40))
      assert.is_nil(w:deathReported(report(), nil, T0 + 40))
      assert.is_nil(w:deathReported(report(), "", T0 + 40))
      assert.is_nil(w:deathReported(report(), "  ", T0 + 40))
      assert.is_nil(w:deathReported(report(), RELAYER, nil))
      assert.is_nil(w:deathReported(report(), RELAYER, 0 / 0))
      nothingStored()
    end)

    it("returns nil and writes nothing when the db is read-only", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      db._newer = true
      assert.is_nil(w:deathReported(report(), VICTIM, T0 + 40))
      assert.is_nil(w:deathReported(report(), RELAYER, T0 + 40))
      nothingStored()
      assert.is_nil(w.rides[RIDE].deathSource)
    end)
  end)

  describe("aliveEvidence", function()
    local function selfDeath(at)
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_not_nil(w:deathReported(report(), VICTIM, at))
      assert.is_true(db.deaths[WARLOCK][RIDE].heavy)
    end

    it("alive after self-reported death marks liar", function()
      selfDeath(T0 + 40)
      assert.are.equal(1, trust().deathsReported)
      assert.are.equal(1, w:aliveEvidence(VICTIM, T0 + 40 + 61))
      assert.are.equal(T0 + 40 + 61, db.liars[VICTIM])
      nothingStored()
      assert.are.equal(0, trust().deathsReported)
    end)

    it("waits out the grace period: alive 60 s after the report is not yet lying", function()
      selfDeath(T0 + 40)
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + 40 + 60))
      assert.is_nil(db.liars[VICTIM])
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + 40 - 5))
      assert.is_nil(db.liars[VICTIM])
    end)

    it("alive after relayed death strikes relayer", function()
      assert.is_not_nil(w:deathReported(report(), RELAYER, T0 + 40))
      assert.are.equal(1, w:aliveEvidence(VICTIM, T0 + 40 + 61))
      assert.are.equal(1, db.strikes[RELAYER])
      assert.is_nil(db.liars[VICTIM])
      assert.is_nil(db.liars[RELAYER])
      nothingStored()
    end)

    it("strikes every relayer of the death", function()
      assert.is_not_nil(w:deathReported(report(), RELAYER, T0 + 40))
      assert.is_not_nil(w:deathReported(report(), "Bea Cons", T0 + 41))
      assert.are.equal(1, w:aliveEvidence(VICTIM, T0 + 200))
      assert.are.equal(1, db.strikes[RELAYER])
      assert.are.equal(1, db.strikes["Bea Cons"])
      nothingStored()
    end)

    it("does not strike a relayer inside the grace period", function()
      assert.is_not_nil(w:deathReported(report(), RELAYER, T0 + 40))
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + 40 + 60))
      assert.is_nil(db.strikes[RELAYER])
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)

    it("observed death survives alive evidence", function()
      arrivedRide()
      local died = ARRIVED + 50
      assert.is_not_nil(w:observedDeath(VICTIM, died))
      assert.are.equal(0, w:aliveEvidence(VICTIM, died + 3600))
      assert.is_nil(db.liars[VICTIM])
      assert.is_nil(next(db.strikes))
      assert.is_true(db.deaths[WARLOCK][RIDE].heavy)
      assert.are.equal(1, trust().deathsReported)
    end)

    it("keeps a self-reported death this client also saw happen", function()
      arrivedRide()
      assert.is_not_nil(w:deathReported(report(), VICTIM, ARRIVED + 40))
      assert.is_not_nil(w:observedDeath(VICTIM, ARRIVED + 41))
      assert.are.equal(0, w:aliveEvidence(VICTIM, ARRIVED + 41 + 600))
      assert.is_nil(db.liars[VICTIM])
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)

    it("keeps a death observed first and reported by the victim afterwards", function()
      arrivedRide()
      assert.is_not_nil(w:observedDeath(VICTIM, ARRIVED + 40))
      assert.is_not_nil(w:deathReported(report(), VICTIM, ARRIVED + 41))
      assert.are.equal(0, w:aliveEvidence(VICTIM, ARRIVED + 41 + 600))
      assert.is_nil(db.liars[VICTIM])
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)

    it("leaves a heavy death whose source is unknown alone", function()
      -- Written straight to the db, with no witness record of where it came from.
      assert.is_true(ns.Ratings.addDeath(db, { target = WARLOCK, victim = VICTIM, id = RIDE, ts = T0, heavy = true }, T0))
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + 600))
      assert.is_nil(db.liars[VICTIM])
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)

    it("leaves a death with no relayer and no first-hand source alone", function()
      assert.is_true(ns.Ratings.addDeath(db, { target = WARLOCK, victim = VICTIM, id = RIDE, ts = T0, heavy = false }, T0))
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + 600))
      assert.is_nil(next(db.strikes))
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)

    it("takes back a relayed death that came with a query reply too", function()
      -- Stored by the engine from someone else's records, not through the witness.
      assert.is_true(ns.Ratings.addDeath(db, {
        target = WARLOCK, victim = VICTIM, id = "old-ride", ts = T0, heavy = false, via = { [RELAYER] = true },
      }, T0))
      assert.are.equal(1, w:aliveEvidence(VICTIM, T0 + 61))
      assert.are.equal(1, db.strikes[RELAYER])
      nothingStored()
    end)

    it("only looks at the player who was seen alive", function()
      selfDeath(T0 + 40)
      assert.are.equal(0, w:aliveEvidence("Mal Ice", T0 + 1000))
      assert.are.equal(0, w:aliveEvidence("Tom", T0 + 1000))
      assert.are.equal(0, w:aliveEvidence(WARLOCK, T0 + 1000))
      assert.is_nil(next(db.liars))
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)

    it("handles several deaths of one player and of several warlocks", function()
      selfDeath(T0 + 40)
      local other = "Dar Kbolt@" .. VICTIM .. "@" .. (T0 + 500)
      assert.is_not_nil(w:deathReported(report({ rideId = other, warlock = "Dar Kbolt" }), RELAYER, T0 + 540))
      assert.are.equal(2, w:aliveEvidence(VICTIM, T0 + 700))
      assert.are.equal(T0 + 700, db.liars[VICTIM])
      assert.are.equal(1, db.strikes[RELAYER])
      nothingStored()
    end)

    it("ignores a name or a time that is not usable", function()
      selfDeath(T0 + 40)
      assert.are.equal(0, w:aliveEvidence(nil, T0 + 1000))
      assert.are.equal(0, w:aliveEvidence("", T0 + 1000))
      assert.are.equal(0, w:aliveEvidence(VICTIM, nil))
      assert.are.equal(0, w:aliveEvidence(VICTIM, 0 / 0))
      assert.is_nil(next(db.liars))
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)

    it("skips malformed rows in the db", function()
      db.deaths.Junk = "not a table"
      db.deaths[WARLOCK] = { bad = "row", worse = { victim = VICTIM }, [1] = { victim = VICTIM, ts = T0 } }
      db.deaths[2] = { r1 = { victim = VICTIM, ts = T0 } }
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + 1000))
      assert.is_nil(next(db.liars))
    end)

    it("changes nothing when the db is read-only", function()
      selfDeath(T0 + 40)
      db._newer = true
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + 1000))
      assert.is_nil(next(db.liars))
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)
  end)

  describe("expire", function()
    it("drops rides older than RIDE_MEMORY and keeps the rest", function()
      local memory = ns.Config.RIDE_MEMORY
      assert.is_true(w:rideStarted("old", VICTIM, WARLOCK, T0, VICTIM))
      assert.is_true(w:rideStarted("edge", VICTIM, WARLOCK, T0 + 1, VICTIM))
      assert.is_true(w:rideStarted("new", VICTIM, WARLOCK, T0 + 2, VICTIM))
      assert.are.equal(1, w:expire(T0 + memory + 1))
      assert.is_nil(w.rides.old)
      assert.is_not_nil(w.rides.edge)
      assert.is_not_nil(w.rides.new)
      assert.are.equal(0, w:expire(T0 + memory + 1))
      assert.are.equal(2, w:expire(T0 + memory + 1000))
      assert.is_nil(next(w.rides))
    end)

    it("keeps a ride that is exactly RIDE_MEMORY old", function()
      assert.is_true(w:rideStarted("r1", VICTIM, WARLOCK, T0, VICTIM))
      assert.are.equal(0, w:expire(T0 + ns.Config.RIDE_MEMORY))
      assert.is_not_nil(w.rides.r1)
    end)

    it("forgets the ride, so a report about it no longer counts as first hand", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      w:expire(T0 + ns.Config.RIDE_MEMORY + 1)
      assert.is_nil(w:deathReported(report(), VICTIM, T0 + ns.Config.RIDE_MEMORY + 1))
      nothingStored()
    end)

    it("does not touch stored deaths", function()
      arrivedRide()
      assert.is_not_nil(w:observedDeath(VICTIM, ARRIVED + 5))
      w:expire(T0 + ns.Config.RIDE_MEMORY * 10)
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)

    it("ignores a time that is not a number", function()
      assert.is_true(w:rideStarted("r1", VICTIM, WARLOCK, T0, VICTIM))
      assert.are.equal(0, w:expire(nil))
      assert.are.equal(0, w:expire(0 / 0))
      assert.is_not_nil(w.rides.r1)
    end)
  end)
end)
