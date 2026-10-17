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
      -- A refused store leaves no trace: once the db can be written, the death counts.
      db._newer = nil
      assert.is_not_nil(w:observedDeath(VICTIM, ARRIVED + 51))
      assert.is_true(db.deaths[WARLOCK][RIDE].heavy)
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
      assert.are.equal("relayed", db.deaths[WARLOCK][RIDE].source)
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
      -- A refused store leaves no trace: once the db can be written, the victim's report is heavy.
      db._newer = nil
      assert.is_true(w:deathReported(report(), VICTIM, T0 + 41).heavy)
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

    it("leaves a heavy death with no first-hand source alone", function()
      -- Written straight to the db (an old save, say), with no source behind it.
      assert.is_true(ns.Ratings.addDeath(db, { target = WARLOCK, victim = VICTIM, id = RIDE, ts = T0, heavy = true }, T0))
      w = ns.Witness.new(db)
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + 600))
      assert.is_nil(db.liars[VICTIM])
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)

    it("leaves a death with no relayer alone", function()
      assert.is_true(ns.Ratings.addDeath(db, { target = WARLOCK, victim = VICTIM, id = RIDE, ts = T0, heavy = false }, T0))
      w = ns.Witness.new(db)
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + 600))
      assert.is_nil(next(db.strikes))
      assert.is_not_nil(db.deaths[WARLOCK][RIDE])
    end)

    it("takes back a relayed death that was stored before this witness started", function()
      assert.is_true(ns.Ratings.addDeath(db, {
        target = WARLOCK, victim = VICTIM, id = "old-ride", ts = T0, heavy = false, via = { [RELAYER] = true },
      }, T0))
      w = ns.Witness.new(db)
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
      w = ns.Witness.new(db)
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

  -- Fix round 1 -------------------------------------------------------------------

  local MEMORY = 1800 -- Config.RIDE_MEMORY (checked below, so a change is noticed)

  local function countDeaths()
    local n = 0
    for _, byId in pairs(db.deaths) do
      for _ in pairs(byId) do
        n = n + 1
      end
    end
    return n
  end

  -- A ride of VICTIM with another warlock, started at `at` (the id Ride.makeId gives).
  local SECOND_WARLOCK = "Dar Kbolt"
  local function secondRide(at)
    local id = SECOND_WARLOCK .. "@" .. VICTIM .. "@" .. at
    assert.is_true(w:rideStarted(id, VICTIM, SECOND_WARLOCK, at, VICTIM))
    return id
  end

  it("assumes the ride memory the fix-round tests use", function()
    assert.are.equal(MEMORY, ns.Config.RIDE_MEMORY)
  end)

  describe("the source of a death is kept in the db (R30)", function()
    it("stores self, observed and relayed", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_not_nil(w:deathReported(report(), VICTIM, T0 + 40))
      assert.are.equal("self", db.deaths[WARLOCK][RIDE].source)

      local db2 = ns.Store.init(nil)
      local w2 = ns.Witness.new(db2)
      assert.is_true(w2:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_true(w2:arrived(RIDE, VICTIM, ARRIVED, VICTIM))
      assert.is_not_nil(w2:observedDeath(VICTIM, ARRIVED + 5))
      assert.are.equal("observed", db2.deaths[WARLOCK][RIDE].source)

      local db3 = ns.Store.init(nil)
      local w3 = ns.Witness.new(db3)
      assert.is_not_nil(w3:deathReported(report(), RELAYER, T0 + 40))
      assert.are.equal("relayed", db3.deaths[WARLOCK][RIDE].source)
    end)

    it("still takes back a self-reported death after its ride left memory", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_not_nil(w:deathReported(report(), VICTIM, T0 + 40))
      assert.are.equal(1, w:expire(T0 + MEMORY + 1))
      assert.is_nil(next(w.rides))
      assert.are.equal(1, w:aliveEvidence(VICTIM, T0 + MEMORY + 100))
      assert.are.equal(T0 + MEMORY + 100, db.liars[VICTIM])
      nothingStored()
    end)

    it("still takes back a self-reported death after a reload (a new witness on the same db)", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_not_nil(w:deathReported(report(), VICTIM, T0 + 40))
      w = ns.Witness.new(db)
      assert.is_nil(next(w.rides))
      assert.are.equal(1, w:aliveEvidence(VICTIM, T0 + 40 + 61))
      assert.are.equal(T0 + 40 + 61, db.liars[VICTIM])
      nothingStored()
    end)

    it("keeps an observed death after its ride left memory and after a reload", function()
      arrivedRide()
      assert.is_not_nil(w:observedDeath(VICTIM, ARRIVED + 5))
      w:expire(T0 + MEMORY + 1)
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + MEMORY + 100))
      w = ns.Witness.new(db)
      assert.are.equal(0, w:aliveEvidence(VICTIM, T0 + MEMORY + 200))
      assert.is_nil(next(db.liars))
      assert.are.equal("observed", db.deaths[WARLOCK][RIDE].source)
    end)

    it("keeps a death that was reported by the victim and then seen by this client, after a reload", function()
      arrivedRide()
      assert.is_not_nil(w:deathReported(report(), VICTIM, ARRIVED + 40))
      assert.is_not_nil(w:observedDeath(VICTIM, ARRIVED + 41))
      assert.are.equal("observed", db.deaths[WARLOCK][RIDE].source)
      w = ns.Witness.new(db)
      assert.are.equal(0, w:aliveEvidence(VICTIM, ARRIVED + 3600))
      assert.is_nil(next(db.liars))
    end)

    it("does not let the victim's own report lower an observed death", function()
      arrivedRide()
      assert.is_not_nil(w:observedDeath(VICTIM, ARRIVED + 40))
      assert.is_not_nil(w:deathReported(report(), VICTIM, ARRIVED + 41))
      assert.are.equal("observed", db.deaths[WARLOCK][RIDE].source)
    end)
  end)

  describe("a Hardcore character dies once (R32)", function()
    local function firstDeath()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_true(w:deathReported(report(), VICTIM, T0 + 40).heavy)
    end

    it("a second ride start and death report from the same victim is not heavy", function()
      firstDeath()
      local second = secondRide(T0 + 100)
      local m = report({ rideId = second, warlock = SECOND_WARLOCK, secs = 5 })
      assert.is_nil(w:deathReported(m, VICTIM, T0 + 110))
      assert.is_nil(db.deaths[SECOND_WARLOCK])
      assert.are.equal(1, countDeaths())
      assert.are.equal(0, ns.Ratings.summary(db, SECOND_WARLOCK, "trust").deathsReported)
    end)

    it("holds after a reload, because it is checked against the stored deaths", function()
      firstDeath()
      w = ns.Witness.new(db)
      local second = secondRide(T0 + 100)
      assert.is_nil(w:deathReported(report({ rideId = second, warlock = SECOND_WARLOCK, secs = 5 }), VICTIM, T0 + 110))
      assert.are.equal(1, countDeaths())
    end)

    it("a victim minting rides with fresh ids gets one heavy death in all", function()
      local heavy = 0
      for i = 1, 50 do
        local now = T0 + i * (MEMORY + 1)
        w:expire(now)
        local id = secondRide(now)
        if w:deathReported(report({ rideId = id, warlock = SECOND_WARLOCK, secs = 5 }), VICTIM, now + 5) then
          heavy = heavy + 1
        end
      end
      assert.are.equal(1, heavy)
      assert.are.equal(1, countDeaths())
      assert.are.equal(1, ns.Ratings.summary(db, SECOND_WARLOCK, "trust").deathsReported)
    end)

    it("the same minting across several warlocks and reloads is still one", function()
      local heavy = 0
      for i = 1, 20 do
        local now = T0 + i * (MEMORY + 1)
        w = ns.Witness.new(db)
        local warlock = "Dar Kbolt" .. string.char(64 + i)
        local id = warlock .. "@" .. VICTIM .. "@" .. now
        assert.is_true(w:rideStarted(id, VICTIM, warlock, now, VICTIM))
        if w:deathReported(report({ rideId = id, warlock = warlock, secs = 5 }), VICTIM, now + 5) then
          heavy = heavy + 1
        end
      end
      assert.are.equal(1, heavy)
      assert.are.equal(1, countDeaths())
    end)

    it("an observed death on a second ride is not heavy either", function()
      firstDeath()
      assert.is_true(w:arrived(RIDE, VICTIM, ARRIVED, VICTIM))
      local second = secondRide(T0 + 300)
      assert.is_true(w:arrived(second, VICTIM, T0 + 310, VICTIM))
      assert.is_nil(w:observedDeath(VICTIM, T0 + 320))
      assert.is_nil(db.deaths[SECOND_WARLOCK])
      assert.are.equal(1, countDeaths())
    end)

    it("does the same for a first heavy death that was observed", function()
      arrivedRide()
      assert.is_not_nil(w:observedDeath(VICTIM, ARRIVED + 5))
      local second = secondRide(ARRIVED + 100)
      assert.is_nil(w:deathReported(report({ rideId = second, warlock = SECOND_WARLOCK, secs = 5 }), VICTIM, ARRIVED + 110))
      assert.are.equal(1, countDeaths())
    end)

    it("reads the first death from a db that already has it", function()
      assert.is_true(ns.Ratings.addDeath(db, {
        target = WARLOCK, victim = VICTIM, id = RIDE, ts = T0, heavy = true, source = "self",
      }, T0))
      w = ns.Witness.new(db)
      local second = secondRide(T0 + 100)
      assert.is_nil(w:deathReported(report({ rideId = second, warlock = SECOND_WARLOCK, secs = 5 }), VICTIM, T0 + 110))
      assert.are.equal(1, countDeaths())
    end)

    it("still takes the same ride's death again, as one death", function()
      firstDeath()
      assert.is_not_nil(w:deathReported(report(), VICTIM, T0 + 41))
      assert.is_not_nil(w:deathReported(report(), RELAYER, T0 + 42))
      assert.are.equal(1, countDeaths())
    end)

    it("does not limit other victims, or relayed (light) deaths", function()
      firstDeath()
      local other = WARLOCK .. "@Mal Ice@" .. T0
      assert.is_true(w:rideStarted(other, "Mal Ice", WARLOCK, T0, "Mal Ice"))
      assert.is_true(w:deathReported(report({ rideId = other, victim = "Mal Ice" }), "Mal Ice", T0 + 40).heavy)
      for i = 1, 5 do
        local id = SECOND_WARLOCK .. "@" .. VICTIM .. "@" .. (T0 + 1000 + i)
        local death = w:deathReported(report({ rideId = id, warlock = SECOND_WARLOCK }), RELAYER, T0 + 1000 + i)
        assert.is_false(death.heavy)
      end
      assert.are.equal(7, countDeaths())
    end)

    it("frees the slot when the death is taken back", function()
      firstDeath()
      assert.are.equal(1, w:aliveEvidence(VICTIM, T0 + 40 + 61))
      nothingStored()
      local second = secondRide(T0 + 200)
      assert.is_true(w:arrived(second, VICTIM, T0 + 210, VICTIM))
      assert.is_not_nil(w:observedDeath(VICTIM, T0 + 220))
      assert.are.equal(1, countDeaths())
    end)

    it("notices a heavy death that was taken out of the db behind its back", function()
      firstDeath()
      assert.is_true(ns.Ratings.removeDeath(db, WARLOCK, RIDE))
      local second = secondRide(T0 + 100)
      assert.is_true(w:deathReported(report({ rideId = second, warlock = SECOND_WARLOCK, secs = 5 }), VICTIM, T0 + 110).heavy)
    end)

    it("is not fooled by a failed store", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      db._newer = true
      assert.is_nil(w:deathReported(report(), VICTIM, T0 + 40))
      db._newer = nil
      local second = secondRide(T0 + 100)
      assert.is_true(w:deathReported(report({ rideId = second, warlock = SECOND_WARLOCK, secs = 5 }), VICTIM, T0 + 110).heavy)
    end)
  end)

  describe("open rides per victim (R32)", function()
    local function start(i)
      local id = WARLOCK .. "@" .. VICTIM .. "@" .. (T0 + i)
      return id, w:rideStarted(id, VICTIM, WARLOCK, T0 + i, VICTIM)
    end

    local function openRides()
      local n = 0
      for _ in pairs(w.rides) do
        n = n + 1
      end
      return n
    end

    it("keeps at most 3 open rides from a flood of ride starts", function()
      local accepted = {}
      for i = 1, 50 do
        local id, ok = start(i)
        if ok then
          accepted[#accepted + 1] = id
        end
      end
      assert.are.equal(3, #accepted)
      assert.are.equal(3, openRides())
      for _, id in ipairs(accepted) do
        assert.is_not_nil(w.rides[id])
      end
      assert.are.equal(WARLOCK .. "@" .. VICTIM .. "@" .. (T0 + 1), accepted[1])
      assert.are.equal(WARLOCK .. "@" .. VICTIM .. "@" .. (T0 + 3), accepted[3])
    end)

    it("hearing a known ride's start again is still fine at the limit", function()
      for i = 1, 3 do
        assert.is_true(select(2, start(i)))
      end
      assert.is_true(select(2, start(2)))
      assert.is_false(select(2, start(4)))
    end)

    it("takes new ride starts again once one expires", function()
      for i = 1, 3 do
        assert.is_true(select(2, start(i)))
      end
      assert.is_false(select(2, start(4)))
      assert.are.equal(1, w:expire(T0 + 1 + MEMORY + 1))
      assert.is_true(select(2, start(5)))
      assert.is_false(select(2, start(6)))
      assert.are.equal(3, openRides())
    end)

    it("limits each victim on its own", function()
      for i = 1, 10 do
        start(i)
      end
      local other = WARLOCK .. "@Mal Ice@" .. T0
      assert.is_true(w:rideStarted(other, "Mal Ice", WARLOCK, T0, "Mal Ice"))
      assert.are.equal(4, openRides())
    end)

    it("still finds a death on a ride that was kept", function()
      for i = 1, 6 do
        start(i)
      end
      local id = WARLOCK .. "@" .. VICTIM .. "@" .. (T0 + 2)
      assert.is_true(w:arrived(id, VICTIM, T0 + 20, VICTIM))
      assert.are.equal(id, w:observedDeath(VICTIM, T0 + 30).id)
    end)
  end)

  describe("no walking of everything (R34)", function()
    it("aliveEvidence finds a victim's deaths through an index, not by walking db.deaths", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_not_nil(w:deathReported(report(), VICTIM, T0 + 40))
      assert.is_not_nil(w:deathReported(report({ rideId = "r-light", victim = "Mal Ice" }), RELAYER, T0 + 41))
      -- pairs() over a stand-in that only forwards lookups sees nothing, so a
      -- walk of db.deaths finds no death at all.
      local real = db.deaths
      db.deaths = setmetatable({}, { __index = real })
      assert.are.equal(1, w:aliveEvidence(VICTIM, T0 + 40 + 61))
      assert.is_not_nil(db.liars[VICTIM])
      assert.is_nil(real[WARLOCK][RIDE])
      assert.is_not_nil(real[WARLOCK]["r-light"], "another victim's death is left alone")
    end)

    it("observedDeath finds a victim's rides through a map of their own, not by walking every ride", function()
      arrivedRide()
      local real = w.rides
      w.rides = setmetatable({}, { __index = real })
      local death = w:observedDeath(VICTIM, ARRIVED + 5)
      assert.is_not_nil(death)
      assert.are.equal(RIDE, death.id)
    end)

    it("keeps its indexes in step when rides expire and deaths are taken back", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_true(w:arrived(RIDE, VICTIM, ARRIVED, VICTIM))
      assert.are.equal(1, w:expire(T0 + MEMORY + 1))
      assert.is_nil(w:observedDeath(VICTIM, ARRIVED + 5))
      assert.is_nil(w:deathReported(report(), VICTIM, ARRIVED + 5))
      nothingStored()
    end)
  end)

  describe("the arrival time bounds a report (R33)", function()
    it("rejects a self report long after the arrival, whatever secs says", function()
      arrivedRide()
      assert.is_nil(w:deathReported(report({ secs = 5 }), VICTIM, ARRIVED + 25 * 60))
      nothingStored()
    end)

    it("rejects a relayed report long after a known arrival too", function()
      arrivedRide()
      assert.is_nil(w:deathReported(report({ secs = 5 }), RELAYER, ARRIVED + 25 * 60))
      nothingStored()
    end)

    it("allows the death window plus 30 s of transport slack, to the second", function()
      arrivedRide()
      assert.is_nil(w:deathReported(report({ secs = 5 }), VICTIM, ARRIVED + 151))
      nothingStored()
      assert.is_true(w:deathReported(report({ secs = 5 }), VICTIM, ARRIVED + 150).heavy)
      assert.is_true(w:deathReported(report({ secs = 5 }), VICTIM, ARRIVED).heavy)
    end)

    it("rejects a report that is stamped before the arrival", function()
      arrivedRide()
      assert.is_nil(w:deathReported(report({ secs = 5 }), VICTIM, ARRIVED - 1))
      assert.is_nil(w:deathReported(report({ secs = 5 }), RELAYER, ARRIVED - 1))
      nothingStored()
    end)

    it("keeps the claimed secs rule when no arrival was heard", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_true(w:deathReported(report({ secs = 120 }), VICTIM, T0 + 3600).heavy)
      assert.is_nil(w:deathReported(report({ secs = 121 }), VICTIM, T0 + 3600))
    end)

    it("does not touch a relayed report about a ride this client never heard", function()
      assert.is_false(w:deathReported(report({ secs = 5 }), RELAYER, T0 + 3600).heavy)
    end)
  end)

  describe("relayedDeath", function()
    local function rec(fields)
      local r = { target = WARLOCK, victim = VICTIM, id = RIDE, ts = T0 + 30 }
      for k, v in pairs(fields or {}) do
        r[k] = v
      end
      return r
    end

    it("stores a death from a query reply as light, relayed by the sender", function()
      local death = w:relayedDeath(rec(), RELAYER, T0 + 100)
      assert.are.same({
        target = WARLOCK,
        victim = VICTIM,
        id = RIDE,
        ts = T0 + 30,
        heavy = false,
        source = "relayed",
        via = { [RELAYER] = true },
      }, death)
      local stored = db.deaths[WARLOCK][RIDE]
      assert.is_false(stored.heavy)
      assert.are.same({ [RELAYER] = true }, stored.via)
      assert.are.equal("relayed", stored.source)
    end)

    it("is taken back, and the relayer struck, when the victim is seen alive", function()
      assert.is_not_nil(w:relayedDeath(rec(), RELAYER, T0 + 100))
      assert.are.equal(1, w:aliveEvidence(VICTIM, T0 + 30 + 61))
      assert.are.equal(1, db.strikes[RELAYER])
      nothingStored()
    end)

    it("never makes a heavy death, even for the victim's own name or a known ride", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_false(w:relayedDeath(rec(), RELAYER, T0 + 100).heavy)
      assert.is_false(db.deaths[WARLOCK][RIDE].heavy)
      assert.is_false(w:relayedDeath(rec({ id = "other-ride" }), VICTIM, T0 + 100).heavy)
    end)

    it("does not weaken a first-hand death", function()
      assert.is_true(w:rideStarted(RIDE, VICTIM, WARLOCK, T0, VICTIM))
      assert.is_not_nil(w:deathReported(report(), VICTIM, T0 + 30))
      assert.is_not_nil(w:relayedDeath(rec(), RELAYER, T0 + 100))
      assert.is_true(db.deaths[WARLOCK][RIDE].heavy)
      assert.are.equal("self", db.deaths[WARLOCK][RIDE].source)
    end)

    it("refuses a ride id that names other players than the record does", function()
      assert.is_nil(w:relayedDeath(rec({ victim = "Liar Larry" }), RELAYER, T0 + 100))
      assert.is_nil(w:relayedDeath(rec({ target = "Dar Kbolt" }), RELAYER, T0 + 100))
      nothingStored()
    end)

    it("must agree with a ride this client knows, and with its arrival", function()
      assert.is_true(w:rideStarted("r1", VICTIM, WARLOCK, T0, VICTIM))
      assert.is_nil(w:relayedDeath(rec({ id = "r1", victim = "Liar Larry" }), RELAYER, T0 + 100))
      assert.is_nil(w:relayedDeath(rec({ id = "r1", target = "Dar Kbolt" }), RELAYER, T0 + 100))
      assert.is_true(w:arrived("r1", VICTIM, T0 + 10, VICTIM))
      assert.is_nil(w:relayedDeath(rec({ id = "r1", ts = T0 + 10 + 1500 }), RELAYER, T0 + 3000))
      assert.is_nil(w:relayedDeath(rec({ id = "r1", ts = T0 + 9 }), RELAYER, T0 + 3000))
      nothingStored()
      assert.is_not_nil(w:relayedDeath(rec({ id = "r1", ts = T0 + 10 + 150 }), RELAYER, T0 + 3000))
    end)

    it("fails closed on a malformed record, relayer or time", function()
      for _, fields in ipairs({
        { target = "" }, { victim = "  " }, { victim = 5 }, { id = "" }, { id = 5 },
        { ts = "now" }, { ts = 0 / 0 }, { ts = math.huge },
      }) do
        assert.is_nil(w:relayedDeath(rec(fields), RELAYER, T0 + 100))
      end
      assert.is_nil(w:relayedDeath(nil, RELAYER, T0 + 100))
      assert.is_nil(w:relayedDeath("death", RELAYER, T0 + 100))
      assert.is_nil(w:relayedDeath(rec(), nil, T0 + 100))
      assert.is_nil(w:relayedDeath(rec(), "  ", T0 + 100))
      assert.is_nil(w:relayedDeath(rec(), RELAYER, nil))
      assert.is_nil(w:relayedDeath(rec(), RELAYER, 0 / 0))
      nothingStored()
    end)

    it("refuses a death dated ahead of the receiver's clock", function()
      assert.is_nil(w:relayedDeath(rec({ ts = T0 + 100 + 301 }), RELAYER, T0 + 100))
      nothingStored()
    end)

    it("returns nil when the db is read-only", function()
      db._newer = true
      assert.is_nil(w:relayedDeath(rec(), RELAYER, T0 + 100))
      nothingStored()
    end)
  end)
end)
