describe("Negotiation", function()
  local ns, N

  before_each(function()
    ns = Taxi.load()
    N = ns.Negotiation
  end)

  local function neg(askedPct)
    return N.new{standId="s1", owner="Dar Kbolt", clicker="C One", offeredPct=25, askedPct=askedPct or 25}
  end

  -- A copy of the negotiation's fields, to prove a failed apply changed nothing.
  local function snapshot(n)
    local out = {}
    for k, v in pairs(n) do out[k] = v end
    return out
  end

  describe("new", function()
    it("starts asked at the asked share", function()
      local n = N.new{standId="s1", owner="Dar Kbolt", clicker="C One", offeredPct=25, askedPct=30}
      assert.are.equal("asked", n.state)
      assert.are.equal(30, n.pct)
      assert.are.equal("s1", n.standId)
      assert.are.equal("Dar Kbolt", n.owner)
      assert.are.equal("C One", n.clicker)
      assert.are.equal(25, n.offeredPct)
      assert.are.equal(30, n.askedPct)
    end)
  end)

  describe("validPct", function()
    it("accepts a whole number from 1 up to what is available", function()
      assert.is_true(N.validPct(1, 50))
      assert.is_true(N.validPct(25, 50))
      assert.is_true(N.validPct(50, 50))
      assert.is_true(N.validPct(99, 100))
    end)

    it("rejects a share bigger than what is available as over_share", function()
      assert.are.same({nil, "over_share"}, {N.validPct(51, 50)})
      assert.are.same({nil, "over_share"}, {N.validPct(1, 0)})
    end)

    it("rejects anything that is not a whole number from 1 to 99 as bad_pct", function()
      for _, bad in ipairs{0, -5, 100, 150, 1.5, 24.9, "25", true, {}, 0 / 0, math.huge, -math.huge} do
        assert.are.same({nil, "bad_pct"}, {N.validPct(bad, 100)})
      end
      assert.are.same({nil, "bad_pct"}, {N.validPct(nil, 100)})
    end)

    it("calls a bad share bad_pct before over_share", function()
      assert.are.same({nil, "bad_pct"}, {N.validPct(100, 50)})
      assert.are.same({nil, "bad_pct"}, {N.validPct(0.5, 0)})
    end)

    it("agrees with Stand.addClicker about what a share is", function()
      -- One clicker already seated at 30%, so the owner has 70% left.
      for _, pct in ipairs{1, 25, 70, 71, 99, 0, 100, 1.5, "25", true, 0 / 0, math.huge, -math.huge} do
        local s = ns.Stand.new{standId="s1", owner="Dar Kbolt", kind="lock", now=0}
        ns.Stand.addClicker(s, "C One", 30, 1)
        local ok, why = N.validPct(pct, ns.Stand.ownerPct(s))
        local standOk, standWhy = ns.Stand.addClicker(s, "C Two", pct, 1)
        assert.are.equal(standOk, ok)
        assert.are.equal(standWhy, why)
      end
    end)
  end)

  describe("apply", function()
    it("accept asked", function()
      local n = neg(25)
      assert.is_true(N.apply(n, "ACCEPT", nil, 50))
      assert.are.equal("agreed", n.state)
      assert.are.equal(25, n.pct)
    end)

    it("accepts a share equal to what the owner has left", function()
      local n = neg(50)
      assert.is_true(N.apply(n, "ACCEPT", nil, 50))
      assert.are.equal("agreed", n.state)
      assert.are.equal(50, n.pct)
    end)

    it("over share", function()
      local n = neg(60)
      assert.are.same({nil, "over_share"}, {N.apply(n, "ACCEPT", nil, 50)})
      assert.are.equal("asked", n.state)
      assert.are.equal(60, n.pct)
    end)

    it("will not agree to a share that is not a whole number from 1 to 99", function()
      for _, bad in ipairs{0, 100, 12.5, "25", 0 / 0, math.huge} do
        local n = neg(bad)
        assert.are.same({nil, "bad_pct"}, {N.apply(n, "ACCEPT", nil, 100)})
        assert.are.equal("asked", n.state)
        assert.is_true(n.pct == bad or (bad ~= bad and n.pct ~= n.pct))
      end
    end)

    it("counter then accept", function()
      local n = neg(40)
      assert.is_true(N.apply(n, "COUNTER", 20, 50))
      assert.are.equal("countered", n.state)
      assert.are.equal(20, n.pct)
      assert.is_true(N.apply(n, "CLICKER_ACCEPT", nil, 50))
      assert.are.equal("agreed", n.state)
      assert.are.equal(20, n.pct)
    end)

    it("keeps what the clicker first asked after a counter", function()
      local n = neg(40)
      N.apply(n, "COUNTER", 20, 50)
      assert.are.equal(40, n.askedPct)
      assert.are.equal(25, n.offeredPct)
    end)

    it("rejects a counter over the available share and stays asked", function()
      local n = neg(40)
      assert.are.same({nil, "over_share"}, {N.apply(n, "COUNTER", 60, 50)})
      assert.are.equal("asked", n.state)
      assert.are.equal(40, n.pct)
    end)

    it("rejects a counter that is not a whole number from 1 to 99 and stays asked", function()
      for _, bad in ipairs{0, 100, 12.5, "20", true, 0 / 0, math.huge} do
        local n = neg(40)
        assert.are.same({nil, "bad_pct"}, {N.apply(n, "COUNTER", bad, 50)})
        assert.are.equal("asked", n.state)
        assert.are.equal(40, n.pct)
      end
      local n = neg(40)
      assert.are.same({nil, "bad_pct"}, {N.apply(n, "COUNTER", nil, 50)})
      assert.are.equal("asked", n.state)
      assert.are.equal(40, n.pct)
    end)

    it("rechecks the share when the clicker accepts a counter", function()
      local n = neg(40)
      N.apply(n, "COUNTER", 30, 50)
      -- Another clicker agreed meanwhile and the owner has only 20% left.
      assert.are.same({nil, "over_share"}, {N.apply(n, "CLICKER_ACCEPT", nil, 20)})
      assert.are.equal("countered", n.state)
      assert.are.equal(30, n.pct)
    end)

    it("bad state", function()
      local n = neg(25)
      assert.are.same({nil, "bad_state"}, {N.apply(n, "CLICKER_ACCEPT", nil, 50)})
      assert.are.equal("asked", n.state)
      assert.are.equal(25, n.pct)
    end)

    it("lets the owner accept or counter only a request, and the clicker accept only a counter", function()
      local n = neg(25)
      N.apply(n, "COUNTER", 20, 50)
      assert.are.same({nil, "bad_state"}, {N.apply(n, "ACCEPT", nil, 50)})
      assert.are.same({nil, "bad_state"}, {N.apply(n, "COUNTER", 10, 50)})
      assert.are.equal("countered", n.state)
      assert.are.equal(20, n.pct)
    end)

    it("decline", function()
      local n = neg(25)
      assert.is_true(N.apply(n, "DECLINE", nil, 50))
      assert.are.equal("declined", n.state)
      assert.are.equal(25, n.pct)
    end)

    it("declines from countered", function()
      local n = neg(40)
      N.apply(n, "COUNTER", 20, 50)
      assert.is_true(N.apply(n, "DECLINE", nil, 50))
      assert.are.equal("declined", n.state)
      assert.are.equal(20, n.pct)
    end)

    it("declines even when the share no longer fits", function()
      local n = neg(60)
      assert.is_true(N.apply(n, "DECLINE", nil, 10))
      assert.are.equal("declined", n.state)
    end)

    it("is over once agreed: every event is bad_state", function()
      for _, event in ipairs{"ACCEPT", "COUNTER", "CLICKER_ACCEPT", "DECLINE"} do
        local n = neg(25)
        N.apply(n, "ACCEPT", nil, 50)
        local before = snapshot(n)
        assert.are.same({nil, "bad_state"}, {N.apply(n, event, 10, 50)})
        assert.are.same(before, n)
        assert.are.equal("agreed", n.state)
        assert.are.equal(25, n.pct)
      end
    end)

    it("is over once declined: every event is bad_state", function()
      for _, event in ipairs{"ACCEPT", "COUNTER", "CLICKER_ACCEPT", "DECLINE"} do
        local n = neg(25)
        N.apply(n, "DECLINE", nil, 50)
        local before = snapshot(n)
        assert.are.same({nil, "bad_state"}, {N.apply(n, event, 10, 50)})
        assert.are.same(before, n)
        assert.are.equal("declined", n.state)
        assert.are.equal(25, n.pct)
      end
    end)

    it("calls an unknown event bad_state", function()
      local n = neg(25)
      local before = snapshot(n)
      assert.are.same({nil, "bad_state"}, {N.apply(n, "SHRUG", nil, 50)})
      assert.are.same({nil, "bad_state"}, {N.apply(n, nil, nil, 50)})
      assert.are.same(before, n)
    end)

    it("leaves the negotiation completely unchanged when it fails", function()
      local cases = {
        {"ACCEPT", nil, 10},         -- over_share
        {"COUNTER", 60, 50},         -- over_share
        {"COUNTER", 0, 50},          -- bad_pct
        {"CLICKER_ACCEPT", nil, 50}, -- bad_state
      }
      for _, c in ipairs(cases) do
        local n = neg(25)
        local before = snapshot(n)
        assert.is_nil((N.apply(n, c[1], c[2], c[3])))
        assert.are.same(before, n)
      end
    end)
  end)
end)
