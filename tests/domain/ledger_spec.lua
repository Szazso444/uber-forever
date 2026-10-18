describe("Ledger", function()
  local ns, Ledger, l

  local STAND = "Ana Smith@100000"
  local OWNER = "Ana Smith"
  local ONE = "Cli One"
  local TWO = "Cli Two"
  local T0 = 100000

  -- Ride ids as Ride.makeId builds them: driver@traveler@seconds.
  local function ride(n)
    return OWNER .. "@Tom Traveler@" .. (T0 + n)
  end

  -- A tip both the traveler and the warlock reported, arriving at `arrived`.
  local function agreed(rideId, amount, arrived)
    assert.is_true(Ledger.tip(l, rideId, amount, arrived))
    assert.is_true(Ledger.ack(l, rideId, amount))
  end

  before_each(function()
    ns = Taxi.load()
    Ledger = ns.Ledger
    l = Ledger.new(STAND, OWNER)
  end)

  describe("new", function()
    it("needs a stand id and an owner", function()
      assert.is_table(l)
      assert.are.same({ nil, "bad_args" }, { Ledger.new(nil, OWNER) })
      assert.are.same({ nil, "bad_args" }, { Ledger.new("", OWNER) })
      assert.are.same({ nil, "bad_args" }, { Ledger.new(STAND, nil) })
      assert.are.same({ nil, "bad_args" }, { Ledger.new(STAND, "  ") })
    end)
  end)

  describe("join and leave", function()
    it("a shift has an id built from stand, clicker and the whole join second", function()
      local shift = Ledger.join(l, ONE, 25, T0 + 5.9)
      assert.are.same({
        shiftId = STAND .. ":" .. ONE .. ":" .. (T0 + 5),
        clicker = ONE,
        pct = 25,
        joinTs = T0 + 5.9,
      }, shift)
    end)

    it("leaving closes the shift and hands it back", function()
      Ledger.join(l, ONE, 25, T0)
      local shift = Ledger.leave(l, ONE, T0 + 600)
      assert.are.same({
        shiftId = STAND .. ":" .. ONE .. ":" .. T0,
        clicker = ONE,
        pct = 25,
        joinTs = T0,
        leaveTs = T0 + 600,
      }, shift)
    end)

    it("compares clickers by the whole tidied name", function()
      Ledger.join(l, "  Cli   One ", 25, T0)
      agreed(ride(1), 10000, T0 + 1)
      assert.are.equal(2500, (Ledger.owed(l, ONE)))
      assert.is_not_nil(Ledger.leave(l, "Cli One", T0 + 2))
    end)

    it("refuses a bad percentage and starts no shift", function()
      for _, bad in ipairs({ 0, 100, -5, 25.5, 0 / 0, math.huge, "25" }) do
        assert.are.same({ nil, "bad_pct" }, { Ledger.join(l, ONE, bad, T0) })
      end
      assert.are.same({ nil, "bad_pct" }, { Ledger.join(l, ONE, nil, T0) })
      agreed(ride(1), 10000, T0 + 1)
      assert.are.equal(0, (Ledger.owed(l, ONE)))
    end)

    it("refuses a bad clicker, a bad time and the owner", function()
      assert.are.same({ nil, "bad_clicker" }, { Ledger.join(l, nil, 25, T0) })
      assert.are.same({ nil, "bad_clicker" }, { Ledger.join(l, "", 25, T0) })
      assert.are.same({ nil, "bad_ts" }, { Ledger.join(l, ONE, 25, nil) })
      assert.are.same({ nil, "bad_ts" }, { Ledger.join(l, ONE, 25, 0 / 0) })
      assert.are.same({ nil, "bad_ts" }, { Ledger.join(l, ONE, 25, math.huge) })
      assert.are.same({ nil, "is_owner" }, { Ledger.join(l, " Ana  Smith", 25, T0) })
    end)

    it("refuses a second join while the shift is open", function()
      Ledger.join(l, ONE, 25, T0)
      assert.are.same({ nil, "on_shift" }, { Ledger.join(l, ONE, 50, T0 + 10) })
      agreed(ride(20), 10000, T0 + 20)
      assert.are.equal(2500, (Ledger.owed(l, ONE)))
    end)

    it("refuses to leave without an open shift, twice, or before the join", function()
      assert.are.same({ nil, "not_on_shift" }, { Ledger.leave(l, ONE, T0) })
      Ledger.join(l, ONE, 25, T0 + 100)
      assert.are.same({ nil, "bad_ts" }, { Ledger.leave(l, ONE, T0 + 99) })
      assert.are.same({ nil, "bad_ts" }, { Ledger.leave(l, ONE, nil) })
      assert.are.same({ nil, "bad_ts" }, { Ledger.leave(l, ONE, 0 / 0) })
      assert.is_not_nil(Ledger.leave(l, ONE, T0 + 100))
      assert.are.same({ nil, "not_on_shift" }, { Ledger.leave(l, ONE, T0 + 200) })
    end)

    it("a clicker who rejoins gets a new shift that counts only its own rides", function()
      Ledger.join(l, ONE, 25, T0)
      agreed(ride(10), 10000, T0 + 10)
      assert.are.equal(2500, (Ledger.owed(l, ONE)))
      Ledger.leave(l, ONE, T0 + 100)
      Ledger.received(l, ONE, 2500)

      local second = Ledger.join(l, ONE, 50, T0 + 200)
      assert.are.equal(STAND .. ":" .. ONE .. ":" .. (T0 + 200), second.shiftId)
      assert.are.equal(0, (Ledger.owed(l, ONE)))
      assert.are.equal(0, Ledger.receivedBy(l, ONE))
      agreed(ride(210), 4000, T0 + 210)
      assert.are.equal(2000, (Ledger.owed(l, ONE)))
    end)
  end)

  describe("owed", function()
    it("agreed tips times pct", function()
      Ledger.join(l, ONE, 25, T0)
      agreed(ride(10), 10000, T0 + 10)
      agreed(ride(20), 5000, T0 + 20)
      local owed, disputed, pending = Ledger.owed(l, ONE)
      assert.are.equal(3750, owed)
      assert.are.same({}, disputed)
      assert.are.same({}, pending)
    end)

    it("different pcts per clicker", function()
      Ledger.join(l, ONE, 60, T0)
      Ledger.join(l, TWO, 20, T0)
      agreed(ride(10), 10000, T0 + 10)
      assert.are.equal(6000, (Ledger.owed(l, ONE)))
      assert.are.equal(2000, (Ledger.owed(l, TWO)))
    end)

    it("rounds each tip's share down to whole copper", function()
      Ledger.join(l, ONE, 25, T0)
      agreed(ride(10), 999, T0 + 10) -- 249.75
      agreed(ride(20), 7, T0 + 20) -- 1.75
      assert.are.equal(250, (Ledger.owed(l, ONE)))
    end)

    it("a clicker nobody joined is owed nothing", function()
      agreed(ride(10), 10000, T0 + 10)
      local owed, disputed, pending = Ledger.owed(l, ONE)
      assert.are.equal(0, owed)
      assert.are.same({}, disputed)
      assert.are.same({}, pending)
      assert.are.equal(0, (Ledger.owed(l, nil)))
    end)

    it("outside shift not counted", function()
      Ledger.join(l, ONE, 25, T0 + 100)
      agreed(ride(50), 10000, T0 + 50) -- arrived before the clicker joined
      agreed(ride(150), 10000, T0 + 150) -- during the shift
      Ledger.leave(l, ONE, T0 + 200)
      agreed(ride(250), 10000, T0 + 250) -- after the clicker left
      local owed, disputed, pending = Ledger.owed(l, ONE)
      assert.are.equal(2500, owed)
      assert.are.same({}, disputed)
      assert.are.same({}, pending)
    end)

    it("the shift window includes both of its ends", function()
      Ledger.join(l, ONE, 25, T0 + 100)
      Ledger.leave(l, ONE, T0 + 200)
      agreed(ride(1), 10000, T0 + 100)
      agreed(ride(2), 10000, T0 + 200)
      agreed(ride(3), 10000, T0 + 99.9)
      agreed(ride(4), 10000, T0 + 200.1)
      assert.are.equal(5000, (Ledger.owed(l, ONE)))
    end)

    it("after leaving, owed still reads the shift that was just closed", function()
      Ledger.join(l, ONE, 25, T0)
      agreed(ride(10), 10000, T0 + 10)
      Ledger.leave(l, ONE, T0 + 100)
      assert.are.equal(2500, (Ledger.owed(l, ONE)))
    end)

    it("disputed listed and excluded", function()
      Ledger.join(l, ONE, 25, T0)
      agreed(ride(10), 10000, T0 + 10)
      assert.is_true(Ledger.tip(l, ride(20), 10000, T0 + 20))
      assert.is_true(Ledger.ack(l, ride(20), 9000))
      local owed, disputed, pending = Ledger.owed(l, ONE)
      assert.are.equal(2500, owed)
      assert.are.same({ { rideId = ride(20), tip = 10000, ack = 9000 } }, disputed)
      assert.are.same({}, pending)
    end)

    it("lists several disputes in ride id order", function()
      Ledger.join(l, ONE, 25, T0)
      for _, n in ipairs({ 30, 10, 20 }) do
        Ledger.tip(l, ride(n), 1000, T0 + n)
        Ledger.ack(l, ride(n), 500)
      end
      local _, disputed = Ledger.owed(l, ONE)
      assert.are.same({ ride(10), ride(20), ride(30) }, {
        disputed[1].rideId, disputed[2].rideId, disputed[3].rideId,
      })
    end)

    it("pending without ack", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.tip(l, ride(10), 8000, T0 + 10)
      local owed, disputed, pending = Ledger.owed(l, ONE)
      assert.are.equal(0, owed)
      assert.are.same({}, disputed)
      assert.are.same({ { rideId = ride(10), tip = 8000 } }, pending)
    end)

    it("a pending tip counts once the warlock's ack agrees, whichever came first", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.tip(l, ride(10), 8000, T0 + 10)
      Ledger.ack(l, ride(10), 8000)
      Ledger.ack(l, ride(20), 4000) -- the ack beat the traveler's TIP
      local owed, _, pending = Ledger.owed(l, ONE)
      assert.are.equal(2000, owed)
      assert.are.same({}, pending)
      Ledger.tip(l, ride(20), 4000, T0 + 20)
      assert.are.equal(3000, (Ledger.owed(l, ONE)))
    end)

    it("an ack nobody tipped for counts for no one and is not listed", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.ack(l, ride(10), 10000)
      local owed, disputed, pending = Ledger.owed(l, ONE)
      assert.are.equal(0, owed)
      assert.are.same({}, disputed)
      assert.are.same({}, pending)
    end)

    it("pending and disputed tips outside the shift are not listed", function()
      Ledger.join(l, ONE, 25, T0 + 100)
      Ledger.leave(l, ONE, T0 + 200)
      Ledger.tip(l, ride(10), 1000, T0 + 10)
      Ledger.tip(l, ride(300), 1000, T0 + 300)
      Ledger.ack(l, ride(300), 900)
      local owed, disputed, pending = Ledger.owed(l, ONE)
      assert.are.equal(0, owed)
      assert.are.same({}, disputed)
      assert.are.same({}, pending)
    end)

    it("a repeated TIP keeps the first value", function()
      Ledger.join(l, ONE, 25, T0)
      assert.is_true(Ledger.tip(l, ride(10), 10000, T0 + 10))
      assert.are.same({ nil, "duplicate" }, { Ledger.tip(l, ride(10), 99999, T0 + 10) })
      Ledger.ack(l, ride(10), 10000)
      assert.are.equal(2500, (Ledger.owed(l, ONE)))
      -- and a later, different value cannot turn it into a dispute either
      Ledger.tip(l, ride(10), 1, T0 + 10)
      local owed, disputed = Ledger.owed(l, ONE)
      assert.are.equal(2500, owed)
      assert.are.same({}, disputed)
    end)

    it("a repeated TIP_ACK keeps the first value", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.tip(l, ride(10), 10000, T0 + 10)
      assert.is_true(Ledger.ack(l, ride(10), 10000))
      assert.are.same({ nil, "duplicate" }, { Ledger.ack(l, ride(10), 20000) })
      assert.are.equal(2500, (Ledger.owed(l, ONE)))

      Ledger.tip(l, ride(20), 10000, T0 + 20)
      Ledger.ack(l, ride(20), 6000)
      Ledger.ack(l, ride(20), 10000) -- cannot repair the dispute afterwards
      local owed, disputed = Ledger.owed(l, ONE)
      assert.are.equal(2500, owed)
      assert.are.same({ { rideId = ride(20), tip = 10000, ack = 6000 } }, disputed)
    end)

    it("ignores a fractional, negative or non-finite amount", function()
      Ledger.join(l, ONE, 25, T0)
      local bad = { 10.5, -1000, -0.5, 0 / 0, math.huge, -math.huge, "5000", true, {} }
      for _, amount in ipairs(bad) do
        assert.are.same({ nil, "bad_amount" }, { Ledger.tip(l, ride(10), amount, T0 + 10) })
        assert.are.same({ nil, "bad_amount" }, { Ledger.ack(l, ride(10), amount) })
      end
      assert.are.same({ nil, "bad_amount" }, { Ledger.tip(l, ride(10), nil, T0 + 10) })
      assert.are.same({ nil, "bad_amount" }, { Ledger.ack(l, ride(10), nil) })
      local owed, disputed, pending = Ledger.owed(l, ONE)
      assert.are.equal(0, owed)
      assert.are.same({}, disputed)
      assert.are.same({}, pending)
    end)

    it("an ignored bad amount does not use up the ride's one report", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.tip(l, ride(10), -5, T0 + 10)
      Ledger.ack(l, ride(10), 2.5)
      agreed(ride(10), 10000, T0 + 10)
      assert.are.equal(2500, (Ledger.owed(l, ONE)))
    end)

    it("accepts a tip of zero copper, which adds nothing", function()
      Ledger.join(l, ONE, 25, T0)
      agreed(ride(10), 0, T0 + 10)
      assert.are.equal(0, (Ledger.owed(l, ONE)))
    end)

    it("ignores a ride id that is not a non-empty string", function()
      Ledger.join(l, ONE, 25, T0)
      for _, bad in ipairs({ "", 5, true }) do
        assert.are.same({ nil, "bad_ride" }, { Ledger.tip(l, bad, 1000, T0 + 10) })
        assert.are.same({ nil, "bad_ride" }, { Ledger.ack(l, bad, 1000) })
      end
      assert.are.same({ nil, "bad_ride" }, { Ledger.tip(l, nil, 1000, T0 + 10) })
      assert.are.same({ nil, "bad_ride" }, { Ledger.ack(l, nil, 1000) })
    end)

    it("tip with no arrivedTs not counted", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.join(l, TWO, 50, T0)
      agreed(ride(10), 10000, nil)
      for _, who in ipairs({ ONE, TWO }) do
        local owed, disputed, pending = Ledger.owed(l, who)
        assert.are.equal(0, owed)
        assert.are.same({}, disputed)
        assert.are.same({}, pending)
      end
    end)

    it("a tip with a non-finite arrivedTs is never attributed to anyone", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.tip(l, ride(10), 10000, 0 / 0)
      Ledger.ack(l, ride(10), 10000)
      Ledger.tip(l, ride(20), 10000, math.huge) -- "after" an open shift forever
      Ledger.ack(l, ride(20), 10000)
      Ledger.tip(l, ride(30), 10000, -math.huge)
      Ledger.tip(l, ride(40), 10000, "100010")
      Ledger.ack(l, ride(40), 10000)
      local owed, disputed, pending = Ledger.owed(l, ONE)
      assert.are.equal(0, owed)
      assert.are.same({}, disputed)
      assert.are.same({}, pending)
    end)

    it("learning the arrival later (own observation) lets the tip count, still at the first amount", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.tip(l, ride(10), 10000, nil)
      Ledger.ack(l, ride(10), 10000)
      assert.are.equal(0, (Ledger.owed(l, ONE)))
      assert.is_true(Ledger.tip(l, ride(10), 55555, T0 + 10))
      assert.are.equal(2500, (Ledger.owed(l, ONE)))
      -- once known, the arrival is not rewritten either
      Ledger.tip(l, ride(10), 10000, T0 + 9999)
      assert.are.equal(2500, (Ledger.owed(l, ONE)))
    end)
  end)

  describe("received", function()
    it("received accumulates across multiple trades", function()
      Ledger.join(l, ONE, 25, T0)
      assert.are.equal(0, Ledger.receivedBy(l, ONE))
      assert.is_true(Ledger.received(l, ONE, 1000))
      assert.is_true(Ledger.received(l, ONE, 1500))
      assert.is_true(Ledger.received(l, ONE, 0))
      assert.are.equal(2500, Ledger.receivedBy(l, ONE))
    end)

    it("is kept per clicker", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.join(l, TWO, 25, T0)
      Ledger.received(l, ONE, 2500)
      Ledger.received(l, " Cli  Two", 700)
      assert.are.equal(2500, Ledger.receivedBy(l, ONE))
      assert.are.equal(700, Ledger.receivedBy(l, TWO))
      assert.are.equal(0, Ledger.receivedBy(l, "Nobody Here"))
      assert.are.equal(0, Ledger.receivedBy(l, nil))
    end)

    it("ignores a fractional, negative or non-finite amount", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.received(l, ONE, 100)
      for _, bad in ipairs({ 0.5, -100, 0 / 0, math.huge, "100", true }) do
        assert.are.same({ nil, "bad_amount" }, { Ledger.received(l, ONE, bad) })
      end
      assert.are.same({ nil, "bad_amount" }, { Ledger.received(l, ONE, nil) })
      assert.are.same({ nil, "bad_clicker" }, { Ledger.received(l, nil, 100) })
      assert.are.equal(100, Ledger.receivedBy(l, ONE))
    end)

    it("still counts gold that arrives after the shift ended", function()
      Ledger.join(l, ONE, 25, T0)
      Ledger.leave(l, ONE, T0 + 100)
      Ledger.received(l, ONE, 2500)
      assert.are.equal(2500, Ledger.receivedBy(l, ONE))
    end)
  end)

  describe("prefill", function()
    it("no stars when nothing was owed", function()
      assert.is_nil(Ledger.prefill(0, 0))
      assert.is_nil(Ledger.prefill(0, 500))
      assert.is_nil(Ledger.prefill(nil, 0))
      assert.is_nil(Ledger.prefill(0 / 0, 0))
      assert.is_nil(Ledger.prefill(math.huge, 0))
      assert.is_nil(Ledger.prefill(-5, 0))
    end)

    it("5 stars when received covers owed", function()
      assert.are.equal(5, Ledger.prefill(25, 25))
      assert.are.equal(5, Ledger.prefill(25, 40))
    end)

    it("1 star when nothing was received", function()
      assert.are.equal(1, Ledger.prefill(25, 0))
    end)

    it("proportional in between, rounded half up and kept within 1 to 5", function()
      assert.are.equal(3, Ledger.prefill(100, 50)) -- 1 + 2 + 0.5 = 3.5
      assert.are.equal(1, Ledger.prefill(100, 10)) -- 1.9
      assert.are.equal(2, Ledger.prefill(100, 25)) -- 2.5
      assert.are.equal(4, Ledger.prefill(100, 75)) -- 4.5
      assert.are.equal(5, Ledger.prefill(100, 99)) -- 5.46
      assert.are.equal(1, Ledger.prefill(1000000, 1)) -- barely anything
    end)

    it("gives no stars for received it cannot trust", function()
      assert.is_nil(Ledger.prefill(100, nil))
      assert.is_nil(Ledger.prefill(100, 0 / 0))
      assert.is_nil(Ledger.prefill(100, -1))
    end)

    it("works from a ledger's own numbers", function()
      Ledger.join(l, ONE, 25, T0)
      agreed(ride(10), 10000, T0 + 10)
      agreed(ride(20), 5000, T0 + 20)
      local owed = Ledger.owed(l, ONE)
      assert.are.equal(3750, owed)
      assert.are.equal(1, Ledger.prefill(owed, Ledger.receivedBy(l, ONE)))
      Ledger.received(l, ONE, 1875)
      assert.are.equal(3, Ledger.prefill(owed, Ledger.receivedBy(l, ONE)))
      Ledger.received(l, ONE, 1875)
      assert.are.equal(5, Ledger.prefill(owed, Ledger.receivedBy(l, ONE)))
    end)
  end)
end)
