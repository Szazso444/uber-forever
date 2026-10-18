-- The Summon Guard panel, the arrival window and the shift-end window
-- (UI/GuardPanel.lua, ArrivalWindow.lua, ShiftEndWindow.lua) on a real Engine
-- over the simulated world and the strict fake frame API. See tests/ui/boot.lua
-- for the players.
local boot = dofile("tests/ui/boot.lua")

describe("summon windows", function()
  local t, ui, w, ns

  local function start(viewer, opts)
    t = boot(viewer, opts)
    ui, w, ns = t.ui, t.w, t.ns
  end

  after_each(function()
    assert.are.same({}, w.errors)
  end)

  describe("the Summon Guard panel", function()
    local GREEN, YELLOW, RED = { 0.2, 0.8, 0.2, 1 }, { 1, 0.8, 0.2, 1 }, { 0.93, 0.2, 0.2, 1 }

    -- Dar's stand, Tra Veler grouped with him and waiting for the summon.
    local function grouped()
      local stand = t.standOf(t.lock)
      return stand, t.groupUp(t.me, stand, 0)
    end

    -- The panel whose title is `title`, or nil.
    local function panel(title)
      local found = ui:find{ kind = "FontString", text = title }
      return found[1] and found[1].parent
    end

    -- The buttons the panel shows, as their texts.
    local function buttonsOf(frame)
      local out = {}
      for _, b in ipairs(ui:find{ kind = "Button", within = frame }) do
        out[#out + 1] = b:GetText()
      end
      return out
    end

    local function borderOf(frame)
      local colors = {}
      for _, edge in ipairs(frame.border.edges) do
        colors[#colors + 1] = edge.rgba
      end
      return colors
    end

    local function allEdges(color)
      return { color, color, color, color }
    end

    describe("with a warlock the traveler knows", function()
      before_each(function() start("me", { trusted = true }) end)

      it("GREEN: a border, a title and a tick for each of the seven checks, and no button at all", function()
        grouped()
        w:offerSummon("Dar Kbolt", "Tra Veler")
        local p = assert(panel("Summon Guard: GREEN - matches your ride"))
        assert.are.same(allEdges(GREEN), borderOf(p))
        for _, line in ipairs({
          "✓ Summoner: Dar Kbolt", "✓ Destination: Tanaris", "✓ Warlock is at the stand", "✓ Nobody in combat",
          "✓ Zone level is fine", "✓ Stand hasn't moved", "✓ Trust rating OK",
        }) do
          assert.is_true(ui:shows(line), line)
        end
        assert.is_false(ui:shows("✗"))
        assert.are.same({}, buttonsOf(p)) -- never an accept button; Decline only on RED
      end)

      it("RED, wrong place: red border, a cross on what is wrong, Decline summon and nothing to accept with", function()
        grouped()
        w:moveTo("Dar Kbolt", "searing") -- his stand closes
        w:advance(1)
        w:offerSummon("Dar Kbolt", "Tra Veler")
        local p = assert(panel("Summon Guard: RED - do not accept"))
        assert.are.same(allEdges(RED), borderOf(p))
        assert.is_true(ui:shows("✓ Summoner: Dar Kbolt"))
        assert.is_true(ui:shows("✗ Destination: Searing Gorge (agreed: Tanaris)"))
        assert.is_true(ui:shows("✗ Warlock is not at the agreed spot"))
        assert.is_true(ui:shows("✗ Stand moved after you requested"))
        assert.are.same({ "Decline summon" }, buttonsOf(p))
        assert.are.same({}, ui:find{ kind = "Button", text = "Accept" })
      end)

      it("Decline summon calls cancelSummon: the popup goes, and so does the panel", function()
        local _, ride = grouped()
        w:moveTo("Dar Kbolt", "searing")
        w:offerSummon("Dar Kbolt", "Tra Veler")
        assert.is_not_nil(t.me.summon)
        ui:press("Decline summon")
        assert.is_true(t.me.summon == nil)
        assert.is_true(t.me.engine.rides[ride.key].summon.declined)
        w:advance(1) -- the popup's end is seen on the next step
        assert.is_nil(panel("Summon Guard: RED - do not accept"))
      end)

      it("RED, a stranger's summon during the ride", function()
        grouped()
        w:addPlayer{ name = "Mal Ory", class = "WARLOCK", level = 45, place = "searing" }
        w:offerSummon("Mal Ory", "Tra Veler")
        local p = assert(panel("Summon Guard: RED - do not accept"))
        assert.is_true(ui:shows("✗ Summoner: Mal Ory (agreed: Dar Kbolt)"))
        assert.are.same({ "Decline summon" }, buttonsOf(p))
      end)

      it("goes when the summon popup does, and when the ride arrives", function()
        grouped()
        w:offerSummon("Dar Kbolt", "Tra Veler")
        assert.is_not_nil(panel("Summon Guard: GREEN - matches your ride"))
        w:fire(t.me, "SUMMON_GONE") -- the popup closes on accepting
        assert.is_nil(panel("Summon Guard: GREEN - matches your ride"))
        w:acceptSummon("Tra Veler")
        -- A verdict that is still up when the landing is seen goes with the ARRIVED.
        t.me.engine:emit("GUARD_VERDICT", { level = "GREEN", checks = { { id = "x", ok = true, level = "RED", text = "fine" } } }, nil)
        assert.is_not_nil(panel("Summon Guard: GREEN - matches your ride"))
        t.me.engine:emit("ARRIVED", {})
        assert.is_nil(panel("Summon Guard: GREEN - matches your ride"))
      end)

      it("replaces one verdict with the next, line for line", function()
        grouped()
        w:offerSummon("Dar Kbolt", "Tra Veler")
        w:advance(1)
        w:moveTo("Dar Kbolt", "searing")
        w:offerSummon("Dar Kbolt", "Tra Veler")
        assert.is_nil(panel("Summon Guard: GREEN - matches your ride"))
        assert.is_not_nil(panel("Summon Guard: RED - do not accept"))
        assert.is_true(ui:shows("✗ Warlock is not at the agreed spot"))
        local before = #ui:texts()
        w:offerSummon("Dar Kbolt", "Tra Veler")
        assert.are.equal(before, #ui:texts()) -- no line left over, none added
      end)

      it("shows in combat: it hangs from UIParent, not from the protected main window", function()
        grouped()
        ui.combat = true
        w:offerSummon("Dar Kbolt", "Tra Veler")
        assert.is_not_nil(panel("Summon Guard: GREEN - matches your ride"))
        ui.combat = false
      end)

      it("sits to the right of Blizzard's summon popup when there is one, else at the top centre", function()
        grouped()
        w:offerSummon("Dar Kbolt", "Tra Veler")
        local p = panel("Summon Guard: GREEN - matches your ride")
        assert.are.same({ "TOP", ui.env.UIParent, "TOP", 0, -24 }, p.points[#p.points])
        w:fire(t.me, "SUMMON_GONE")
        local popup = ui.env.CreateFrame("Frame", "StaticPopup1", ui.env.UIParent)
        ui.popups.CONFIRM_SUMMON = popup
        w:offerSummon("Dar Kbolt", "Tra Veler")
        assert.are.same({ "TOPLEFT", popup, "TOPRIGHT", 8, 0 }, p.points[#p.points])
      end)

      it("finds a popup that opens just after the verdict", function()
        grouped()
        w:offerSummon("Dar Kbolt", "Tra Veler")
        local p = panel("Summon Guard: GREEN - matches your ride")
        local popup = ui.env.CreateFrame("Frame", "StaticPopup1", ui.env.UIParent)
        ui.popups.CONFIRM_SUMMON = popup
        ui:update(0.1)
        assert.are.equal("TOP", p.points[#p.points][1]) -- not yet asked
        ui:update(0.2)
        assert.are.same({ "TOPLEFT", popup, "TOPRIGHT", 8, 0 }, p.points[#p.points])
      end)

      it("shows a name from the wire with its | doubled", function()
        grouped()
        t.me.engine:emit("GUARD_VERDICT", {
          level = "RED",
          checks = { { id = "summoner", ok = false, level = "RED", text = "Summoner: Evil|cffff0000X (agreed: Dar Kbolt)" } },
        }, nil)
        assert.is_true(ui:shows("✗ Summoner: Evil||cffff0000X (agreed: Dar Kbolt)"))
        t.noRawPipes()
      end)

      it("treats a verdict it cannot read as RED, with the way out", function()
        t.me.engine:emit("GUARD_VERDICT", nil, nil)
        local p = assert(panel("Summon Guard: RED - do not accept"))
        assert.are.same({ "Decline summon" }, buttonsOf(p))
        t.me.engine:emit("GUARD_VERDICT", { level = "PURPLE", checks = "junk" }, nil)
        assert.is_not_nil(panel("Summon Guard: RED - do not accept"))
      end)
    end)

    -- R61: the panel does not take the verdict's word for it. It shows the worse of
    -- the verdict's level and its worst failed check, and a verdict that has nothing
    -- to show for itself (no checks, too many) is RED.
    describe("judging a verdict for itself (R61)", function()
      before_each(function() start("me", { trusted = true }) end)

      local function check(ok, level, text)
        return { id = text, ok = ok, level = level, text = text }
      end

      local function emit(level, checks)
        t.me.engine:emit("GUARD_VERDICT", { level = level, checks = checks }, nil)
      end

      -- The texts the panel with this title shows, its title first.
      local function shown(title)
        local p = assert(panel(title), title)
        local out = {}
        for _, fs in ipairs(ui:find{ kind = "FontString", within = p }) do
          out[#out + 1] = fs:GetText()
        end
        return out, p
      end

      it("shows RED, with Decline summon, for a GREEN verdict that has a failed RED check", function()
        emit("GREEN", { check(true, "RED", "Summoner: Dar Kbolt"), check(false, "RED", "Warlock is not at the agreed spot") })
        local _, p = shown("Summon Guard: RED - do not accept")
        assert.are.same(allEdges(RED), borderOf(p))
        assert.are.same({ "Decline summon" }, buttonsOf(p))
        assert.is_nil(panel("Summon Guard: GREEN - matches your ride"))
      end)

      it("shows the worse of the two: YELLOW stays YELLOW, a failed RED check lifts YELLOW to RED, RED stays RED", function()
        emit("YELLOW", { check(true, "RED", "a"), check(false, "YELLOW", "b") })
        assert.is_not_nil(panel("Summon Guard: YELLOW - be careful"))
        emit("YELLOW", { check(true, "RED", "a"), check(false, "RED", "b") })
        assert.is_not_nil(panel("Summon Guard: RED - do not accept"))
        emit("GREEN", { check(false, "YELLOW", "b") })
        assert.is_not_nil(panel("Summon Guard: YELLOW - be careful"))
        emit("RED", { check(true, "YELLOW", "a") })
        assert.is_not_nil(panel("Summon Guard: RED - do not accept"))
      end)

      it("takes a check that is not plainly ok, or whose level it cannot read, as failed and RED", function()
        emit("GREEN", { { id = "x", level = "YELLOW", text = "no ok field" } })
        assert.is_not_nil(panel("Summon Guard: YELLOW - be careful"))
        emit("GREEN", { check(false, "PURPLE", "unknown level") })
        assert.is_not_nil(panel("Summon Guard: RED - do not accept"))
        emit("GREEN", { check(false, nil, "no level") })
        assert.is_not_nil(panel("Summon Guard: RED - do not accept"))
        emit("GREEN", { check(true, "RED", "ok"), "junk" })
        assert.is_not_nil(panel("Summon Guard: RED - do not accept"))
      end)

      it("shows RED for a GREEN verdict with no checks, or none that it can read", function()
        emit("GREEN", {})
        assert.are.same({ "Decline summon" }, buttonsOf(assert(panel("Summon Guard: RED - do not accept"))))
        emit("GREEN", nil)
        assert.is_not_nil(panel("Summon Guard: RED - do not accept"))
        emit("YELLOW", "junk")
        assert.is_not_nil(panel("Summon Guard: RED - do not accept"))
        assert.is_nil(panel("Summon Guard: YELLOW - be careful"))
      end)

      it("shows exactly the lines of the verdict on show: a 7-line verdict, then a 1-line one", function()
        local seven = {}
        for i = 1, 7 do
          seven[i] = check(true, "RED", "line " .. i)
        end
        emit("GREEN", seven)
        assert.are.equal(1 + 7, #shown("Summon Guard: GREEN - matches your ride"))
        emit("GREEN", { check(true, "RED", "only line") })
        local texts = shown("Summon Guard: GREEN - matches your ride")
        assert.are.same({ "Summon Guard: GREEN - matches your ride", "✓ only line" }, texts)
        assert.is_false(ui:shows("line 7"))
      end)

      it("shows RED when there are more checks than lines, ending in '... more checks failed' if a hidden one failed", function()
        local many = {}
        for i = 1, 12 do
          many[i] = check(true, "RED", "line " .. i)
        end
        emit("GREEN", many) -- more than it can show, every one ok: RED all the same
        local texts = shown("Summon Guard: RED - do not accept")
        assert.are.equal(1 + 8, #texts)
        assert.is_false(ui:shows("more checks failed"))
        assert.is_true(ui:shows("✓ line 8"))
        assert.is_false(ui:shows("line 9"))
        many[11] = check(false, "RED", "line 11")
        emit("GREEN", many)
        texts = shown("Summon Guard: RED - do not accept")
        assert.are.equal(1 + 9, #texts)
        assert.are.equal("… more checks failed", texts[#texts])
        assert.is_false(ui:shows("line 11"))
      end)
    end)

    describe("with a warlock nobody has rated", function()
      before_each(function() start("me") end)

      it("YELLOW: a yellow border, the one warning in yellow, and still nothing to accept with", function()
        grouped()
        w:offerSummon("Dar Kbolt", "Tra Veler")
        local p = assert(panel("Summon Guard: YELLOW - be careful"))
        assert.are.same(allEdges(YELLOW), borderOf(p))
        assert.is_true(ui:shows("✗ Low or new Trust rating"))
        assert.is_true(ui:shows("✓ Summoner: Dar Kbolt"))
        local warning = ui:one{ kind = "FontString", text = "✗ Low or new Trust rating" }
        assert.are.same(ns.UI.GuardPanel.COLORS.YELLOW, warning.color)
        assert.are.same(ns.UI.GuardPanel.COLORS.GREEN, ui:one{ kind = "FontString", text = "✓ Summoner: Dar Kbolt" }.color)
        assert.are.same({}, buttonsOf(p))
      end)

      it("YELLOW: a summon that is no Taxi ride", function()
        t.standOf(t.lock)
        w:offerSummon("Dar Kbolt", "Tra Veler")
        local p = assert(panel("Summon Guard: YELLOW - be careful"))
        assert.is_true(ui:shows("✗ Not a Taxi ride: Dar Kbolt → Tanaris"))
        assert.are.same({}, buttonsOf(p))
      end)
    end)
  end)

  describe("the arrival window", function()
    before_each(function() start("me", { trusted = true }) end)

    -- Tra Veler rides from Dar's stand (asking with `offer`) and lands where he should.
    local function arrive(offer)
      local stand = t.standOf(t.lock)
      local ride = t.groupUp(t.me, stand, offer)
      w:offerSummon("Dar Kbolt", "Tra Veler")
      w:fire(t.me, "SUMMON_GONE")
      w:acceptSummon("Tra Veler")
      w:advance(1)
      assert.are.equal("arrived", ride.state)
      return ride
    end

    local function window()
      for _, f in ipairs(ui.frames) do
        if f.TitleText and f.TitleText:GetText() == "You arrived" and ui:visible(f) then
          return f
        end
      end
      return nil
    end

    local function star(n)
      ui:click(window().stars.buttons[n])
    end

    -- The ratings Tra Veler has sent (the summary's count has the ride's receipt in it already).
    local function ratingsSent()
      w:advance(2)
      return #t.wireOf("RATING", "Tra Veler")
    end

    it("opens when the ride arrives, with the driver, the stars and the tip picker", function()
      arrive(10000)
      assert.is_not_nil(window())
      assert.is_true(ui:shows("Summon from Dar Kbolt"))
      assert.is_true(ui:shows("Rate Dar Kbolt (Trust):"))
      assert.is_true(ui:shows("Tip:"))
      assert.is_true(ui:visible(window().stars))
      assert.is_true(ui:visible(ui:one{ kind = "Button", text = "Stay and click" }))
      assert.is_true(ui:visible(ui:one{ kind = "Button", text = "Leave group" }))
      assert.is_false(ui:shows("⚠")) -- landed at the stand
    end)

    it("starts with the tip that was offered picked: 1g, 50s or a custom amount, else none", function()
      arrive(10000)
      assert.are.same({ true, true, false, true }, {
        ui:one{ kind = "Button", text = "No tip" }.enabled, ui:one{ kind = "Button", text = "50s" }.enabled,
        ui:one{ kind = "Button", text = "1g" }.enabled, ui:one{ kind = "Button", text = "Custom" }.enabled })
      assert.is_true(ui:one{ kind = "Button", text = "Open trade with Dar Kbolt" }.enabled)
      start("me", { trusted = true })
      arrive(5000)
      assert.is_false(ui:one{ kind = "Button", text = "50s" }.enabled)
      start("me", { trusted = true })
      arrive(25000)
      assert.is_false(ui:one{ kind = "Button", text = "Custom" }.enabled)
      assert.are.same({ "2", "50" }, { window().picker.custom.gold:GetText(), window().picker.custom.silver:GetText() })
      start("me", { trusted = true })
      arrive(0)
      assert.is_false(ui:one{ kind = "Button", text = "No tip" }.enabled)
      assert.is_false(ui:one{ kind = "Button", text = "Send rating" }.enabled) -- no tip, no stars: nothing to send
    end)

    it("rates and opens the trade in one click; the game cannot fill in the money, so it says what to put in", function()
      local ride = arrive(10000)
      t.me.game.trySetTradeMoney = function(game, copper) -- as Forever: the money cannot be set
        game.p.tradeMoney = copper
        return false
      end
      assert.are.equal(0, ratingsSent())
      star(5)
      ui:press("Open trade with Dar Kbolt")
      assert.are.same({ "Dar Kbolt", 10000 }, { t.me.tradeWith, t.me.tradeMoney })
      assert.is_true(ui:shows("Put 1g in the trade"))
      assert.is_true(ui:shows("Rating sent."))
      assert.are.equal(1, ratingsSent())
      local sent = t.wireOf("RATING", "Tra Veler")
      assert.are.same({ "trust", "Dar Kbolt", 5, ride.rideId }, { sent[1].kind, sent[1].target, sent[1].stars, sent[1].id })
    end)

    describe("the Put button (R64)", function()
      -- As Forever: the money can't be confirmed, so the window keeps its hint.
      local function forever()
        t.me.game.trySetTradeMoney = function(game, copper)
          game.p.tradeMoney = copper
          game.setCalls = (game.setCalls or 0) + 1
          return false
        end
      end

      local function put(text)
        return ui:one{ kind = "Button", text = text or "Put 1g in the trade" }
      end

      it("is there once Open trade was pressed, not before", function()
        forever()
        arrive(10000)
        assert.are.equal(0, #ui:find{ kind = "Button", text = "Put 1g in the trade" })
        ui:press("Open trade with Dar Kbolt")
        assert.is_true(ui:visible(put()))
        assert.is_true(ui:shows("Put 1g in the trade")) -- and the hint, as before
      end)

      it("is disabled with no trade open and enabled while the trade with the driver is open", function()
        forever()
        arrive(10000)
        ui:press("Open trade with Dar Kbolt") -- the simulated game has the window open at once
        local button = put()
        assert.is_true(button.enabled)
        t.me.tradeWith = nil -- the window closed
        ui:update(1)
        assert.is_false(button.enabled)
        t.me.tradeWith = "Cee One" -- a trade, but not with the driver
        ui:update(1)
        assert.is_false(button.enabled)
        t.me.tradeWith = "Dar Kbolt"
        ui:update(1)
        assert.is_true(button.enabled)
      end)

      it("calls trySetTradeMoney with the tip picked now, and keeps the hint", function()
        forever()
        arrive(10000)
        ui:press("Open trade with Dar Kbolt")
        t.me.game.setCalls = 0
        ui:click(put())
        assert.are.same({ 1, 10000 }, { t.me.game.setCalls, t.me.tradeMoney })
        ui:press("50s") -- another amount picked: the button and the hint follow it
        assert.is_false(ui:shows("Put 1g in the trade"))
        ui:click(put("Put 50s in the trade"))
        assert.are.same({ 2, 5000 }, { t.me.game.setCalls, t.me.tradeMoney })
        assert.is_true(ui:shows("Put 50s in the trade"))
        assert.is_false(ui:shows("is in the trade"))
      end)

      it("refuses a click that has no trade open or no tip, and says why", function()
        forever()
        arrive(10000)
        ui:press("Open trade with Dar Kbolt")
        local button = put()
        t.me.tradeWith = nil
        t.me.game.setCalls = 0
        button.scripts.OnClick(button) -- a click that got through before the poll disabled it
        assert.are.equal(0, t.me.game.setCalls)
        assert.is_true(ui:shows("No trade window with that player is open."))
      end)

      it("is not offered when the game could put the money in itself", function()
        arrive(10000)
        ui:press("Open trade with Dar Kbolt")
        assert.is_true(ui:shows("1g is in the trade. Check it and accept."))
        assert.are.equal(0, #ui:find{ kind = "Button", text = "Put 1g in the trade" })
      end)
    end)

    it("says the money is in the trade when the game could put it there", function()
      arrive(10000)
      ui:press("Open trade with Dar Kbolt")
      assert.is_true(ui:shows("1g is in the trade. Check it and accept."))
      assert.is_false(ui:shows("Put 1g"))
    end)

    it("sends one rating only, however often the trade is opened again", function()
      arrive(10000)
      star(4)
      ui:press("Open trade with Dar Kbolt")
      assert.is_false(window().stars.pickable)
      ui:press("50s")
      ui:press("Open trade with Dar Kbolt")
      assert.are.equal(5000, t.me.tradeMoney)
      assert.are.equal(1, ratingsSent())
    end)

    it("sends just the rating when no tip is picked", function()
      arrive(0)
      local rate = ui:one{ kind = "Button", text = "Send rating" }
      assert.is_false(rate.enabled) -- nothing to send yet
      star(3)
      assert.is_true(rate.enabled)
      ui:click(rate)
      assert.is_nil(t.me.tradeWith)
      assert.are.equal(1, ratingsSent())
      assert.is_false(rate.enabled)
    end)

    it("opens the trade for a preset or a custom amount without any rating", function()
      arrive(0)
      ui:press("50s")
      ui:press("Open trade with Dar Kbolt")
      assert.are.same({ "Dar Kbolt", 5000 }, { t.me.tradeWith, t.me.tradeMoney })
      ui:press("Custom")
      window().picker.custom.gold:SetText("2")
      window().picker.custom.silver:SetText("50")
      ui:press("Open trade with Dar Kbolt")
      assert.are.equal(25000, t.me.tradeMoney)
      assert.are.equal(0, ratingsSent()) -- no stars were picked: nothing rated
    end)

    it("will not open a trade for a custom amount that is empty, or more gold than the player has", function()
      arrive(0)
      ui:press("Custom")
      ui:press("Open trade with Dar Kbolt")
      assert.is_true(ui:shows("That is not a valid tip."))
      assert.is_nil(t.me.tradeWith)
      window().picker.custom.gold:SetText("99")
      star(5)
      ui:press("Open trade with Dar Kbolt")
      assert.is_true(ui:shows("You don't have that much gold."))
      assert.is_nil(t.me.tradeWith)
      assert.are.equal(0, ratingsSent()) -- the rating waits for a tip that can be paid
      assert.is_true(window().stars.pickable)
    end)

    it("Stay and click signs up to the same stand at the share it offers", function()
      local ride = arrive(0)
      ui:press("Stay and click")
      assert.are.same({ ride.standId, 25 }, { t.me.engine.application.standId, t.me.engine.application.askedPct })
      assert.is_true(ui:shows("Applied to click for Dar Kbolt."))
      assert.is_false(ui:one{ kind = "Button", text = "Stay and click" }.enabled)
    end)

    it("Leave group leaves it, and the window stays for the rating", function()
      arrive(0)
      assert.are.equal(2, t.me.game:groupSize())
      ui:press("Leave group")
      w:advance(1)
      assert.are.equal(0, t.me.game:groupSize())
      assert.is_true(ui:shows("You left the group."))
      assert.is_false(ui:one{ kind = "Button", text = "Leave group" }.enabled)
      assert.is_not_nil(window())
    end)

    it("warns when the summon landed away from the agreed spot", function()
      local stand = t.standOf(t.lock)
      t.groupUp(t.me, stand, 0)
      w:moveTo("Dar Kbolt", "searing")
      w:offerSummon("Dar Kbolt", "Tra Veler")
      w:fire(t.me, "SUMMON_GONE")
      w:acceptSummon("Tra Veler")
      assert.is_true(ui:shows("⚠ You landed away from the agreed spot."))
    end)

    it("turns everything off for a dead Hardcore character", function()
      arrive(10000)
      t.me.dead = true
      t.me.engine:emit("ARRIVED", t.me.engine.rides["Tra Veler#" .. t.lock.engine.stand.standId])
      assert.is_true(ui:shows("Your Hardcore character has died."))
      assert.is_false(ui:one{ kind = "Button", text = "Open trade with Dar Kbolt" }.enabled)
      assert.is_false(ui:one{ kind = "Button", text = "Stay and click" }.enabled)
      assert.is_false(ui:one{ kind = "Button", text = "Leave group" }.enabled)
    end)

    it("shows a driver's name from the wire with its | doubled", function()
      arrive(0)
      t.me.engine:emit("ARRIVED", {
        kind = "summon", driver = "Evil|cffff0000X", rideId = "x", offer = 0, state = "arrived",
      })
      assert.is_true(ui:shows("Summon from Evil||cffff0000X"))
      t.noRawPipes()
    end)

    it("is for a portal ride without stars, Stay and click or a rating", function()
      local stand = t.standOf(t.mage, { kind = "mage" })
      local ride = t.groupUp(t.me, stand, 5000, t.mage, "ironforge")
      w:moveTo("Tra Veler", "gadgetzan") -- to the mage
      assert.are.equal("Tra Veler", t.mage.engine:nextTraveler()) -- Open portal: the group is told
      w:advance(1)
      assert.is_true(w:castPortal("Mag Ic", "ironforge"))
      assert.is_true(w:usePortal("Tra Veler", "ironforge"))
      w:advance(1)
      assert.are.equal("arrived", ride.state)
      assert.is_true(ui:shows("Portal to Ironforge from Mag Ic"))
      assert.is_false(ui:visible(window().stars))
      assert.is_false(ui:shows("Rate"))
      assert.are.same({}, ui:find{ kind = "Button", text = "Stay and click" })
      assert.is_false(ui:one{ kind = "Button", text = "50s" }.enabled) -- the offer is picked
      ui:press("Open trade with Mag Ic")
      assert.are.same({ "Mag Ic", 5000 }, { t.me.tradeWith, t.me.tradeMoney })
      assert.are.equal(0, ratingsSent()) -- portals are never rated
      ui:press("Leave group")
      w:advance(1)
      assert.are.equal(0, t.me.game:groupSize())
    end)
  end)

  describe("the shift-end window", function()
    before_each(function() start("c1", { trusted = true }) end)

    -- Cee One and Cee Two on Dar's crew; Tra Veler rides, arrives and tips 1g
    -- (Cee One's share is 25s). Returns the stand.
    local function shiftWithTip()
      local stand = t.standOf(t.lock, { kind = "lock", seats = 3, clickerPct = 25 })
      assert(t.c1.engine:applyClicker(stand.standId, 25))
      assert(t.c2.engine:applyClicker(stand.standId, 25))
      w:advance(2)
      assert(t.lock.engine:respondClicker("Cee One", "ACCEPT"))
      assert(t.lock.engine:respondClicker("Cee Two", "ACCEPT"))
      w:advance(2)
      w:acceptInvite("Cee One")
      w:acceptInvite("Cee Two")
      w:advance(2)
      local ride = t.groupUp(t.me, stand, 10000)
      t.lock.engine:nextTraveler()
      w:offerSummon("Dar Kbolt", "Tra Veler")
      w:fire(t.me, "SUMMON_GONE")
      w:acceptSummon("Tra Veler")
      w:advance(2)
      assert(t.me.engine:submitArrival(ride.rideId, 5, 10000))
      assert.is_true(w:trade("Tra Veler", "Dar Kbolt", 10000))
      w:advance(3)
      return stand
    end

    local function window()
      for _, f in ipairs(ui.frames) do
        if f.TitleText and f.TitleText:GetText() == "Shift ended" and ui:visible(f) then
          return f
        end
      end
      return nil
    end

    it("shows owed against received, with the Share stars filled in from what was paid", function()
      shiftWithTip()
      assert.is_nil(window())
      t.c1.engine:leaveStand()
      assert.is_not_nil(window())
      assert.is_true(ui:shows("Clicked for Dar Kbolt at 25% of the tips"))
      assert.is_true(ui:shows("Owed 25s · Received 0c"))
      assert.is_true(ui:shows("Rate Dar Kbolt (Share):"))
      assert.are.equal(1, window().stars:GetValue()) -- nothing paid: 1 star
      assert.is_true(ui:shows("Suggested from what you were paid."))
    end)

    it("fills in 5 stars and a tick when the warlock paid in full", function()
      shiftWithTip()
      assert.is_true(w:trade("Dar Kbolt", "Cee One", 2500))
      w:advance(1)
      t.c1.engine:leaveStand()
      assert.is_true(ui:shows("Owed 25s · Received 25s ✓"))
      assert.are.equal(5, window().stars:GetValue())
    end)

    it("leaves the stars empty when nothing was owed, and asks for a rating before it sends one", function()
      local stand = t.standOf(t.lock)
      assert(t.c1.engine:applyClicker(stand.standId, 25))
      w:advance(2)
      assert(t.lock.engine:respondClicker("Cee One", "ACCEPT"))
      w:advance(2)
      w:acceptInvite("Cee One")
      w:advance(1)
      t.c1.engine:leaveStand()
      assert.is_true(ui:shows("Owed 0c · Received 0c"))
      assert.are.equal(0, window().stars:GetValue())
      assert.is_true(ui:shows("Nothing was owed, so rating is optional."))
      ui:press("Submit")
      assert.is_true(ui:shows("Pick a star rating first."))
      assert.is_true(ui:visible(window()))
      ui:click(window().stars.buttons[4])
      ui:press("Submit")
      assert.is_nil(window())
      w:advance(2)
      local sent = t.wireOf("RATING", "Cee One")
      assert.are.same({ "share", "Dar Kbolt", 4 }, { sent[1].kind, sent[1].target, sent[1].stars })
    end)

    it("submits the stars shown, or the ones the clicker picked, with the shift as proof", function()
      shiftWithTip()
      t.c1.engine:leaveStand()
      ui:click(window().stars.buttons[3])
      ui:press("Submit")
      assert.is_nil(window())
      w:advance(2)
      local sent = t.wireOf("RATING", "Cee One")
      assert.are.same({ "share", 3, 2500, 0, 25 }, { sent[1].kind, sent[1].stars, sent[1].owed, sent[1].received, sent[1].pct })
      assert.are.equal(3, t.lock.engine:summary("Dar Kbolt", "share").stars)
    end)

    it("follows a payout that comes after the shift, keeping stars the clicker chose", function()
      shiftWithTip()
      t.c1.engine:leaveStand()
      assert.are.equal(1, window().stars:GetValue())
      assert.is_true(w:trade("Dar Kbolt", "Cee One", 2500)) -- paid after all
      w:advance(1)
      assert.is_true(ui:shows("Owed 25s · Received 25s ✓"))
      assert.are.equal(5, window().stars:GetValue()) -- the suggestion follows
      ui:click(window().stars.buttons[2])
      t.c1.engine:emit("SHIFT_ENDED", t.c1.engine.lastShift)
      assert.are.equal(2, window().stars:GetValue()) -- their own pick stays
    end)

    it("does not ask again for a shift already rated", function()
      shiftWithTip()
      t.c1.engine:leaveStand()
      ui:click(window().stars.buttons[5])
      ui:press("Submit")
      assert.is_nil(window())
      t.c1.engine:emit("SHIFT_ENDED", t.c1.engine.lastShift)
      assert.is_nil(window())
    end)

    it("Close leaves the rating unsent", function()
      shiftWithTip()
      t.c1.engine:leaveStand()
      ui:press("Close")
      assert.is_nil(window())
      w:advance(2)
      assert.are.same({}, t.wireOf("RATING", "Cee One"))
    end)

    it("lists a tip the traveler and the warlock disagree about, and how many more", function()
      local stand = t.standOf(t.lock)
      assert(t.c1.engine:applyClicker(stand.standId, 25))
      w:advance(2)
      assert(t.lock.engine:respondClicker("Cee One", "ACCEPT"))
      w:advance(2)
      w:acceptInvite("Cee One")
      w:advance(1)
      local ride = "Dar Kbolt@Tra Veler@" .. math.floor(w.clock:now())
      t.hear(t.c1, "Tra Veler", "RIDE_START", { rideId = ride, warlock = "Dar Kbolt" }, "CHANNEL")
      t.hear(t.c1, "Tra Veler", "ARRIVED", { rideId = ride, warlock = "Dar Kbolt" }, "CHANNEL")
      t.hear(t.c1, "Tra Veler", "TIP", { rideId = ride, amount = 10000 }, "PARTY")
      t.hear(t.c1, "Dar Kbolt", "TIP_ACK", { rideId = ride, amount = 5000 }, "PARTY")
      t.c1.engine:leaveStand()
      assert.is_true(ui:shows("Disputed: traveler said 1g, warlock said 50s"))
      assert.is_true(ui:shows("Owed 0c · Received 0c")) -- a disputed tip is not owed
      -- More than three are cut short.
      local summary = {}
      for k, v in pairs(t.c1.engine.lastShift) do summary[k] = v end
      summary.shiftId = "another"
      summary.disputed = {}
      for i = 1, 5 do
        summary.disputed[i] = { rideId = "r" .. i, tip = i * 100, ack = i * 100 + 50 }
      end
      t.c1.engine:emit("SHIFT_ENDED", summary)
      assert.is_true(ui:shows("Disputed: traveler said 1s, warlock said 1s 50c"))
      assert.is_true(ui:shows("and 2 more disputed"))
      assert.is_false(ui:shows("Disputed: traveler said 4s"))
    end)

    it("turns Submit off for a dead Hardcore character", function()
      shiftWithTip()
      t.c1.dead = true
      t.c1.engine:emit("SHIFT_ENDED", { shiftId = "s", owner = "Dar Kbolt", pct = 25, owed = 0, received = 0, disputed = {} })
      assert.is_false(ui:one{ kind = "Button", text = "Submit" }.enabled)
    end)

    it("shows the owner's name from the wire with its | doubled", function()
      t.c1.engine:emit("SHIFT_ENDED", { shiftId = "s", owner = "Evil|cffff0000X", pct = 25, owed = 0, received = 0, disputed = {} })
      assert.is_true(ui:shows("Clicked for Evil||cffff0000X at 25% of the tips"))
      t.noRawPipes()
    end)
  end)
end)
