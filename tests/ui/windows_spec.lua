-- The main window, its four tabs and the minimap button, run against a real
-- Engine on the simulated world (Taxi/Sim) and the strict fake frame API
-- (tests/ui/fake_ui.lua). The UI is one player's: the others act through their
-- own engines.
local FakeUI = dofile("tests/ui/fake_ui.lua")

-- Every visible text shows "|" only doubled (R14): the game reads a single one
-- as the start of a colour or link code.
local function noRawPipes(ui)
  for _, text in ipairs(ui:texts()) do
    local rest = text:gsub("||", "")
    assert.is_nil(rest:find("|", 1, true), text)
  end
end

-- Decoded single-chunk messages of one type on the bus, optionally from one sender.
local function wireOf(ns, w, msgType, sender)
  local out = {}
  for _, sent in ipairs(w.bus:sent()) do
    local text = sent.text:match("^[^:]+:1/1:(.*)$")
    local msg = text and ns.Protocol.decode(text)
    if msg and msg.type == msgType and (sender == nil or sent.sender == sender) then
      msg.dist, msg.to = sent.dist, sent.target
      out[#out + 1] = msg
    end
  end
  return out
end

describe("windows", function()
  local ns, w, ui, lock, me, c1, c2, mage, Main

  -- A world with a warlock, a traveler and two possible clickers; the window is
  -- `viewer`'s (a key of the table below), started like Core/Init starts it.
  local function boot(viewer, beforeStart)
    ns = Taxi.load()
    w = ns.World.new{ seed = 5, start = 50000 }
    lock = w:addPlayer{ name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan", guild = "Crew" }
    me = w:addPlayer{ name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000,
      guild = "Crew" }
    c1 = w:addPlayer{ name = "Cee One", class = "PRIEST", level = 40, place = "gadgetzan" }
    c2 = w:addPlayer{ name = "Cee Two", class = "ROGUE", level = 40, place = "gadgetzan" }
    mage = w:addPlayer{ name = "Mag Ic", class = "MAGE", level = 45, place = "gadgetzan" }
    ui = FakeUI.new()
    ui.load(ns)
    local p = ({ lock = lock, me = me, c1 = c1, c2 = c2, mage = mage })[viewer]
    ns.engine, ns.db = p.engine, p.db
    Main = ns.UI.Main
    if beforeStart then
      beforeStart()
    end
    Main:Start()
  end

  after_each(function()
    if w then
      assert.are.same({}, w.errors) -- the window's repaints log to the Engine's sink
    end
  end)

  local function standOf(p, o)
    local s = assert(p.engine:openStand(o or { kind = "lock" }))
    w:advance(2)
    return s
  end

  describe("the window", function()
    before_each(function() boot("me") end)

    it("is built hidden at login and toggled by /taxi; Esc closes it", function()
      assert.is_false(Main:IsShown())
      assert.is_not_nil(ui.env.TaxiMainFrame)
      assert.is_false(ui:visible(ui.env.TaxiMainFrame))
      Main:Toggle()
      assert.is_true(Main:IsShown())
      assert.is_true(ui:visible(ui.env.TaxiMainFrame))
      assert.are.same({ "TaxiMainFrame" }, ui.env.UISpecialFrames)
      assert.are.equal("Taxi", ui.env.TaxiMainFrame.TitleText:GetText())
      Main:Toggle()
      assert.is_false(Main:IsShown())
    end)

    it("explains itself when the Engine does not exist", function()
      ns.engine = nil
      Main:Toggle()
      assert.is_false(Main:IsShown())
      assert.are.same({ "Taxi: Taxi is not running. /taxi debug shows why." }, ui.prints)
    end)

    it("has four tabs and shows one at a time", function()
      Main:Show()
      for _, label in ipairs({ "Travel", "My stand", "Clicking", "History" }) do
        assert.is_true(ui:visible(ui:one{ kind = "Button", text = label }))
      end
      assert.is_false(ui:one{ kind = "Button", text = "Travel" }.enabled) -- the open tab
      assert.is_true(ui:shows("Summons"))
      ui:press("History")
      assert.is_false(ui:shows("Summons"))
      assert.is_true(ui:shows("No rides yet."))
      Main:ShowTab("stand")
      assert.is_true(ui:shows("Open stand"))
      Main:Hide()
      Main:Show("clicking")
      assert.is_true(ui:shows("No stand needs clickers right now."))
    end)

    it("repaints at once on an event and every five seconds anyway", function()
      Main:Show()
      assert.is_true(ui:shows("No stands on the board yet."))
      standOf(lock)
      assert.is_true(ui:shows("No stands on the board yet.")) -- marked dirty, painted on the next frame
      ui:update(0.02)
      assert.is_false(ui:shows("No stands on the board yet."))
      assert.is_true(ui:shows("Dar Kbolt"))
    end)

    it("starts once: a second Start adds no second set of listeners", function()
      local handlers = me.engine.callbacks.handlers
      local counts = {}
      for event, list in pairs(handlers) do counts[event] = #list end
      Main:Start()
      for event, list in pairs(handlers) do
        assert.are.equal(counts[event], #list, event)
      end
      assert.are.equal(1, counts.BOARD_CHANGED)
      assert.are.equal(4, counts.RIDE_CHANGED) -- the repaint, the notices, the History journal and the driver toast
    end)

    it("repainting makes no new frames", function()
      Main:Show()
      local before = #ui.frames
      standOf(lock)
      ui:update(0.02)
      assert.are.equal(before, #ui.frames)
    end)
  end)

  describe("a game that starts in combat", function()
    -- The secure button can't be set up in combat lockdown (the fake raises, as the game does).
    local function bootInCombat()
      boot("lock")
      Main.started, Main.frame = false, nil
      ui = FakeUI.new()
      ui.load(ns)
      ui.combat = true
      Main = ns.UI.Main
      Main:Start()
    end

    it("builds the window when combat ends, and opens it then if it was asked for", function()
      bootInCombat()
      assert.is_nil(ui.env.TaxiMainFrame)
      Main:Toggle()
      assert.are.same({ "Taxi: Taxi's window opens once combat ends." }, ui.prints)
      assert.is_false(Main:IsShown())
      ui.combat = false
      ui:event("PLAYER_REGEN_ENABLED")
      assert.is_true(Main:IsShown())
      assert.is_true(ui:shows("Summons")) -- the Travel tab, the one that was open
    end)

    it("builds it without opening it when nobody asked", function()
      bootInCombat()
      ui.combat = false
      ui:event("PLAYER_REGEN_ENABLED")
      assert.is_false(Main:IsShown())
      Main:Toggle()
      assert.is_true(Main:IsShown())
    end)
  end)

  -- The window holds the secure button, so the game treats it, the open tab and
  -- the stand header as protected (see the fake): in combat they are left as they are.
  describe("in combat", function()
    before_each(function() boot("lock") end)

    it("asks for the window and opens it when combat ends", function()
      ui.combat = true
      Main:Toggle()
      assert.is_false(Main:IsShown())
      assert.are.same({ "Taxi: Taxi's window opens once combat ends." }, ui.prints)
      ui.combat = false
      ui:event("PLAYER_REGEN_ENABLED")
      assert.is_true(Main:IsShown())
    end)

    it("keeps an open window open and says Esc closes it", function()
      Main:Show("stand")
      ui.combat = true
      Main:Toggle()
      Main:Hide()
      assert.is_true(Main:IsShown())
      assert.are.same({ "Taxi: Taxi's window can't be closed during combat; press Esc." }, ui.prints)
    end)

    it("does not switch tabs, and says so in the footer", function()
      Main:Show()
      ui.combat = true
      ui:press("History")
      assert.are.equal("Tabs can't be switched during combat.", Main:statusText())
      assert.is_true(ui:shows("Summons")) -- still the Travel tab
      ui.combat = false
      ui:press("History")
      assert.is_true(ui:shows("No rides yet."))
    end)

    it("goes on painting the open tab, and swaps the form for the header only after combat", function()
      Main:Show("stand")
      Main.views.stand.form.seats:SetText("3")
      ui:press("Open stand")
      assert.is_true(ui:shows("Summon stand at Tanaris - Gadgetzan"))
      ui.combat = true
      lock.engine:closeStand() -- say, the owner walked away
      ui:update(0.02) -- the fake raises on any change to the protected frames
      assert.is_true(ui:shows("Summon stand at Tanaris - Gadgetzan")) -- the old header, until combat ends
      ui.combat = false
      ui:event("PLAYER_REGEN_ENABLED")
      ui:update(0.02)
      assert.is_true(ui:shows("Open stand"))
      assert.is_false(ui:shows("Summon stand at"))
    end)

    it("does not start moving the window, and lets go of a drag when combat ends", function()
      Main:Show()
      local frame = ui.env.TaxiMainFrame
      ui:fire(frame, "OnDragStart")
      assert.is_true(frame.moving)
      ui.combat = true
      ui:fire(frame, "OnDragStop") -- can't be stopped now
      assert.is_true(frame.moving)
      ui.combat = false
      ui:event("PLAYER_REGEN_ENABLED")
      assert.is_false(frame.moving)
      ui.combat = true
      ui:fire(frame, "OnDragStart")
      assert.is_false(frame.moving)
    end)
  end)

  describe("a window that fails to build", function()
    local logged

    before_each(function()
      boot("lock", function()
        ns.UI.History.new = function() error("boom") end -- the last tab's constructor
      end)
      logged, w.errors = w.errors, {} -- what the Engine's log sink was given
    end)

    it("leaves nothing visible, logs the failure, and is not built or registered twice", function()
      local frame = assert(ui.env.TaxiMainFrame)
      for _, f in ipairs(ui.frames) do
        local up = f
        while up and up ~= frame do up = up.parent end
        if up == frame then
          assert.is_false(ui:visible(f))
        end
      end
      assert.is_false(Main:IsShown())
      assert.are.same({}, ui.env.UISpecialFrames)
      assert.are.equal(1, #logged)
      assert.truthy(logged[1]:find("window build", 1, true))
      assert.truthy(logged[1]:find("boom", 1, true))
      local made = #ui.frames
      Main:Toggle()
      Main:Toggle()
      assert.are.equal(made, #ui.frames)
      assert.are.equal(frame, ui.env.TaxiMainFrame)
      assert.are.same({}, ui.env.UISpecialFrames)
      assert.are.same({ "Taxi: Taxi's window could not be built. /taxi debug shows why.",
        "Taxi: Taxi's window could not be built. /taxi debug shows why." }, ui.prints)
      assert.is_false(Main:IsShown())
    end)

    it("still runs the rest of Taxi: the minimap button, the journal and the notices", function()
      assert.is_not_nil(ui.env.TaxiMinimapButton)
      lock.engine:status("STATUS_LEAVE_GROUP")
      assert.are.equal(ns.L.STATUS_LEAVE_GROUP, Main:statusText())
    end)
  end)

  describe("the Travel tab", function()
    before_each(function() boot("me") end)

    it("lists a stand with its owner, place, seats and trust", function()
      standOf(lock, { kind = "lock", seats = 3, note = "Fast & kind" })
      Main:Show()
      assert.is_true(ui:shows("Dar Kbolt"))
      assert.is_true(ui:shows("Tanaris - Gadgetzan"))
      assert.is_true(ui:shows("3 seats free"))
      assert.is_true(ui:shows("New · no ratings yet"))
      assert.is_true(ui:visible(ui:one{ kind = "Button", text = "Request" }))
    end)

    it("shows the stars, the summons, New and reported deaths of a rated warlock", function()
      standOf(lock)
      local db = me.db
      for i = 1, 6 do
        local rater = "Old Rider" .. string.char(96 + i)
        local ts = 49000 + i
        assert(ns.Ratings.addDirect(db, { kind = "trust", rater = rater, target = "Dar Kbolt", stars = 5,
          id = ns.Ride.makeId("Dar Kbolt", rater, ts), ts = ts }, rater, 50002))
      end
      Main:Show()
      assert.is_true(ui:shows("★ 5.0 · 6 summons"))
      assert.is_false(ui:shows("· New"))
      assert(ns.Ratings.addDeath(db, { target = "Dar Kbolt", victim = "Vic Tim", id = "Dar Kbolt@Vic Tim@49000",
        ts = 49100, heavy = true, source = "observed" }, 50002))
      Main:Invalidate()
      ui:update(0.02)
      assert.is_true(ui:shows("⚠ 1 reported death"))
    end)

    it("puts guildmates first and in green", function()
      local ann = w:addPlayer{ name = "Ann Other", class = "WARLOCK", level = 45, place = "gadgetzan" }
      standOf(ann)
      standOf(lock)
      Main:Show()
      local view = Main.views.travel
      assert.are.equal("Dar Kbolt", view.list.rows[1].title:GetText()) -- Ann sorts first by name; the guild beats it
      assert.are.same(ns.UI.Widgets.COLOR.green, view.list.rows[1].title.color)
      assert.are.equal("Ann Other", view.list.rows[2].title:GetText())
      assert.are.same(ns.UI.Widgets.COLOR.white, view.list.rows[2].title.color)
    end)

    it("never shows a raw | from the wire, in any text", function()
      local now = w.clock:now()
      local view = ns.Stand.fromFields({
        standId = "Evil|cff00ff00Name@1", kind = "lock", faction = "Alliance", mapID = 1446, wx = 0, wy = 0,
        zone = "Zone|r", subzone = "Sub|cffff0000", seatsFree = 2, clickers = 0, clickerPct = 25,
        note = "Note|cffff0000X",
      }, "Evil|cff00ff00Name", now)
      ns.Board.upsert(me.engine.board, view, now)
      Main:Show()
      assert.is_true(ui:shows("Evil||cff00ff00Name"))
      ui:click(Main.views.travel.list.rows[1]) -- the details, with the note
      assert.is_true(ui:shows("Note||cffff0000X"))
      noRawPipes(ui)
      Main:ShowTab("clicking")
      assert.is_true(ui:shows("Evil||cff00ff00Name"))
      noRawPipes(ui)
    end)

    it("never lets a control character from the wire make a second line", function()
      local now = w.clock:now()
      local function stand(id, kind, extra)
        local fields = {
          standId = id, kind = kind, faction = "Alliance", mapID = 1446, wx = 0, wy = 0,
          zone = "Tanaris\n★ 5.0 · 999 summons\nX", subzone = "Sub\r\tz\127", seatsFree = 2, clickers = 0,
          clickerPct = 25, note = "n1\nn2\1n3",
        }
        for k, v in pairs(extra or {}) do fields[k] = v end
        return ns.Stand.fromFields(fields, id:match("^(.-)@"), now)
      end
      ns.Board.upsert(me.engine.board, stand("Evil One@1", "lock"), now)
      ns.Board.upsert(me.engine.board, stand("Evil Two@1", "mage", { portals = { "stormwind\n⚠ fake", "ironforge" } }), now)
      local function noControls()
        for _, text in ipairs(ui:texts()) do
          assert.is_nil(text:find("%c"), text)
        end
      end
      Main:Show()
      local list = Main.views.travel.list
      assert.are.equal("New · no ratings yet", list.rows[1].sub2:GetText()) -- the real trust line, nothing forged
      assert.are.equal("Tanaris ★ 5.0 · 999 summons X - Sub  z ", list.rows[1].sub:GetText())
      ui:click(list.rows[1])
      assert.is_true(ui:shows("Note: n1 n2 n3"))
      noControls()
      ui:press("Portals")
      assert.truthy(list.rows[1].sub2:GetText():find("stormwind ⚠ fake, Ironforge", 1, true))
      noControls()
      Main:ShowTab("clicking")
      noControls()
    end)

    it("picking a row shows its details and asks the channel about the warlock once", function()
      standOf(lock, { kind = "lock", note = "Fast" })
      Main:Show()
      assert.is_true(ui:shows("Select a stand to see its details."))
      ui:click(Main.views.travel.list.rows[1])
      assert.is_true(ui:shows("Note: Fast"))
      assert.is_true(ui:shows("Clickers 0/2 · 25% of the tips each"))
      assert.is_not_nil(me.engine.queryBook.asked["Dar Kbolt"])
      w:advance(1)
      assert.are.equal(1, #wireOf(ns, w, "QUERY", "Tra Veler"))
      ui:click(Main.views.travel.list.rows[1]) -- again within the cooldown: nothing more is sent
      w:advance(1)
      assert.are.equal(1, #wireOf(ns, w, "QUERY", "Tra Veler"))
    end)

    it("filters by zone and forgets a zone whose last stand has left", function()
      local eve = w:addPlayer{ name = "Eve Ning", class = "WARLOCK", level = 45, place = "searing" }
      standOf(lock)
      standOf(eve)
      Main:Show()
      local view = Main.views.travel
      assert.is_true(ui:shows("Dar Kbolt") and ui:shows("Eve Ning"))
      ui:click(view.dropdown)
      ui:click(ui:one{ kind = "FontString", text = "Tanaris" }.parent)
      assert.are.equal("Tanaris", view.dropdown:GetText())
      assert.is_true(ui:shows("Dar Kbolt"))
      assert.is_false(ui:shows("Eve Ning"))
      ui:click(view.dropdown)
      ui:click(ui:one{ kind = "FontString", text = "All zones" }.parent)
      assert.is_true(ui:shows("Eve Ning"))
      ui:click(view.dropdown)
      ui:click(ui:one{ kind = "FontString", text = "Searing Gorge" }.parent)
      assert.is_false(ui:shows("Dar Kbolt"))
      eve.engine:closeStand()
      w:advance(2)
      ui:update(0.02)
      assert.are.equal("All zones", view.dropdown:GetText()) -- the filter went with its last stand
      assert.is_true(ui:shows("Dar Kbolt"))
    end)

    it("shows and filters a stand by its map's zone, not the zone its message names (R65)", function()
      local liar = w:addPlayer{ name = "Lia Rlock", class = "WARLOCK", level = 45, place = "searing",
        zoneText = "Ironforge", subzoneText = "The Commons" }
      standOf(liar)
      Main:Show()
      local view = Main.views.travel
      assert.are.equal("Searing Gorge - The Commons", view.list.rows[1].sub:GetText())
      assert.is_false(ui:shows("Ironforge - The Commons"))
      ui:click(view.list.rows[1])
      assert.is_true(ui:shows("Lia Rlock - Searing Gorge - The Commons"))
      ui:click(view.dropdown)
      assert.are.same({}, ui:find{ kind = "FontString", text = "Ironforge" })
      ui:click(ui:one{ kind = "FontString", text = "Searing Gorge" }.parent)
      assert.is_true(ui:shows("Lia Rlock"))
      ui:press("Request")
      assert.is_true(ui:shows("Searing Gorge - The Commons")) -- the request dialog
    end)

    it("drops a stand that went quiet at its TTL without waiting for the 30 s sweep (R51)", function()
      standOf(lock)
      Main:Show()
      assert.is_true(ui:shows("Dar Kbolt"))
      local stand = next(me.engine.board.stands)
      me.engine.board.stands[stand].seenAt = w.clock:now() - ns.Config.STAND_TTL - 1
      ui:update(1)
      assert.is_true(ui:shows("Dar Kbolt")) -- under five seconds: not yet repainted
      ui:update(4.5)
      assert.is_false(ui:shows("Dar Kbolt"))
    end)

    it("asks for a seat, shows where the ride is, and offers the button again after a decline", function()
      local s = standOf(lock)
      Main:Show()
      ui:press("Request")
      assert.is_nil(me.engine.rides["Tra Veler#" .. s.standId]) -- the dialog asks about the tip first
      ui:press("Send")
      local key = "Tra Veler#" .. s.standId
      assert.are.equal("requested", me.engine.rides[key].state)
      ui:update(0.02)
      assert.is_true(ui:shows("Waiting for an answer"))
      assert.are.same({}, ui:find{ kind = "Button", text = "Request" })
      assert.is_true(ui:shows("Requested a seat from Dar Kbolt."))
      w:advance(2)
      assert.is_true(lock.engine:declineRequest(key, "busy"))
      w:advance(2)
      ui:update(0.02)
      assert.are.equal("Dar Kbolt declined your request.", Main:statusText())
      assert.is_true(ui:visible(ui:one{ kind = "Button", text = "Request" }))
    end)

    it("says why a request was refused, on the dialog, which stays open", function()
      local s = standOf(lock)
      Main:Show()
      lock.engine:closeStand()
      w:advance(2)
      -- the stand is still on the screen until the next repaint: Send finds it gone
      local button = ui:one{ kind = "Button", text = "Request" }
      me.engine.board.stands[s.standId] = nil
      ui:click(button)
      ui:press("Send")
      assert.is_true(ui:shows("That stand is no longer on the board."))
      assert.is_true(ui:visible(ui.env.TaxiRequestFrame))
      assert.are.same({}, me.engine.rides)
    end)

    it("shows mage stands under Portals and asks which portal", function()
      local s = standOf(mage, { kind = "mage" })
      standOf(lock)
      Main:Show()
      assert.is_false(ui:shows("Mag Ic"))
      ui:press("Portals")
      assert.is_true(ui:shows("Mag Ic"))
      assert.is_false(ui:shows("Dar Kbolt"))
      assert.is_true(ui:shows("Portals: Stormwind, Ironforge, Darnassus"))
      assert.is_true(ui:shows("Tanaris - Gadgetzan")) -- where the mage stands, too
      ui:press("Request")
      ui:click(ui:one{ kind = "FontString", text = "Ironforge" }.parent)
      ui:press("Send")
      local ride = me.engine.rides["Tra Veler#" .. s.standId]
      assert.are.same({ "portal", "ironforge" }, { ride.kind, ride.dest })
    end)

    it("says a dead Hardcore character has died and turns every action off", function()
      standOf(lock)
      Main:Show()
      assert.is_true(ui:one{ kind = "Button", text = "Request" }.enabled)
      me.dead = true
      Main:Invalidate()
      ui:update(0.02)
      assert.is_true(ui:shows("Your Hardcore character has died."))
      assert.is_false(ui:one{ kind = "Button", text = "Request" }.enabled)
      assert.is_false(ui:press("Request"))
      assert.are.same({}, me.engine.rides)
      Main:ShowTab("stand")
      assert.is_false(ui:one{ kind = "Button", text = "Open stand" }.enabled)
    end)
  end)

  describe("the footer", function()
    before_each(function() boot("me") end)

    local REMINDER = "New ratings are saved on /reload or logout."

    it("reminds to save new ratings, but not in combat (spec 8.4)", function()
      Main:Show()
      assert.are.equal("", Main:reminderText())
      me.engine.dirty = true
      assert.are.equal(REMINDER, Main:reminderText())
      ui.combat = true
      assert.are.equal("", Main:reminderText())
      ui.combat = false
      Main:Invalidate()
      ui:update(0.02)
      assert.is_true(ui:shows(REMINDER))
    end)

    it("shows the reminder beside a newer-version status, for as long as that stays", function()
      Main:Show()
      me.engine:onVersion() -- one newer peer: updateShown stays set for the session
      me.engine.dirty = true
      Main:Invalidate()
      ui:update(0.02)
      assert.is_true(ui:shows(ns.L.STATUS_UPDATE))
      assert.is_true(ui:shows(REMINDER))
    end)

    it("shows the reminder beside what is wrong with Taxi", function()
      Main:Show()
      me.engine.disabled = true
      me.engine.dirty = true
      Main:Invalidate()
      ui:update(0.02)
      assert.is_true(ui:shows(ns.L.STATUS_CHANNEL_FULL))
      assert.is_true(ui:shows(REMINDER))
    end)

    it("shows the reminder beside an action's answer", function()
      Main:Show()
      me.engine:status("STATUS_LEAVE_GROUP")
      me.engine.dirty = true
      Main:Invalidate()
      ui:update(0.02)
      assert.is_true(ui:shows(ns.L.STATUS_LEAVE_GROUP))
      assert.is_true(ui:shows(REMINDER))
    end)

    it("hides the reminder in combat, and nothing else with it", function()
      Main:Show()
      me.engine:onVersion()
      me.engine.dirty = true
      ui.combat = true
      Main:Invalidate()
      ui:update(0.02)
      assert.is_true(ui:shows(ns.L.STATUS_UPDATE))
      assert.is_false(ui:shows(REMINDER))
    end)

    it("shows what is wrong with Taxi while it is, and not after", function()
      Main:Show()
      me.engine.disabled = true
      assert.are.equal(ns.L.STATUS_CHANNEL_FULL, Main:statusText())
      me.engine.disabled = false
      me.engine.inInstance = true
      assert.are.equal(ns.L.STATUS_LOCKDOWN, Main:statusText())
      me.engine.inInstance = false
      me.engine:onVersion()
      assert.are.equal(ns.L.STATUS_UPDATE, Main:statusText())
    end)

    it("shows a STATUS the Engine says for ten seconds", function()
      Main:Show()
      me.engine:status("STATUS_LEAVE_GROUP")
      ui:update(0.02)
      assert.is_true(ui:shows("Leave your group so the driver can invite you."))
      w:advance(11)
      ui:update(5)
      assert.are.equal("", Main:statusText())
      assert.is_false(ui:shows("Leave your group"))
    end)
  end)

  describe("the My stand tab", function()
    before_each(function() boot("lock") end)

    local function openForm(seats, share, note)
      Main:Show("stand")
      local f = Main.views.stand.form
      f.seats:SetText(seats)
      f.share:SetText(share)
      f.note:SetText(note)
    end

    -- Opens a stand from the form; the other players hear it (two seconds).
    local function openStand(seats, share, note)
      openForm(seats, share, note)
      ui:press("Open stand")
      w:advance(2)
      return lock.engine.stand
    end

    it("opens a stand from the form and shows its header", function()
      openForm("4", "30", "Fast")
      ui:press("Open stand")
      local stand = lock.engine.stand
      assert.are.same({ "lock", 4, 30, "Fast" }, { stand.kind, stand.seats, stand.clickerPct, stand.note })
      assert.are.same({ seats = 4, clickerPct = 30, note = "Fast" }, lock.charDb.stand)
      ui:update(0.02)
      assert.is_true(ui:shows("Summon stand at Tanaris - Gadgetzan"))
      assert.is_true(ui:shows("Recruiting clickers"))
      assert.is_true(ui:shows("Seats 4 (4 free) · Clickers 0/2 · 30% of the tips each"))
      assert.is_false(ui:shows("Open stand"))
      assert.is_true(ui:shows("Your stand is open."))
    end)

    it("starts the form from the character's last stand", function()
      lock.charDb.stand = { seats = 6, clickerPct = 20, note = "hello" }
      Main:Show("stand")
      local f = Main.views.stand.form
      assert.are.same({ "6", "20", "hello" }, { f.seats:GetText(), f.share:GetText(), f.note:GetText() })
    end)

    it("says why a stand can't be opened", function()
      openForm("0", "25", "")
      ui:press("Open stand")
      assert.are.equal("Seats must be a whole number from 1 to 37.", Main:statusText())
      ui:press("Mage portals")
      assert.is_false(ui:shows("Clicker share %")) -- portal stands have no clickers
      Main.views.stand.form.seats:SetText("3")
      ui:press("Open stand")
      assert.are.equal("You don't know any portal spell yet.", Main:statusText())
      assert.is_nil(lock.engine.stand)
    end)

    it("closes the stand", function()
      openForm("3", "25", "")
      ui:press("Open stand")
      ui:press("Close stand")
      assert.is_nil(lock.engine.stand)
      ui:update(0.02)
      assert.is_true(ui:shows("Open stand"))
    end)

    it("works a request through: Accept, wait for the group, then the secure Summon button", function()
      local s = openStand("3", "25", "")
      me.engine:requestRide(s.standId, 10000)
      w:advance(2)
      ui:update(0.02)
      assert.is_true(ui:shows("Tra Veler (level 44)"))
      assert.is_true(ui:shows("Offers 1g"))
      local secure = Main.views.stand.head.secure
      assert.is_false(secure.enabled) -- nobody in the group yet
      assert.is_true(ui:shows("Nobody in your group is waiting"))
      ui:press("Accept", Main.views.stand.frame)
      w:advance(2)
      ui:update(0.02)
      assert.is_true(ui:shows("Invited - waiting for them to join"))
      assert.is_true(w:acceptInvite("Tra Veler"))
      w:advance(1)
      ui:update(0.02)
      assert.is_true(ui:shows("In your group"))
      assert.are.same({ true, "Summon Tra Veler" }, { secure.enabled, secure:GetText() })
      assert.are.same({ "spell", ns.Config.RITUAL_SPELL, "party1" },
        { secure.attributes.type, secure.attributes.spell, secure.attributes.unit })
      assert.is_false(secure.attributes.useOnKeyDown)
      assert.is_false(ui:shows("Nobody in your group is waiting"))

      -- The player's click casts (the game does that) and then tells the group.
      assert.are.equal(0, #wireOf(ns, w, "PORTAL_UP", "Dar Kbolt"))
      ui:click(secure)
      assert.are.same({ { spell = 698, unit = "party1" } }, ui.casts)
      w:advance(1)
      assert.are.equal(1, #wireOf(ns, w, "PORTAL_UP", "Dar Kbolt"))
      ui:fire(secure, "PostClick", "LeftButton", true) -- the press of a click: not told twice
      w:advance(1)
      assert.are.equal(1, #wireOf(ns, w, "PORTAL_UP", "Dar Kbolt"))
    end)

    it("leaves the secure button alone in combat and repaints it when combat ends", function()
      local s = openStand("3", "25", "")
      lock.game:invite("Cee One") -- takes party1, so the traveler joins as party2
      assert.is_true(w:acceptInvite("Cee One"))
      me.engine:requestRide(s.standId, 0)
      w:advance(2)
      lock.engine:acceptRequest("Tra Veler#" .. s.standId)
      w:advance(2)
      assert.is_true(w:acceptInvite("Tra Veler"))
      w:advance(1)
      ui:update(0.02)
      local secure = Main.views.stand.head.secure
      assert.are.same({ "Summon Tra Veler", "party2" }, { secure:GetText(), secure.attributes.unit })

      ui.combat = true
      ui:event("PLAYER_REGEN_DISABLED")
      w:leaveGroup(c1, false) -- Cee One leaves: the traveler is party1 now
      w:advance(1)
      ui:event("GROUP_ROSTER_UPDATE")
      ui:update(0.02) -- repaints without touching the protected button (the fake raises if it does)
      assert.are.equal("party1", lock.game:unitFor("Tra Veler"))
      assert.are.equal("party2", secure.attributes.unit) -- what it had, until combat ends
      assert.is_true(ui:click(secure)) -- the game would cast at that unit; nothing in Lua changed it

      ui.combat = false
      ui:event("PLAYER_REGEN_ENABLED")
      ui:update(0.02)
      assert.are.equal("party1", secure.attributes.unit)
    end)

    it("turns the Accept into Convert to raid & invite when the group would pass five", function()
      local names = { "Ann One", "Bea Two", "Cal Three", "Dee Four", "Eli Five" }
      local travelers = {}
      for i, name in ipairs(names) do
        travelers[i] = w:addPlayer{ name = name, class = "MAGE", level = 30, place = "ironforge" }
      end
      local s = openStand("37", "25", "")
      for _, p in ipairs(travelers) do
        p.engine:requestRide(s.standId, 0)
      end
      w:advance(2)
      for i = 1, 4 do
        assert.is_string(lock.engine:acceptRequest(names[i] .. "#" .. s.standId))
        w:advance(1)
        assert.is_true(w:acceptInvite(names[i]))
        w:advance(1)
      end
      ui:update(0.02)
      assert.are.same({}, ui:find{ kind = "Button", text = "Accept", within = Main.views.stand.frame }) -- the fifth would make 6
      ui:press("Convert to raid & invite", Main.views.stand.frame)
      assert.are.equal(ns.L.NOTICE_CONVERTING, Main:statusText())
      assert.is_not_nil(lock.engine.raidPending)
      w:advance(1) -- the game makes the raid; the accept follows
      ui:update(0.02)
      assert.are.equal("accepted", lock.engine.rides["Eli Five#" .. s.standId].state)
      assert.is_true(lock.game:isRaid())
      Main.views.stand.list:Scroll(10) -- the sixth row is past the first five
      assert.is_true(ui:shows("Invited - waiting for them to join"))
    end)

    it("declines a request", function()
      local s = openStand("3", "25", "")
      me.engine:requestRide(s.standId, 0)
      w:advance(2)
      ui:update(0.02)
      ui:press("Decline", Main.views.stand.frame)
      w:advance(2)
      assert.are.equal("declined", me.engine.rides["Tra Veler#" .. s.standId].state)
      ui:update(0.02)
      assert.is_false(ui:shows("Tra Veler"))
    end)

    it("takes a clicker's application, lists the crew with the agreed share, and dismisses them", function()
      local s = openStand("3", "25", "")
      assert.is_true(c1.engine:applyClicker(s.standId, 30))
      w:advance(2)
      ui:update(0.02)
      assert.is_true(ui:shows("Cee One asks for 30%"))
      assert.is_true(ui:shows("You offered 25%"))
      ui:press("Accept", Main.views.stand.frame)
      w:advance(2)
      ui:update(0.02)
      assert.is_true(ui:shows("30% of the tips"))
      assert.is_true(ui:shows("Cee One"))
      assert.are.equal(30, s.clickers["Cee One"].pct)
      ui:press("Dismiss", Main.views.stand.frame)
      w:advance(2)
      ui:update(0.02)
      assert.is_nil(s.clickers["Cee One"])
      assert.is_false(ui:shows("30% of the tips"))
    end)

    it("shows a countered application until the clicker answers, and can turn it down", function()
      local s = openStand("3", "25", "")
      assert.is_true(c1.engine:applyClicker(s.standId, 40))
      w:advance(2)
      assert.is_true(lock.engine:respondClicker("Cee One", "COUNTER", 20))
      ui:update(0.02)
      assert.is_true(ui:shows("You countered with 20%"))
      assert.are.same({}, ui:find{ kind = "Button", text = "Accept", within = Main.views.stand.frame })
      ui:press("Decline", Main.views.stand.frame)
      assert.are.same({}, s.talks)
    end)

    it("adds crew by hand, from the group", function()
      local s = openStand("3", "25", "")
      local head = Main.views.stand.head
      assert.are.equal("25", head.crewPct:GetText())
      head.crewName:SetText("Cee Two")
      ui:press("Add")
      assert.are.equal("They are not in your group.", Main:statusText())
      lock.game:invite("Cee Two")
      assert.is_true(w:acceptInvite("Cee Two"))
      w:advance(1)
      ui:press("Add")
      assert.are.equal(25, s.clickers["Cee Two"].pct)
      assert.are.equal("", head.crewName:GetText())
      ui:update(0.02)
      assert.is_true(ui:shows("25% of the tips"))
    end)

    it("lists what is owed to each clicker and opens a trade to pay", function()
      Main:Show("stand")
      local paid
      lock.engine.payoutList = function()
        return { { clicker = "Cee One", owed = 15000, received = 5000 }, { clicker = "Cee Two", owed = 0, received = 0 } }
      end
      lock.engine.payClicker = function(_, name)
        paid = name
        return true
      end
      Main:Invalidate()
      ui:update(0.02)
      assert.is_true(ui:shows("Payouts"))
      assert.is_true(ui:shows("Owed 1g 50s · paid 50s"))
      local pay = ui:find{ kind = "Button", text = "Pay" }
      assert.are.same({ true, false }, { pay[1].enabled, pay[2].enabled }) -- nothing to pay Cee Two
      ui:click(pay[1])
      assert.are.equal("Cee One", paid)
    end)

    it("shows a hint while the open stand has nothing to show", function()
      openForm("3", "25", "")
      ui:press("Open stand")
      ui:update(0.02)
      assert.is_true(ui:shows("Requests, clickers and payouts show up here."))
    end)
  end)

  describe("a mage's stand", function()
    before_each(function() boot("mage") end)

    it("opens a portal stand and aims the secure button at the next portal", function()
      Main:Show("stand")
      assert.are.equal("mage", Main.views.stand.kind) -- a mage starts on the mage form
      ui:press("Open stand")
      w:advance(2)
      local s = mage.engine.stand
      assert.are.equal("mage", s.kind)
      ui:update(0.02)
      assert.is_true(ui:shows("Portal stand at Tanaris - Gadgetzan"))
      assert.is_true(ui:shows("Portals: Stormwind, Ironforge, Darnassus"))
      assert.is_false(ui:one{ kind = "Button", text = "Open portal" }.enabled)
      me.engine:requestRide(s.standId, 0, "ironforge")
      w:advance(2)
      ui:update(0.02)
      assert.is_true(ui:shows("Ironforge")) -- the destination, on the request
      ui:press("Accept", Main.views.stand.frame)
      w:advance(2)
      assert.is_true(w:acceptInvite("Tra Veler"))
      w:advance(1)
      ui:update(0.02)
      local secure = Main.views.stand.head.secure
      assert.are.equal("Open portal to Ironforge", secure:GetText())
      assert.are.same({ "spell", 11416 }, { secure.attributes.type, secure.attributes.spell })
      assert.is_nil(secure.attributes.unit) -- a portal needs no target
      ui:click(secure)
      assert.are.same({ { spell = 11416 } }, ui.casts)
      w:advance(1)
      local up = wireOf(ns, w, "PORTAL_UP", "Mag Ic")
      assert.are.same({ 1, "ironforge" }, { #up, up[1].dest })
    end)
  end)

  describe("the Clicking tab", function()
    before_each(function() boot("c1") end)

    it("lists stands that need clickers with the share rating, offer and an Apply box", function()
      standOf(lock, { kind = "lock", clickerPct = 25 })
      Main:Show("clicking")
      assert.is_true(ui:shows("Dar Kbolt"))
      assert.is_true(ui:shows("Tanaris - Gadgetzan · Needs 2 clickers"))
      assert.is_true(ui:shows("Share: no ratings yet"))
      assert.is_true(ui:shows("Offers 25%"))
      assert.is_true(ui:shows("You are not on a shift."))
      assert.are.equal("25", Main.views.clicking.list.rows[1].edit:GetText())
    end)

    it("applies for the share in the box, shows the wait, and a counter-offer to take", function()
      local s = standOf(lock)
      Main:Show("clicking")
      Main.views.clicking.list.rows[1].edit:SetText("40")
      ui:press("Apply")
      assert.are.equal(40, c1.engine.application.askedPct)
      assert.is_true(ui:shows("Applied to click for Dar Kbolt."))
      ui:update(0.02)
      assert.is_true(ui:shows("You asked Dar Kbolt for 40% and are waiting for an answer."))
      assert.is_false(ui:one{ kind = "Button", text = "Apply" }.enabled)
      w:advance(2)
      assert.is_true(lock.engine:respondClicker("Cee One", "COUNTER", 20))
      w:advance(2)
      ui:update(0.02)
      assert.is_true(ui:shows("Dar Kbolt offers 20% instead (you asked 40%)."))
      ui:press("Take it", Main.views.clicking.frame)
      w:advance(2)
      assert.is_true(w:acceptInvite("Cee One"))
      w:advance(1)
      ui:update(0.02)
      assert.are.equal(20, c1.engine.shift.pct)
      assert.is_true(ui:shows("On shift for Dar Kbolt at 20% of the tips"))
      assert.is_true(ui:shows("Owed 0c · received 0c"))
      assert.are.same({ s.standId }, { c1.engine.shift.standId })
      ui:press("Leave")
      ui:update(0.02)
      assert.is_nil(c1.engine.shift)
      assert.is_true(ui:shows("You are not on a shift."))
      assert.is_true(ui:shows("Last shift for Dar Kbolt: owed 0c · received 0c"))
    end)

    it("says why an application was refused, and shows when the owner turns it down", function()
      standOf(lock)
      Main:Show("clicking")
      Main.views.clicking.list.rows[1].edit:SetText("0")
      ui:press("Apply")
      assert.are.equal("A share must be a whole number of percent.", Main:statusText())
      Main.views.clicking.list.rows[1].edit:SetText("30")
      ui:press("Apply")
      w:advance(2)
      assert.is_true(lock.engine:respondClicker("Cee One", "DECLINE"))
      w:advance(2)
      assert.are.equal("Dar Kbolt turned your application down.", Main:statusText())
      ui:update(0.02)
      assert.is_true(ui:one{ kind = "Button", text = "Apply" }.enabled)
    end)

    it("leaves out a stand that has its two clickers", function()
      standOf(lock)
      Main:Show("clicking")
      assert.is_true(ui:shows("Dar Kbolt"))
      local stand = next(c1.engine.board.stands)
      c1.engine.board.stands[stand].clickers = 2
      Main:Invalidate()
      ui:update(0.02)
      assert.is_false(ui:shows("Dar Kbolt"))
    end)
  end)

  describe("the History tab", function()
    -- A ride from request to arrival: Tra Veler asks, Dar accepts, they group up and Dar summons.
    local function ride()
      local s = standOf(lock)
      me.engine:requestRide(s.standId, 5000)
      w:advance(2)
      lock.engine:acceptRequest("Tra Veler#" .. s.standId)
      w:advance(2)
      assert.is_true(w:acceptInvite("Tra Veler"))
      w:advance(1)
      lock.engine:nextTraveler()
      w:offerSummon("Dar Kbolt", "Tra Veler")
      w:acceptSummon("Tra Veler")
      w:advance(2)
      return s
    end

    it("journals a ride that arrived and lists it with the newest first", function()
      boot("me")
      ride()
      assert.are.equal(1, #me.db.rides)
      local entry = me.db.rides[1]
      assert.are.same({ "traveler", "summon", "Dar Kbolt", "arrived", 5000 },
        { entry.role, entry.kind, entry.other, entry.outcome, entry.offer })
      Main:Show("history")
      assert.is_true(ui:shows("Summon from Dar Kbolt"))
      assert.is_true(ui:shows("Arrived"))
      assert.is_true(ui:shows("Tip offered: 50s"))
      assert.is_false(ui:shows("No rides yet."))
    end)

    it("journals a declined request, once, and the entry shows when it was", function()
      boot("me")
      local s = standOf(lock)
      local key = "Tra Veler#" .. s.standId
      me.engine:requestRide(s.standId, 0)
      w:advance(2)
      lock.engine:declineRequest(key)
      w:advance(2)
      assert.are.equal(1, #me.db.rides)
      assert.are.equal("declined", me.db.rides[1].outcome)
      assert.is_true(me.db.rides[1].ts >= 50004 and me.db.rides[1].ts <= w.clock:now()) -- when the DECLINE came
      Main:Show("history")
      local row = Main.views.history.list.rows[1]
      assert.are.equal("Summon from Dar Kbolt", row.title:GetText())
      assert.truthy(row.sub:GetText():find("· Declined", 1, true))
    end)

    it("journals the other side too: the stand's owner", function()
      boot("lock")
      local s = standOf(lock)
      me.engine:requestRide(s.standId, 0)
      w:advance(2)
      lock.engine:declineRequest("Tra Veler#" .. s.standId)
      w:advance(1)
      local entry = lock.db.rides[1]
      assert.are.same({ "provider", "summon", "Tra Veler", "declined" },
        { entry.role, entry.kind, entry.other, entry.outcome })
      Main:Show("history")
      assert.is_true(ui:shows("Summon for Tra Veler"))
    end)

    it("journals a clicker's shift, brought up to date when it is paid", function()
      boot("c1")
      local s = standOf(lock)
      assert.is_true(c1.engine:applyClicker(s.standId, 25))
      w:advance(2)
      assert.is_true(lock.engine:respondClicker("Cee One", "ACCEPT"))
      w:advance(2)
      assert.is_true(w:acceptInvite("Cee One"))
      w:advance(1)
      assert.is_not_nil(c1.engine.shift)
      c1.engine:leaveStand()
      assert.are.equal(1, #c1.db.rides)
      local entry = c1.db.rides[1]
      assert.are.same({ "clicker", "Dar Kbolt", "shift", 25, 0, 0 },
        { entry.role, entry.other, entry.outcome, entry.pct, entry.owed, entry.received })
      local ts = entry.ts
      w:advance(5)
      c1.engine:emit("SHIFT_ENDED", { shiftId = entry.id, owner = "Dar Kbolt", pct = 25, owed = 15000, received = 5000 })
      assert.are.equal(1, #c1.db.rides)
      assert.are.same({ ts, 15000, 5000 }, { c1.db.rides[1].ts, c1.db.rides[1].owed, c1.db.rides[1].received })
      Main:Show("history")
      assert.is_true(ui:shows("Clicked for Dar Kbolt"))
      assert.is_true(ui:shows("Owed 1g 50s · paid 50s"))
      assert.is_true(ui:shows("25% of the tips"))
    end)

    it("keeps the newest 200 and lists newest first", function()
      boot("me")
      local History = ns.UI.History
      for i = 1, 205 do
        History.record(me.db, { id = "r" .. i, ts = 1000 + i, role = "traveler", kind = "summon", other = "X" .. i,
          outcome = "arrived" })
      end
      assert.are.equal(200, #me.db.rides)
      local list = History.list(me.db)
      assert.are.same({ "r205", "r204", "r6" }, { list[1].id, list[2].id, list[200].id })
    end)

    it("copes with a SavedVariables that holds anything", function()
      boot("me")
      me.db.rides = { "junk", 5, { id = "a" }, { ts = "x", role = "clicker", pct = "n", owed = {} }, { ts = 5 }, { ts = 1e300, role = "traveler" } }
      Main:Show("history")
      assert.is_true(ui:visible(Main.views.history.frame))
      noRawPipes(ui)
      me.db.rides = "not a table"
      Main:Invalidate()
      ui:update(0.02)
      assert.is_true(ui:shows("No rides yet."))
    end)
  end)

  describe("the minimap button", function()
    before_each(function() boot("me") end)

    it("sits on the minimap's rim at the saved angle and toggles the window", function()
      local button = ui.env.TaxiMinimapButton
      assert.is_not_nil(button)
      local p = button.points[#button.points]
      local rim = 140 / 2 + 5
      assert.are.same({ "CENTER", ui.env.Minimap, "CENTER" }, { p[1], p[2], p[3] })
      assert.is_true(math.abs(p[4] - math.cos(math.rad(215)) * rim) < 1e-9)
      assert.is_true(math.abs(p[5] - math.sin(math.rad(215)) * rim) < 1e-9)
      ui:click(button)
      assert.is_true(Main:IsShown())
      ui:click(button)
      assert.is_false(Main:IsShown())
    end)

    it("is dragged around the rim and remembers where it was left", function()
      local button = ui.env.TaxiMinimapButton
      ui:fire(button, "OnDragStart")
      ui.cursor = { 500, 500 } -- straight above the minimap's centre (500, 400)
      ui:update(0.01)
      local p = button.points[#button.points]
      assert.is_true(math.abs(p[4]) < 1e-9)
      assert.is_true(math.abs(p[5] - 75) < 1e-9)
      ui:fire(button, "OnDragStop")
      assert.is_nil(button.scripts.OnUpdate)
      assert.are.equal(90, me.db.settings.minimap.angle)
    end)

    it("starts from a saved angle", function()
      me.db.settings.minimap = { angle = 0 }
      ns.UI.MinimapButton.button = nil
      local button = ns.UI.MinimapButton.create()
      local p = button.points[#button.points]
      assert.is_true(math.abs(p[4] - 75) < 1e-9)
    end)

    it("shows a tooltip with the status line, escaped", function()
      local button = ui.env.TaxiMinimapButton
      me.engine.disabled = true
      ui:fire(button, "OnEnter")
      assert.is_true(ui.tooltip.shown)
      assert.are.same({ "Taxi", ns.L.MINIMAP_TIP, ns.L.STATUS_CHANNEL_FULL }, ui.tooltip.lines)
      ui:fire(button, "OnLeave")
      assert.is_false(ui.tooltip.shown)
    end)
  end)
end)
