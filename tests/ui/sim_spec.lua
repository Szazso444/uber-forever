-- /taxi sim (UI/SimControls.lua): the made-up world the real window is driven
-- through when played alone. The "real" player is Tra Veler in the specs'
-- own world; the sim builds a second world of its own inside the same
-- namespace, as it does in game, and binds the UI to its player "You".
local boot = dofile("tests/ui/boot.lua")

describe("/taxi sim", function()
  local t, ui, w, ns, Main, Sim, realBefore

  local function start(viewer, opts)
    t = boot(viewer or "me", opts)
    ui, w, ns, Main, Sim = t.ui, t.w, t.ns, t.Main, t.ns.UI.Sim
    realBefore = #w.bus:sent()
  end

  -- Screen time passes: the sim's clock runs on it, a second at a time at most.
  local function pass(seconds)
    local left = seconds
    while left > 0 do
      local dt = math.min(left, 1)
      ui:update(dt)
      left = left - dt
    end
  end

  -- The window whose title is `title`, if it is up.
  local function window(title)
    for _, f in ipairs(ui.frames) do
      if f.TitleText and f.TitleText:GetText() == title and ui:visible(f) then
        return f
      end
    end
    return nil
  end

  local function row(n)
    return Main.views.travel.list.rows[n]
  end

  -- Request on Dar Kbolt's row with a 1g offer, answered as Dar Kbolt (his toast), You joined to his group.
  local function groupedWithDar()
    ui:click(row(1).buttons[1])
    ui:press("1g")
    ui:press("Send")
    pass(2)
    ui:press("Accept", window("Dar Kbolt (sim) - Ride request"))
    pass(2)
    ui:press("Accept invite")
  end

  after_each(function()
    assert.are.same({}, w.errors)
    if Sim.active() then
      Sim.stop()
    end
  end)

  describe("starting", function()
    before_each(function()
      start()
      Sim.start()
    end)

    it("binds the UI to You, opens the Travel tab and the Sim controls", function()
      assert.is_true(Sim.active())
      assert.are.equal("You", ns.engine.me)
      assert.are_not.equal(t.me.engine, ns.engine)
      assert.is_true(Main:IsShown())
      assert.is_true(ui:visible(window("Sim controls")))
      for _, label in ipairs({
        "Accept invite", "Offer summon (green)", "Offer summon (wrong place)", "Offer stranger summon",
        "Accept summon", "Mage opens portal", "Step through portal", "Clicker applies", "Kill traveler",
        "Trade tip", "End shift", "Advance 60 s", "Stop sim",
      }) do
        assert.is_true(ui:visible(ui:one{ kind = "Button", text = label }), label)
      end
      assert.is_true(ui:shows("Press Request on Dar Kbolt"))
    end)

    it("lists the stands: the guildmate's first and green, with the star and count format", function()
      assert.are.equal("Dar Kbolt", row(1).title:GetText())
      assert.are.same(ns.UI.Widgets.COLOR.green, row(1).title.color)
      assert.are.equal("★ 4.7 · 6 summons", row(1).sub2:GetText())
      assert.are.equal("Tanaris - Gadgetzan", row(1).sub:GetText())
      assert.is_true(row(1).buttons[1].enabled)
      assert.are.equal("Ann Other", row(2).title:GetText())
      assert.are.equal("★ 1.5 · 4 summons · New", row(2).sub2:GetText()) -- 3 four-star ratings and a death weigh in
      assert.are.equal("⚠ 1 reported death", row(2).warn:GetText())
      assert.are.equal("Paused", row(2).right:GetText()) -- her crew left her (R69)
      assert.is_false(row(2).buttons[1].enabled)
      ui:press("Portals")
      assert.are.equal("Mag Ic", row(1).title:GetText())
      assert.are.equal("Portals: Stormwind, Ironforge, Darnassus", row(1).sub2:GetText())
    end)

    it("lists the stands that need clickers on the Clicking tab: Ann's, not Dar's live one", function()
      ui:press("Clicking")
      local rows = Main.views.clicking.list.rows
      assert.are.equal("Ann Other", rows[1].title:GetText())
      assert.are.equal("Searing Gorge - Thorium Point · Needs 2 clickers", rows[1].sub:GetText())
      assert.is_false(ui:visible(rows[2])) -- the only one
    end)

    it("says what stays real: death reports still go out, the rest of the real addon is paused (R62)", function()
      local line = ui.prints[1]
      assert.are.equal("Taxi: " .. ns.L.SIM_STARTED, line)
      assert.truthy(line:find("Real death reports still go out; everything else from the real addon is paused until /taxi sim off.", 1, true))
      assert.is_nil(line:find("Don't play Hardcore", 1, true))
    end)

    it("says it is running when started again, and builds no second world", function()
      local world = Sim.state.world
      ui.prints = {}
      Sim.start()
      assert.are.same({ "Taxi: The sim is already running. /taxi sim off ends it." }, ui.prints)
      assert.are.equal(world, Sim.state.world)
    end)

    it("moves the sim's clock with the screen's, and Advance 60 s moves it a minute", function()
      local clock = Sim.state.world.clock
      local t0 = clock:now()
      pass(2)
      assert.is_true(math.abs(clock:now() - (t0 + 2)) < 1e-6)
      ui:press("Advance 60 s")
      assert.is_true(math.abs(clock:now() - (t0 + 62)) < 1e-6)
      assert.is_true(ui:shows("60 seconds passed."))
    end)

    it("keeps the sim's data to itself: You has its own db, and nothing is rated in the real one", function()
      assert.are_not.equal(t.me.db, ns.db)
      groupedWithDar()
      ui:press("Offer summon (green)")
      ui:press("Accept summon")
      ui:click(window("You arrived").stars.buttons[5])
      ui:press("Open trade with Dar Kbolt")
      pass(2)
      assert.are.equal(1, #ns.db.given) -- You rated him, in the sim's db
      assert.are.equal(0, #t.me.db.given) -- and the real db heard nothing of it
      assert.is_true(ns.engine.dirty)
      assert.are.equal("", Main:reminderText()) -- nothing of the sim is ever saved: no reminder to /reload
    end)
  end)

  describe("a ride through the real windows", function()
    before_each(function()
      start()
      Sim.start()
    end)

    it("request, toast, accept, guard, arrival and tip, end to end", function()
      ui:click(row(1).buttons[1])
      assert.is_true(ui:shows("Summon from Dar Kbolt"))
      ui:press("1g")
      ui:press("Send")
      local ride = ns.engine.rides["You#" .. Sim.state.dar.engine.stand.standId]
      assert.are.same({ "requested", 10000 }, { ride.state, ride.offer })
      pass(2)
      -- Dar Kbolt's side: his toast, with the traveler and the offer.
      local toast = assert(window("Dar Kbolt (sim) - Ride request"))
      assert.is_true(ui:shows("You (level 60)"))
      assert.is_true(ui:shows("Guildmate · Wants a summon"))
      assert.is_true(ui:shows("Offers 1g"))
      ui:press("Accept", toast)
      assert.is_nil(window("Dar Kbolt (sim) - Ride request"))
      pass(2)
      assert.is_true(ui:shows("Accepted - join group")) -- the Travel tab says so
      ui:press("Accept invite")
      assert.is_true(ui:shows("You joined Dar Kbolt's group."))

      -- The summon: GREEN, with the Summon Guard's lines, and no accept button.
      ui:press("Offer summon (green)")
      local title = ui:one{ kind = "FontString", text = "(sim) Summon Guard: GREEN - matches your ride" }
      assert.are.same({}, ui:find{ kind = "Button", within = title.parent })
      assert.is_true(ui:shows("✓ Trust rating OK"))

      -- You accept on the popup (the button stands for it): the panel goes, the arrival window comes.
      ui:press("Accept summon")
      assert.is_false(ui:shows("Summon Guard:"))
      local arrival = assert(window("You arrived"))
      assert.is_true(ui:shows("Summon from Dar Kbolt"))
      assert.is_false(ui:one{ kind = "Button", text = "1g" }.enabled) -- the offer, picked
      ui:click(arrival.stars.buttons[5])
      ui:press("Open trade with Dar Kbolt")
      assert.is_true(ui:shows("Put 1g in the trade")) -- Forever cannot set it, so the sim cannot either
      ui:press("Put 1g in the trade") -- the Put button: only its click sets money (M2)
      local money = Sim.state.you.money
      ui:press("Trade tip")
      assert.are.equal(money - 10000, Sim.state.you.money)
      assert.are.equal(10000, Sim.state.dar.money)
      assert.is_true(ui:shows("You gave 1g to Dar Kbolt."))
      pass(3)
      assert.are.equal("done", ride.state)
      -- The ride is in the History tab.
      ui:press("History")
      assert.is_true(ui:shows("Summon from Dar Kbolt"))
    end)

    it("shows RED for a summon from the wrong place, with Decline summon", function()
      ui:click(row(1).buttons[1])
      ui:press("Send")
      pass(2)
      ui:press("Accept", window("Dar Kbolt (sim) - Ride request"))
      pass(2)
      ui:press("Accept invite")
      ui:press("Offer summon (wrong place)")
      ui:one{ kind = "FontString", text = "(sim) Summon Guard: RED - do not accept" }
      assert.is_true(ui:shows("✗ Destination: Searing Gorge (agreed: Tanaris)"))
      assert.is_true(ui:shows("✗ Warlock is not at the agreed spot"))
      assert.is_true(ui:shows("✓ Summoner: Dar Kbolt"))
      assert.are.same({}, ui:find{ kind = "Button", text = "Accept" })
      ui:press("Decline summon")
      pass(1)
      assert.is_false(ui:shows("Summon Guard:"))
      assert.is_nil(Sim.state.you.summon)
    end)

    it("shows RED for a stranger's summon during the ride, and YELLOW when there is no ride", function()
      ui:press("Offer stranger summon")
      assert.is_true(ui:shows("Summon Guard: YELLOW - be careful"))
      assert.is_true(ui:shows("✗ Not a Taxi ride: Stan Ger → Searing Gorge"))
      ui:press("Accept summon") -- say, by mistake; the popup goes
      assert.is_false(ui:shows("Summon Guard:"))
      ui:click(row(1).buttons[1])
      ui:press("Send")
      pass(2)
      ui:press("Accept", window("Dar Kbolt (sim) - Ride request"))
      pass(2)
      ui:press("Accept invite")
      ui:press("Offer stranger summon")
      assert.is_true(ui:shows("Summon Guard: RED - do not accept"))
      assert.is_true(ui:shows("✗ Summoner: Stan Ger (agreed: Dar Kbolt)"))
    end)

    it("says what to do when a button has nothing to act on", function()
      ui:press("Offer summon (green)")
      assert.is_true(ui:shows("Request a ride from Dar Kbolt first"))
      ui:press("Accept summon")
      assert.is_true(ui:shows("No summon is waiting for you."))
      ui:press("Accept invite")
      assert.is_true(ui:shows("No invite is waiting for you"))
      ui:press("Trade tip")
      assert.is_true(ui:shows("Put the tip in a trade first"))
      ui:press("Mage opens portal")
      assert.is_true(ui:shows("Request a portal from Mag Ic first"))
      ui:press("Step through portal")
      assert.is_true(ui:shows("No portal is open for you."))
      ui:press("End shift")
      assert.is_true(ui:shows("Cee One's shift ended.")) -- Cee One and Cee Two are on Dar's crew
      ui:press("End shift")
      assert.is_true(ui:shows("Cee Two's shift ended."))
      ui:press("End shift")
      assert.is_true(ui:shows("Nobody is on a shift."))
    end)

    it("leaves the group you are in when you accept another's invite, as the player would have to", function()
      groupedWithDar()
      assert.are.equal(4, Sim.state.you.group and #Sim.state.you.group.members) -- Dar, his crew and You
      ui:press("Portals")
      ui:click(row(1).buttons[1])
      ui:click(ui:one{ kind = "FontString", text = "Stormwind" }.parent)
      ui:press("Send")
      pass(2)
      ui:press("Accept", window("Mag Ic (sim) - Ride request"))
      pass(2)
      assert.is_true(ui:shows("Leave your group so the driver can invite you.")) -- the footer says so
      ui:press("Accept invite")
      assert.is_true(ui:shows("You left your group and joined Mag Ic's."))
      assert.are.same({ "Mag Ic", "You" }, Sim.state.you.group.members)
      assert.are.equal("grouped", ns.engine.rides["You#" .. Sim.state.mag.engine.stand.standId].state)
    end)

    it("takes a portal ride: Mag Ic's toast, the alert, the portal, and an arrival window without stars", function()
      ui:press("Portals")
      ui:press("Request")
      ui:click(ui:one{ kind = "FontString", text = "Darnassus" }.parent)
      assert.is_true(ui:shows("Portal to Darnassus from Mag Ic"))
      ui:press("Send")
      pass(2)
      assert.is_true(ui:shows("Wants a portal to Darnassus"))
      ui:press("Accept", window("Mag Ic (sim) - Ride request"))
      pass(2)
      ui:press("Accept invite")
      ui:press("Mage opens portal")
      assert.is_true(ui:shows("Portal to Darnassus is up - click it!"))
      ui:press("Step through portal")
      local arrival = assert(window("You arrived"))
      assert.is_true(ui:shows("Portal to Darnassus from Mag Ic"))
      assert.is_false(ui:visible(arrival.stars))
      assert.are.same({}, ui:find{ kind = "Button", text = "Stay and click" })
    end)

    it("plays the stand owner's side: Stan Ger's application is answered in Ann Other's offer window", function()
      ui:press("Clicker applies")
      local offer = assert(window("Ann Other (sim) - Clicker offer"))
      assert.is_true(ui:shows("Stan Ger asks for 40%"))
      assert.is_true(ui:shows("You offered 30%"))
      ui:press("Accept", offer)
      pass(2)
      assert.are.equal(40, Sim.state.ann.engine.stand.clickers["Stan Ger"].pct)
      assert.is_nil(window("Ann Other (sim) - Clicker offer"))
    end)

    it("plays the clicker yourself: apply, a counter-offer back, a shift, and your own shift-end window", function()
      ui:press("Clicking")
      ui:click(Main.views.clicking.list.rows[1].buttons[1]) -- Ann Other's row: Apply at her 30%
      pass(2)
      local offer = assert(window("Ann Other (sim) - Clicker offer"))
      assert.is_true(ui:shows("You asks for 30%"))
      offer.counter:SetText("20")
      ui:press("Counter", offer)
      pass(2)
      assert.is_true(ui:shows("Ann Other offers 20% instead (you asked 30%)."))
      ui:press("Take it", window("Counter-offer"))
      pass(2)
      ui:press("Accept invite")
      assert.are.equal(20, ns.engine.shift.pct)
      ui:press("End shift") -- yours first
      assert.is_nil(ns.engine.shift)
      local ended = assert(window("Shift ended"))
      assert.is_true(ui:shows("Clicked for Ann Other at 20% of the tips"))
      assert.are.equal(0, ended.stars:GetValue()) -- nothing owed: no suggestion
      ui:click(ended.stars.buttons[4])
      ui:press("Submit", ended)
      pass(1)
      assert.is_nil(window("Shift ended"))
      assert.are.equal(1, #ns.db.given)
    end)

    it("ends a clicker's shift with the shift-end window, owed and received, and the stars suggested", function()
      groupedWithDar()
      ui:press("Offer summon (green)")
      ui:press("Accept summon")
      ui:click(window("You arrived").stars.buttons[5])
      ui:press("Open trade with Dar Kbolt")
      ui:press("Put 1g in the trade") -- the Put button: only its click sets money (M2)
      ui:press("Trade tip")
      pass(3)
      ui:press("End shift")
      local ended = assert(window("Cee One (sim) - Shift ended"))
      assert.is_true(ui:shows("Clicked for Dar Kbolt at 25% of the tips"))
      assert.is_true(ui:shows("Owed 25s · Received 0c"))
      assert.are.equal(1, ended.stars:GetValue())
      ui:press("Submit", ended)
      assert.is_nil(window("Cee One (sim) - Shift ended"))
    end)

    it("kills You: the window says so and every action is off", function()
      ui:press("Kill traveler")
      pass(1)
      assert.is_true(ui:shows("Your Hardcore character has died."))
      assert.is_false(row(1).buttons[1].enabled)
      ui:press("Stop sim")
      assert.is_false(Sim.active())
    end)
  end)

  -- The walkthrough in the Task 18 report, click for click: three rides in one sim.
  describe("the walkthrough", function()
    it("works from the first Request to the portal ride and Stop sim", function()
      start()
      Sim.start()
      -- 1. A ride: GREEN, arrival, rating, tip.
      ui:click(row(1).buttons[1])
      ui:press("1g")
      ui:press("Send")
      pass(2)
      ui:press("Accept", window("Dar Kbolt (sim) - Ride request"))
      pass(2)
      ui:press("Accept invite")
      ui:press("Offer summon (green)")
      assert.is_not_nil(ui:find{ kind = "FontString", text = "(sim) Summon Guard: GREEN - matches your ride" }[1])
      ui:press("Accept summon")
      ui:click(window("You arrived").stars.buttons[5])
      ui:press("Open trade with Dar Kbolt")
      ui:press("Put 1g in the trade") -- the Put button: only its click sets money (M2)
      ui:press("Trade tip")
      pass(3)
      assert.are.equal("done", ns.engine.rides["You#" .. Sim.state.dar.engine.stand.standId].state)
      -- With the ride over, a stranger's summon is just no Taxi ride: YELLOW.
      ui:press("Offer stranger summon")
      assert.is_true(ui:shows("Summon Guard: YELLOW - be careful"))
      assert.is_true(ui:shows("✗ Not a Taxi ride: Stan Ger → Searing Gorge"))
      ui:press("Accept summon")
      -- 2. Another ride, still in his group: RED wrong place, declined; a stranger; then GREEN again.
      ui:click(window("You arrived").CloseButton)
      ui:click(row(1).buttons[1])
      ui:press("Send")
      pass(2)
      ui:press("Accept", window("Dar Kbolt (sim) - Ride request"))
      pass(2)
      ui:press("Offer summon (wrong place)")
      assert.is_true(ui:shows("Summon Guard: RED - do not accept"))
      ui:press("Decline summon")
      pass(1)
      ui:press("Offer stranger summon")
      assert.is_true(ui:shows("✗ Summoner: Stan Ger (agreed: Dar Kbolt)"))
      ui:press("Accept summon")
      assert.are.equal("grouped", ns.engine.rides["You#" .. Sim.state.dar.engine.stand.standId].state)
      ui:press("Offer summon (green)")
      assert.is_true(ui:shows("Summon Guard: GREEN - matches your ride"))
      ui:press("Accept summon")
      assert.is_true(ui:visible(window("You arrived")))
      ui:press("Leave group")
      pass(1)
      -- 3. A portal ride, with the footer's status line on the way.
      ui:click(window("You arrived").CloseButton)
      ui:press("Portals")
      ui:click(row(1).buttons[1])
      ui:click(ui:one{ kind = "FontString", text = "Darnassus" }.parent)
      ui:press("Send")
      pass(2)
      ui:press("Accept", window("Mag Ic (sim) - Ride request"))
      pass(2)
      ui:press("Accept invite")
      ui:press("Mage opens portal")
      ui:press("Step through portal")
      assert.is_true(ui:visible(window("You arrived")))
      assert.is_true(ui:shows("Portal to Darnassus from Mag Ic"))
      Sim.stop()
      assert.are.equal(t.me.engine, ns.engine)
    end)
  end)

  describe("the real player", function()
    it("sends nothing to the real channel while the sim runs, and again after it", function()
      start()
      Sim.start()
      assert.is_true(t.me.engine.muted)
      groupedWithDar()
      ui:press("Offer summon (green)")
      ui:press("Accept summon")
      ui:press("Open trade with Dar Kbolt")
      ui:press("Put 1g in the trade") -- the Put button: only its click sets money (M2)
      ui:press("Trade tip")
      ui:press("Advance 60 s")
      w:advance(70) -- the real world's own time, heartbeats due included
      assert.are.equal(realBefore, #w.bus:sent())
      Sim.stop()
      assert.is_false(t.me.engine.muted)
      assert.is_string(t.me.engine:send("QUERY", { target = "Dar Kbolt" }, "CHANNEL"))
      w:advance(1)
      assert.are.equal(realBefore + 1, #w.bus:sent())
    end)

    it("still reports the real character's death while the sim runs (R62)", function()
      start()
      local id = ns.Ride.makeId("Dar Kbolt", "Tra Veler", w.clock:now())
      t.me.engine.witness:rideStarted(id, "Tra Veler", "Dar Kbolt", w.clock:now(), "Tra Veler")
      t.me.engine.witness:arrived(id, "Tra Veler", w.clock:now(), "Tra Veler")
      Sim.start()
      assert.is_true(t.me.engine.muted)
      w:advance(5)
      t.me.dead = true
      t.me.engine:onGame("PLAYER_DIED")
      w:advance(2)
      local sent = t.wireOf("DEATH", "Tra Veler")
      assert.are.equal(1, #sent)
      assert.are.same({ id, "Tra Veler", "Dar Kbolt", "self" }, { sent[1].rideId, sent[1].victim, sent[1].warlock, sent[1].source })
    end)

    it("stops cleanly: the real engine and its data are back, and the sim's windows are gone", function()
      start()
      local realDb = ns.db
      Sim.start()
      groupedWithDar()
      ui:press("Offer summon (wrong place)")
      assert.is_true(ui:shows("Summon Guard: RED - do not accept"))
      ui:press("Stop sim")
      assert.is_false(Sim.active())
      assert.are.equal(t.me.engine, ns.engine)
      assert.are.equal(realDb, ns.db)
      assert.is_false(ui:shows("Summon Guard:"))
      assert.is_nil(window("Sim controls"))
      assert.is_nil(window("Dar Kbolt (sim) - Ride request"))
      assert.is_nil(Sim.state)
      assert.are.equal("Taxi: Sim ended. Taxi is back on your real character.", ui.prints[#ui.prints])
    end)

    it("says so when asked to stop and no sim is running", function()
      start()
      Sim.stop()
      assert.are.same({ "Taxi: The sim is not running." }, ui.prints)
    end)

    it("keeps the real windows quiet during the sim, and shows what waited when it ends", function()
      start("lock")
      local stand = t.standOf(t.lock)
      Sim.start()
      assert.is_true(t.me.engine:requestRide(stand.standId, 0) ~= nil) -- a real traveler, in the real world
      w:advance(2)
      assert.is_nil(window("Ride request"))
      Sim.stop()
      assert.is_not_nil(window("Ride request"))
      assert.is_true(ui:shows("Tra Veler (level 44)"))
    end)

    -- A real summon is judged by the real engine and shown beside the real popup,
    -- sim or no sim; the sim's own panels are labelled and never go near a popup.
    describe("when a real summon comes during the sim", function()
      local REAL_YELLOW = "Summon Guard: YELLOW - be careful"
      local SIM_YELLOW = "(sim) Summon Guard: YELLOW - be careful"

      local function titled(title)
        local found = ui:find{ kind = "FontString", text = title }
        return found[1] and found[1].parent
      end

      local function lastPoint(frame)
        return frame.points[#frame.points]
      end

      before_each(function()
        start()
        Sim.start()
      end)

      it("still shows the real panel next to the real popup", function()
        local popup = ui.env.CreateFrame("Frame", "StaticPopup1", ui.env.UIParent)
        ui.popups.CONFIRM_SUMMON = popup
        w:offerSummon("Dar Kbolt", "Tra Veler") -- the real world: the real warlock, the real player
        local real = assert(titled(REAL_YELLOW))
        assert.are.same({ "TOPLEFT", popup, "TOPRIGHT", 8, 0 }, lastPoint(real))
        assert.is_true(ui:shows("✗ Not a Taxi ride: Dar Kbolt → Tanaris"))
        assert.is_true(ui:visible(real))
        w:fire(t.me, "SUMMON_GONE") -- the real popup closes
        assert.is_nil(titled(REAL_YELLOW))
      end)

      it("keeps the sim's panel apart: labelled, at the top centre, whatever the real popup does", function()
        local popup = ui.env.CreateFrame("Frame", "StaticPopup1", ui.env.UIParent)
        ui.popups.CONFIRM_SUMMON = popup
        local looked = 0
        local find = ui.env.StaticPopup_FindVisible
        ui.env.StaticPopup_FindVisible = function(...)
          looked = looked + 1
          return find(...)
        end
        ui:press("Offer stranger summon")
        local panel = assert(titled(SIM_YELLOW))
        assert.is_nil(titled(REAL_YELLOW))
        ui:update(1) -- its re-anchoring poll runs: it still does not look
        assert.are.equal(0, looked)
        assert.are.same({ "TOP", ui.env.UIParent, "TOP", 0, -24 }, lastPoint(panel))
        -- Both at once: each keeps its own place.
        w:offerSummon("Dar Kbolt", "Tra Veler")
        local real = assert(titled(REAL_YELLOW))
        assert.is_true(looked > 0)
        assert.are.same({ "TOPLEFT", popup, "TOPRIGHT", 8, 0 }, lastPoint(real))
        assert.are.same({ "TOP", ui.env.UIParent, "TOP", 0, -24 }, lastPoint(panel))
      end)

      it("leaves the real panel working after /taxi sim off", function()
        local popup = ui.env.CreateFrame("Frame", "StaticPopup1", ui.env.UIParent)
        ui.popups.CONFIRM_SUMMON = popup
        w:offerSummon("Dar Kbolt", "Tra Veler")
        assert.is_not_nil(titled(REAL_YELLOW))
        Sim.stop()
        assert.is_not_nil(titled(REAL_YELLOW)) -- a real verdict is not taken away by the sim ending
        w:fire(t.me, "SUMMON_GONE")
        assert.is_nil(titled(REAL_YELLOW))
        w:offerSummon("Dar Kbolt", "Tra Veler")
        assert.are.same({ "TOPLEFT", popup, "TOPRIGHT", 8, 0 }, lastPoint(assert(titled(REAL_YELLOW))))
      end)
    end)

    it("keeps what the real engine says out of the sim's footer", function()
      start()
      Sim.start()
      t.me.engine:status("STATUS_LEAVE_GROUP") -- the real engine, on the real channel's business
      assert.are_not.equal(ns.L.STATUS_LEAVE_GROUP, Main:statusText())
      ns.engine:status("STATUS_RAID_FAILED") -- the sim's own
      assert.are.equal(ns.L.STATUS_RAID_FAILED, Main:statusText())
    end)

    it("is unchanged when the sim cannot be built", function()
      start()
      ns.World.new = function() error("no world", 0) end
      assert.has_error(function() Sim.start() end, "no world")
      assert.is_false(Sim.active())
      assert.are.equal(t.me.engine, ns.engine)
      assert.is_false(t.me.engine.muted == true)
    end)

    it("is undone when it fails after taking over", function()
      start()
      ns.UI.ShiftEndWindow.attach = function() error("no window", 0) end
      assert.has_error(function() Sim.start() end, "no window")
      assert.is_false(Sim.active())
      assert.are.equal(t.me.engine, ns.engine)
      assert.are.equal(t.me.db, ns.db)
      assert.is_false(t.me.engine.muted == true)
      assert.is_nil(window("Sim controls"))
    end)

    it("will not start without an Engine", function()
      start()
      ns.engine = nil
      Sim.start()
      assert.is_false(Sim.active())
      assert.are.same({ "Taxi: Taxi is not running. /taxi debug shows why." }, ui.prints)
    end)
  end)
end)
