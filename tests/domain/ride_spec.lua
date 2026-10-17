describe("Ride", function()
  local ns, Ride

  before_each(function()
    ns = Taxi.load()
    Ride = ns.Ride
  end)

  local function newRide(kind, rideId)
    return Ride.new{
      rideId = rideId,
      kind = kind or "summon",
      driver = "Dar Kbolt",
      traveler = "Tra Vler",
      standId = "Dar Kbolt@50",
      offer = 5000,
      dest = "Stormwind",
      now = 100,
    }
  end

  -- Applies each event in turn, one second apart starting at `from`; every one
  -- must be allowed. ACCEPT carries a rideId, as it does on the wire.
  local function play(r, events, from)
    local t = from or 101
    for _, event in ipairs(events) do
      assert.is_true(Ride.apply(r, event, t, { rideId = "R1" }), event)
      t = t + 1
    end
    return r
  end

  -- The events that bring a fresh ride of `kind` to `state`.
  local PATHS = {
    requested = {},
    accepted = { "ACCEPT" },
    grouped = { "ACCEPT", "JOINED" },
    summoning = { "ACCEPT", "JOINED", "SUMMON_OFFERED" },
    portal = { "ACCEPT", "JOINED", "PORTAL_UP" },
    arrived = { "ACCEPT", "JOINED", "SUMMON_OFFERED", "ARRIVED" },
    done = { "ACCEPT", "JOINED", "SUMMON_OFFERED", "ARRIVED", "FINISHED" },
    declined = { "DECLINE" },
    cancelled = { "CANCEL" },
  }

  local function rideAt(state)
    local kind = state == "portal" and "portal" or "summon"
    return play(newRide(kind), PATHS[state])
  end

  -- A deep copy, to prove a failed apply changed nothing (times included).
  local function snapshot(r)
    local out = {}
    for k, v in pairs(r) do
      if type(v) == "table" then
        local inner = {}
        for k2, v2 in pairs(v) do inner[k2] = v2 end
        v = inner
      end
      out[k] = v
    end
    return out
  end

  local function assertUnchanged(before, r)
    assert.are.same(before, snapshot(r))
  end

  describe("makeId", function()
    it("joins driver, traveler and time with @", function()
      assert.are.equal("Dar Kbolt@Tra Vler@1234", Ride.makeId("Dar Kbolt", "Tra Vler", 1234))
    end)
  end)

  describe("new", function()
    it("starts requested with no retries and the request time", function()
      local r = newRide("summon")
      assert.are.equal("requested", r.state)
      assert.are.equal(0, r.retries)
      assert.are.same({ requested = 100 }, r.times)
      assert.are.equal("summon", r.kind)
      assert.are.equal("Dar Kbolt", r.driver)
      assert.are.equal("Tra Vler", r.traveler)
      assert.are.equal("Dar Kbolt@50", r.standId)
      assert.are.equal(5000, r.offer)
      assert.are.equal("Stormwind", r.dest)
    end)

    it("keeps a rideId it is given and leaves it nil otherwise", function()
      assert.are.equal("R9", newRide("summon", "R9").rideId)
      assert.is_nil(newRide("summon").rideId)
    end)
  end)

  describe("summon happy path", function()
    it("walks requested to done, stamping each state's time", function()
      local r = newRide("summon")
      assert.is_true(Ride.apply(r, "ACCEPT", 110, { rideId = "R1" }))
      assert.are.equal("accepted", r.state)
      assert.are.equal("R1", r.rideId)
      assert.is_true(Ride.apply(r, "JOINED", 120))
      assert.are.equal("grouped", r.state)
      assert.is_true(Ride.apply(r, "SUMMON_OFFERED", 130))
      assert.are.equal("summoning", r.state)
      assert.is_true(Ride.apply(r, "ARRIVED", 140))
      assert.are.equal("arrived", r.state)
      assert.are.equal(140, r.times.arrived)
      assert.is_false(Ride.isFinal(r))
      assert.is_true(Ride.apply(r, "FINISHED", 150))
      assert.are.equal("done", r.state)
      assert.is_true(Ride.isFinal(r))
      assert.are.same({
        requested = 100, accepted = 110, grouped = 120,
        summoning = 130, arrived = 140, done = 150,
      }, r.times)
      assert.are.equal(0, r.retries)
    end)
  end)

  describe("portal path", function()
    it("walks accepted to grouped to portal to arrived", function()
      local r = newRide("portal")
      assert.is_true(Ride.apply(r, "ACCEPT", 110, { rideId = "R2" }))
      assert.are.equal("accepted", r.state)
      assert.is_true(Ride.apply(r, "JOINED", 120))
      assert.are.equal("grouped", r.state)
      assert.is_true(Ride.apply(r, "PORTAL_UP", 130))
      assert.are.equal("portal", r.state)
      assert.are.equal(130, r.times.portal)
      assert.is_true(Ride.apply(r, "ARRIVED", 140))
      assert.are.equal("arrived", r.state)
      assert.are.equal(140, r.times.arrived)
      assert.is_true(Ride.apply(r, "FINISHED", 150))
      assert.are.equal("done", r.state)
    end)
  end)

  describe("ACCEPT", function()
    it("stores the rideId the driver sent", function()
      local r = newRide("summon")
      assert.is_true(Ride.apply(r, "ACCEPT", 110, { rideId = "Dar Kbolt@Tra Vler@109" }))
      assert.are.equal("Dar Kbolt@Tra Vler@109", r.rideId)
    end)

    it("is rejected without a rideId string, leaving the ride untouched", function()
      -- Each case wraps the data argument, so the first can be a real nil.
      local cases = {
        { nil },
        { {} },
        { { rideId = 42 } },
        { { rideId = true } },
        { { rideId = {} } },
      }
      for i, case in ipairs(cases) do
        local r = newRide("summon")
        local before = snapshot(r)
        local ok, why = Ride.apply(r, "ACCEPT", 110, case[1])
        assert.is_nil(ok, i)
        assert.are.equal("bad_transition", why, i)
        assertUnchanged(before, r)
        assert.are.equal("requested", r.state, i)
        assert.is_nil(r.rideId, i)
        assert.is_nil(r.times.accepted, i)
      end
    end)

    it("is only valid from requested", function()
      for _, state in ipairs{ "accepted", "grouped", "summoning", "portal", "arrived", "done", "declined", "cancelled" } do
        local r = rideAt(state)
        local before = snapshot(r)
        local ok, why = Ride.apply(r, "ACCEPT", 200, { rideId = "OTHER" })
        assert.is_nil(ok, state)
        assert.are.equal("bad_transition", why, state)
        assertUnchanged(before, r)
        assert.are_not.equal("OTHER", r.rideId, state)
      end
    end)
  end)

  describe("DECLINE", function()
    it("moves a requested ride to declined", function()
      local r = newRide("summon")
      assert.is_true(Ride.apply(r, "DECLINE", 105))
      assert.are.equal("declined", r.state)
      assert.are.equal(105, r.times.declined)
      assert.is_true(Ride.isFinal(r))
    end)

    it("is a bad transition from every other state", function()
      for _, state in ipairs{ "accepted", "grouped", "summoning", "portal", "arrived", "done", "declined", "cancelled" } do
        local r = rideAt(state)
        local before = snapshot(r)
        local ok, why = Ride.apply(r, "DECLINE", 200)
        assert.is_nil(ok, state)
        assert.are.equal("bad_transition", why, state)
        assertUnchanged(before, r)
      end
    end)
  end)

  describe("kind gates", function()
    it("rejects SUMMON_OFFERED on a portal ride", function()
      local r = play(newRide("portal"), PATHS.grouped)
      local before = snapshot(r)
      local ok, why = Ride.apply(r, "SUMMON_OFFERED", 200)
      assert.is_nil(ok)
      assert.are.equal("bad_transition", why)
      assertUnchanged(before, r)
      assert.are.equal("grouped", r.state)
    end)

    it("rejects PORTAL_UP on a summon ride", function()
      local r = play(newRide("summon"), PATHS.grouped)
      local before = snapshot(r)
      local ok, why = Ride.apply(r, "PORTAL_UP", 200)
      assert.is_nil(ok)
      assert.are.equal("bad_transition", why)
      assertUnchanged(before, r)
      assert.are.equal("grouped", r.state)
    end)
  end)

  describe("one retry", function()
    it("goes back to grouped on the first SUMMON_FAILED, then cancels on the second", function()
      local r = play(newRide("summon"), PATHS.summoning)
      assert.are.equal(0, r.retries)

      assert.is_true(Ride.apply(r, "SUMMON_FAILED", 200))
      assert.are.equal("grouped", r.state)
      assert.are.equal(1, r.retries)
      assert.are.equal(200, r.times.grouped)
      assert.is_false(Ride.isFinal(r))

      assert.is_true(Ride.apply(r, "SUMMON_OFFERED", 210))
      assert.are.equal("summoning", r.state)
      assert.are.equal(210, r.times.summoning)

      assert.is_true(Ride.apply(r, "SUMMON_FAILED", 220))
      assert.are.equal("cancelled", r.state)
      assert.are.equal(1, r.retries)
      assert.are.equal(220, r.times.cancelled)
      assert.is_true(Ride.isFinal(r))
    end)

    it("can still arrive after a retry", function()
      local r = play(newRide("summon"), PATHS.summoning)
      play(r, { "SUMMON_FAILED", "SUMMON_OFFERED", "ARRIVED" }, 200)
      assert.are.equal("arrived", r.state)
      assert.are.equal(1, r.retries)
    end)

    it("is only valid while summoning", function()
      for _, state in ipairs{ "requested", "accepted", "grouped", "portal", "arrived", "done", "declined", "cancelled" } do
        local r = rideAt(state)
        local before = snapshot(r)
        local ok, why = Ride.apply(r, "SUMMON_FAILED", 200)
        assert.is_nil(ok, state)
        assert.are.equal("bad_transition", why, state)
        assertUnchanged(before, r)
        assert.are.equal(0, r.retries, state)
      end
    end)
  end)

  describe("bad transition", function()
    it("rejects ARRIVED from requested and leaves the ride unchanged", function()
      local r = newRide("summon")
      local before = snapshot(r)
      local ok, why = Ride.apply(r, "ARRIVED", 200)
      assert.is_nil(ok)
      assert.are.equal("bad_transition", why)
      assert.are.equal("requested", r.state)
      assert.are.equal(0, r.retries)
      assert.is_nil(r.times.arrived)
      assert.is_nil(r.rideId)
      assertUnchanged(before, r)
    end)

    it("rejects an event it does not know", function()
      local r = newRide("summon")
      local before = snapshot(r)
      local ok, why = Ride.apply(r, "TELEPORT", 200)
      assert.is_nil(ok)
      assert.are.equal("bad_transition", why)
      assertUnchanged(before, r)
    end)

    it("rejects every event that does not fit the state", function()
      local ALLOWED = {
        requested = { ACCEPT = true, DECLINE = true, CANCEL = true },
        accepted = { JOINED = true, CANCEL = true },
        grouped = { SUMMON_OFFERED = true, CANCEL = true },
        summoning = { SUMMON_FAILED = true, ARRIVED = true, CANCEL = true },
        portal = { ARRIVED = true, CANCEL = true },
        arrived = { FINISHED = true, CANCEL = true },
        done = {},
        declined = {},
        cancelled = {},
      }
      local EVENTS = {
        "ACCEPT", "DECLINE", "JOINED", "SUMMON_OFFERED", "PORTAL_UP",
        "SUMMON_FAILED", "ARRIVED", "FINISHED", "CANCEL",
      }
      for state, allowed in pairs(ALLOWED) do
        for _, event in ipairs(EVENTS) do
          local r = rideAt(state)
          local before = snapshot(r)
          local ok, why = Ride.apply(r, event, 300, { rideId = "R1" })
          if allowed[event] then
            assert.is_true(ok, state .. " " .. event)
          else
            assert.is_nil(ok, state .. " " .. event)
            assert.are.equal("bad_transition", why, state .. " " .. event)
            assertUnchanged(before, r)
          end
        end
      end
    end)
  end)

  describe("final", function()
    it("treats done, declined and cancelled as final and the rest as live", function()
      for _, state in ipairs{ "done", "declined", "cancelled" } do
        assert.is_true(Ride.isFinal(rideAt(state)), state)
      end
      for _, state in ipairs{ "requested", "accepted", "grouped", "summoning", "portal", "arrived" } do
        assert.is_false(Ride.isFinal(rideAt(state)), state)
      end
    end)

    it("rejects CANCEL after done", function()
      local r = rideAt("done")
      local before = snapshot(r)
      local ok, why = Ride.apply(r, "CANCEL", 400)
      assert.is_nil(ok)
      assert.are.equal("bad_transition", why)
      assert.are.equal("done", r.state)
      assert.is_nil(r.times.cancelled)
      assertUnchanged(before, r)
    end)

    it("rejects every event from every final state", function()
      local EVENTS = {
        "ACCEPT", "DECLINE", "JOINED", "SUMMON_OFFERED", "PORTAL_UP",
        "SUMMON_FAILED", "ARRIVED", "FINISHED", "CANCEL",
      }
      for _, state in ipairs{ "done", "declined", "cancelled" } do
        for _, event in ipairs(EVENTS) do
          local r = rideAt(state)
          local before = snapshot(r)
          local ok, why = Ride.apply(r, event, 400, { rideId = "R1" })
          assert.is_nil(ok, state .. " " .. event)
          assert.are.equal("bad_transition", why)
          assertUnchanged(before, r)
        end
      end
    end)
  end)

  describe("CANCEL", function()
    it("cancels a ride from each non-final state and stamps the time", function()
      for _, state in ipairs{ "requested", "accepted", "grouped", "summoning", "portal", "arrived" } do
        local r = rideAt(state)
        assert.are.equal(state, r.state)
        assert.is_true(Ride.apply(r, "CANCEL", 500), state)
        assert.are.equal("cancelled", r.state, state)
        assert.are.equal(500, r.times.cancelled, state)
        assert.is_true(Ride.isFinal(r), state)
      end
    end)

    it("keeps the earlier times and retries of the ride it cancels", function()
      local r = play(newRide("summon"), PATHS.summoning)
      play(r, { "SUMMON_FAILED" }, 200)
      assert.is_true(Ride.apply(r, "CANCEL", 300))
      assert.are.equal("cancelled", r.state)
      assert.are.equal(1, r.retries)
      assert.are.equal(103, r.times.summoning)
      assert.are.equal("R1", r.rideId)
    end)
  end)
end)
