-- The request dialog, the driver toast, the clicker offer and the portal alert
-- (UI/Dialogs.lua), on a real Engine over the simulated world and the strict
-- fake frame API. See tests/ui/boot.lua for the players.
local boot = dofile("tests/ui/boot.lua")

describe("dialogs", function()
  local t, ui, w, ns, Main

  local function start(viewer, opts)
    t = boot(viewer, opts)
    ui, w, ns, Main = t.ui, t.w, t.ns, t.Main
  end

  after_each(function()
    assert.are.same({}, w.errors) -- nothing any Engine logged, the windows' repaints included
  end)

  describe("the request dialog", function()
    before_each(function() start("me") end)

    -- Lock opens a stand; the Travel tab's Request opens the dialog.
    local function open()
      local stand = t.standOf(t.lock)
      Main:Show()
      ui:press("Request")
      return stand
    end

    it("opens from Request and sends nothing until Send, with no tip picked", function()
      local stand = open()
      local dialog = ui.env.TaxiRequestFrame
      assert.is_true(ui:visible(dialog))
      assert.are.equal("Request a ride", dialog.TitleText:GetText())
      assert.is_true(ui:shows("Summon from Dar Kbolt"))
      assert.is_true(ui:shows("Tanaris - Gadgetzan"))
      assert.is_true(ui:shows("Nothing is paid now."))
      assert.are.same({ false, true, true, true }, {
        ui:one{ kind = "Button", text = "No tip" }.enabled, ui:one{ kind = "Button", text = "50s" }.enabled,
        ui:one{ kind = "Button", text = "1g" }.enabled, ui:one{ kind = "Button", text = "Custom" }.enabled,
      }) -- the picked one is the disabled one
      assert.are.same({}, t.me.engine.rides)
      ui:press("Send")
      local ride = t.me.engine.rides["Tra Veler#" .. stand.standId]
      assert.are.equal(0, ride.offer)
      assert.is_false(ui:visible(dialog))
      assert.are.equal("Requested a seat from Dar Kbolt.", Main:statusText())
    end)

    it("sends the chosen preset, on the wire too: 50s and 1g", function()
      for _, case in ipairs({ { "50s", 5000 }, { "1g", 10000 } }) do
        start("me")
        local stand = open()
        ui:press(case[1])
        assert.is_false(ui:one{ kind = "Button", text = case[1] }.enabled)
        ui:press("Send")
        assert.are.equal(case[2], t.me.engine.rides["Tra Veler#" .. stand.standId].offer)
        w:advance(2)
        local sent = t.wireOf("REQUEST", "Tra Veler")
        assert.are.same({ case[2], "Dar Kbolt" }, { sent[1].offer, sent[1].to })
      end
    end)

    it("sends a custom amount from the gold and silver boxes", function()
      local stand = open()
      ui:press("Custom")
      local custom = ui.env.TaxiRequestFrame.picker.custom
      assert.is_true(ui:visible(custom))
      custom.gold:SetText("2")
      custom.silver:SetText("50")
      ui:press("Send")
      assert.are.equal(25000, t.me.engine.rides["Tra Veler#" .. stand.standId].offer)
    end)

    it("keeps the dialog open and says so when the custom amount is empty", function()
      local stand = open()
      ui:press("Custom")
      ui:press("Send")
      assert.is_true(ui:shows("That is not a valid tip."))
      assert.is_true(ui:visible(ui.env.TaxiRequestFrame))
      assert.is_nil(t.me.engine.rides["Tra Veler#" .. stand.standId])
      ui:press("No tip") -- a way out: ask without a tip after all
      ui:press("Send")
      assert.are.equal(0, t.me.engine.rides["Tra Veler#" .. stand.standId].offer)
    end)

    it("cancels without sending, and Esc closes it", function()
      open()
      ui:press("Cancel")
      assert.is_false(ui:visible(ui.env.TaxiRequestFrame))
      assert.are.same({}, t.me.engine.rides)
      assert.are.same({ "TaxiMainFrame", "TaxiRequestFrame" }, ui.env.UISpecialFrames)
    end)

    it("starts again from no tip for the next stand", function()
      open()
      ui:press("1g")
      ui:press("Cancel")
      ui:press("Request")
      assert.is_false(ui:one{ kind = "Button", text = "No tip" }.enabled)
    end)

    it("asks which portal for a mage's stand, then names it", function()
      local stand = t.standOf(t.mage, { kind = "mage" })
      Main:Show()
      ui:press("Portals")
      ui:press("Request")
      ui:click(ui:one{ kind = "FontString", text = "Ironforge" }.parent)
      assert.is_true(ui:shows("Portal to Ironforge from Mag Ic"))
      ui:press("50s")
      ui:press("Send")
      local ride = t.me.engine.rides["Tra Veler#" .. stand.standId]
      assert.are.same({ "portal", "ironforge", 5000 }, { ride.kind, ride.dest, ride.offer })
    end)

    it("says why the Engine refused and stays open", function()
      local stand = open()
      t.me.engine.board.stands[stand.standId] = nil -- it left the board a moment ago
      ui:press("Send")
      assert.is_true(ui:shows("That stand is no longer on the board."))
      assert.is_true(ui:visible(ui.env.TaxiRequestFrame))
    end)

    it("is refused for a dead Hardcore character, whether open or not", function()
      local stand = open()
      t.me.dead = true
      ui:press("Send")
      assert.is_true(ui:shows("Your Hardcore character has died."))
      assert.is_nil(t.me.engine.rides["Tra Veler#" .. stand.standId])
      ui:press("Cancel")
      ns.UI.Dialogs.request(ns.Board.get(t.me.engine.board, stand.standId), nil)
      assert.is_false(ui:visible(ui.env.TaxiRequestFrame))
      assert.are.equal("Your Hardcore character has died.", Main:statusText())
    end)

    it("shows a stand's name from the wire with its | doubled", function()
      local now = w.clock:now()
      local view = ns.Stand.fromFields({
        standId = "Evil|cff00ff00Name@1", kind = "lock", faction = "Alliance", mapID = 1446, wx = 0, wy = 0,
        zone = "Zone|r", subzone = "Sub|cffff0000", seatsFree = 2, clickers = 0, clickerPct = 25,
      }, "Evil|cff00ff00Name", now)
      ns.Board.upsert(t.me.engine.board, view, now)
      ns.UI.Dialogs.request(view, nil)
      assert.is_true(ui:shows("Summon from Evil||cff00ff00Name"))
      t.noRawPipes()
    end)
  end)

  describe("the driver toast", function()
    before_each(function() start("lock") end)

    -- The toast window if it is up (its title is the template's TitleText), else nil.
    local function shown()
      for _, f in ipairs(ui.frames) do
        if f.TitleText and f.TitleText:GetText() == "Ride request" and ui:visible(f) then
          return f
        end
      end
      return nil
    end

    -- Tra Veler asks Dar's stand for a ride, offering `offer`; the owner hears it.
    local function asks(stand, offer, who)
      who = who or t.me
      assert(who.engine:requestRide(stand.standId, offer))
      w:advance(2)
    end

    it("shows the traveler, level, guild and offer, with a sound", function()
      local stand = t.standOf(t.lock)
      assert.is_nil(shown())
      asks(stand, 10000)
      assert.is_not_nil(shown())
      assert.is_true(ui:shows("Tra Veler (level 44)"))
      assert.is_true(ui:shows("Guildmate · Wants a summon"))
      assert.is_true(ui:shows("Offers 1g"))
      assert.are.same({ 8960 }, ui.sounds) -- SOUNDKIT.READY_CHECK
    end)

    it("says no tip was offered, and does not call a stranger a guildmate", function()
      local stand = t.standOf(t.lock)
      asks(stand, 0, t.c1)
      assert.is_true(ui:shows("Cee One (level 40)"))
      assert.is_true(ui:shows("No tip offered"))
      assert.is_false(ui:shows("Guildmate"))
    end)

    it("Accept answers the request: the ride gets its id and the traveler an invite", function()
      local stand = t.standOf(t.lock)
      asks(stand, 5000)
      ui:press("Accept")
      local ride = t.lock.engine.rides["Tra Veler#" .. stand.standId]
      assert.are.equal("accepted", ride.state)
      assert.is_string(ride.rideId)
      assert.are.equal("Dar Kbolt", t.me.invitedBy)
      assert.is_nil(shown())
    end)

    it("Decline turns it down and the toast goes", function()
      local stand = t.standOf(t.lock)
      asks(stand, 0)
      ui:press("Decline")
      w:advance(2)
      assert.are.equal("declined", t.lock.engine.rides["Tra Veler#" .. stand.standId].state)
      assert.are.equal("declined", t.me.engine.rides["Tra Veler#" .. stand.standId].state)
      assert.is_nil(shown())
    end)

    it("takes the requests one at a time, oldest first, and counts the rest", function()
      local stand = t.standOf(t.lock)
      asks(stand, 0, t.me)
      w:advance(1)
      asks(stand, 0, t.c1)
      assert.is_true(ui:shows("Tra Veler (level 44)"))
      assert.is_false(ui:shows("Cee One (level 40)"))
      assert.is_true(ui:shows("1 more request is waiting"))
      assert.are.equal(2, #ui.sounds) -- each new request sounds once
      ui:press("Accept")
      assert.is_true(ui:shows("Cee One (level 40)"))
      assert.is_false(ui:shows("more request"))
      ui:press("Decline")
      assert.is_nil(shown())
      assert.are.equal(2, #ui.sounds)
    end)

    it("goes when the request is answered somewhere else, without waiting for a refresh", function()
      local stand = t.standOf(t.lock)
      asks(stand, 0)
      assert.is_not_nil(shown())
      assert.is_string(t.lock.engine:acceptRequest("Tra Veler#" .. stand.standId)) -- say, on the My stand tab
      assert.is_nil(shown())
    end)

    it("offers only Decline when there is no free seat", function()
      local stand = t.standOf(t.lock, { kind = "lock", seats = 1 })
      asks(stand, 0, t.me)
      ui:press("Accept")
      asks(stand, 0, t.c1)
      assert.is_true(ui:shows("Cee One (level 40)"))
      assert.is_true(ui:shows("No free seat"))
      assert.are.same({}, ui:find{ kind = "Button", text = "Accept", within = shown() })
      assert.is_true(ui:one{ kind = "Button", text = "Decline", within = shown() }.enabled)
    end)

    it("offers Convert to raid & invite when the group would pass five, and accepts when the raid is there", function()
      local names = { "Ann One", "Bea Two", "Cal Three", "Dee Four", "Eli Five" }
      local travelers = {}
      for i, name in ipairs(names) do
        travelers[i] = w:addPlayer{ name = name, class = "MAGE", level = 30, place = "ironforge" }
      end
      local stand = t.standOf(t.lock, { kind = "lock", seats = 37 })
      for _, p in ipairs(travelers) do
        assert(p.engine:requestRide(stand.standId, 0))
      end
      w:advance(2)
      for i = 1, 4 do
        assert.is_string(t.lock.engine:acceptRequest(names[i] .. "#" .. stand.standId))
        w:advance(1)
        assert.is_true(w:acceptInvite(names[i]))
        w:advance(1)
      end
      assert.is_true(ui:shows("Eli Five (level 30)"))
      assert.are.same({}, ui:find{ kind = "Button", text = "Accept", within = shown() }) -- the fifth would make 6
      ui:press("Convert to raid & invite", shown())
      assert.is_not_nil(t.lock.engine.raidPending)
      assert.is_true(ui:shows("Converting the group to a raid..."))
      assert.are.same({}, ui:find{ kind = "Button", text = "Convert to raid & invite" })
      w:advance(1) -- the game makes the raid; the accept follows
      assert.are.equal("accepted", t.lock.engine.rides["Eli Five#" .. stand.standId].state)
      assert.is_nil(shown())
    end)

    it("says what the Engine said when it refuses, and keeps the request", function()
      local stand = t.standOf(t.lock)
      asks(stand, 0)
      local key = "Tra Veler#" .. stand.standId
      t.lock.engine.acceptRequest = function() return nil, "full" end
      ui:press("Accept")
      assert.is_true(ui:shows("There is no free seat."))
      assert.are.equal("requested", t.lock.engine.rides[key].state)
      assert.is_not_nil(shown())
    end)

    it("leaves a request to the My stand tab after a minute, or when the player closes it", function()
      local late = w:addPlayer{ name = "Lat Er", class = "MAGE", level = 30, place = "ironforge" }
      local stand = t.standOf(t.lock)
      asks(stand, 0, t.me)
      asks(stand, 0, t.c1)
      ui:click(shown().CloseButton) -- the player's X: this request only
      assert.is_true(ui:shows("Cee One (level 40)")) -- the next one is up at once
      assert.is_false(ui:shows("Tra Veler (level 44)"))
      w:advance(61)
      ui:update(0.6)
      assert.is_nil(shown()) -- timed out; both are still waiting
      assert.are.same({ "requested", "requested" }, {
        t.lock.engine.rides["Tra Veler#" .. stand.standId].state, t.lock.engine.rides["Cee One#" .. stand.standId].state })
      Main:Show("stand")
      assert.is_true(ui:shows("Tra Veler (level 44)"))
      assert.is_true(ui:shows("Cee One (level 40)"))
      -- A new request still gets its toast.
      asks(stand, 0, late)
      assert.is_not_nil(shown())
      assert.is_true(ui:shows("Lat Er (level 30)"))
    end)

    it("turns Accept and Decline off for a dead Hardcore character", function()
      local stand = t.standOf(t.lock)
      asks(stand, 0)
      t.lock.dead = true
      ui:update(0.6)
      assert.is_false(ui:one{ kind = "Button", text = "Accept", within = shown() }.enabled)
      assert.is_false(ui:one{ kind = "Button", text = "Decline", within = shown() }.enabled)
      assert.is_false(ui:press("Accept", shown()))
      assert.are.equal("requested", t.lock.engine.rides["Tra Veler#" .. stand.standId].state)
    end)

    it("shows a name from the wire with its | doubled and no control characters", function()
      t.standOf(t.lock)
      local stand = t.lock.engine.stand
      t.hear(t.lock, "Evil|cff00ff00Name", "REQUEST", { standId = stand.standId, offer = 0, level = 30 })
      assert.is_true(ui:shows("Evil||cff00ff00Name (level 30)"))
      t.noRawPipes()
    end)

    it("shows in combat: it is not part of the protected main window", function()
      local stand = t.standOf(t.lock)
      Main:Show("stand")
      ui.combat = true
      asks(stand, 0)
      assert.is_not_nil(shown())
      ui:press("Accept", shown())
      assert.are.equal("accepted", t.lock.engine.rides["Tra Veler#" .. stand.standId].state)
    end)
  end)

  describe("the clicker offer", function()
    before_each(function() start("lock") end)

    local function offerWindow()
      for _, f in ipairs(ui.frames) do
        if f.TitleText and f.TitleText:GetText() == "Clicker offer" and ui:visible(f) then
          return f
        end
      end
      return nil
    end

    local function applies(who, pct, stand)
      assert(who.engine:applyClicker(stand.standId, pct))
      w:advance(2)
    end

    it("shows the share asked and the share offered", function()
      local stand = t.standOf(t.lock)
      applies(t.c1, 30, stand)
      assert.is_not_nil(offerWindow())
      assert.is_true(ui:shows("Cee One asks for 30%"))
      assert.is_true(ui:shows("You offered 25%"))
      assert.are.equal("25", offerWindow().counter:GetText())
    end)

    it("Accept seats the clicker at the share asked", function()
      local stand = t.standOf(t.lock)
      applies(t.c1, 30, stand)
      ui:press("Accept", offerWindow())
      assert.are.equal(30, stand.clickers["Cee One"].pct)
      assert.is_nil(offerWindow())
    end)

    it("Counter sends the share in the box", function()
      local stand = t.standOf(t.lock)
      applies(t.c1, 40, stand)
      offerWindow().counter:SetText("20")
      ui:press("Counter", offerWindow())
      assert.are.same({ "countered", 20 }, { stand.talks["Cee One"].state, stand.talks["Cee One"].pct })
      assert.is_nil(offerWindow())
      w:advance(2)
      assert.are.equal(20, t.c1.engine.application.pct)
    end)

    it("says why a counter was refused and stays open", function()
      local stand = t.standOf(t.lock)
      applies(t.c1, 40, stand)
      offerWindow().counter:SetText("0")
      ui:press("Counter", offerWindow())
      assert.is_true(ui:shows("A share must be a whole number of percent."))
      assert.are.equal("asked", stand.talks["Cee One"].state)
      assert.is_not_nil(offerWindow())
    end)

    it("Decline turns the application down", function()
      local stand = t.standOf(t.lock)
      applies(t.c1, 30, stand)
      ui:press("Decline", offerWindow())
      w:advance(2)
      assert.is_nil(stand.talks["Cee One"])
      assert.is_nil(offerWindow())
      assert.is_nil(t.c1.engine.application)
    end)

    it("takes the applications one at a time", function()
      local stand = t.standOf(t.lock)
      applies(t.c1, 30, stand)
      applies(t.c2, 35, stand)
      assert.is_true(ui:shows("Cee One asks for 30%"))
      ui:press("Decline", offerWindow())
      assert.is_true(ui:shows("Cee Two asks for 35%"))
    end)

    it("goes when the talk is answered on the My stand tab, at once", function()
      local stand = t.standOf(t.lock)
      applies(t.c1, 30, stand)
      Main:Show("stand")
      assert.is_not_nil(offerWindow())
      ui:press("Decline", Main.views.stand.frame)
      assert.is_nil(offerWindow())
      applies(t.c2, 30, stand)
      assert.is_not_nil(offerWindow())
      ui:update(0.02) -- the tab repaints on the next frame
      ui:press("Accept", Main.views.stand.frame)
      assert.is_nil(offerWindow())
      assert.are.equal(30, stand.clickers["Cee Two"].pct)
    end)

    it("turns its buttons off for a dead Hardcore character", function()
      local stand = t.standOf(t.lock)
      applies(t.c1, 30, stand)
      t.lock.dead = true
      ui:update(0.6)
      assert.is_false(ui:one{ kind = "Button", text = "Accept", within = offerWindow() }.enabled)
      assert.is_false(ui:one{ kind = "Button", text = "Counter", within = offerWindow() }.enabled)
      assert.is_false(ui:one{ kind = "Button", text = "Decline", within = offerWindow() }.enabled)
    end)
  end)

  describe("the clicker's side of the haggling", function()
    before_each(function() start("c1") end)

    local function offerWindow()
      for _, f in ipairs(ui.frames) do
        if f.TitleText and f.TitleText:GetText() == "Counter-offer" and ui:visible(f) then
          return f
        end
      end
      return nil
    end

    it("shows the owner's counter-offer to take", function()
      local stand = t.standOf(t.lock)
      assert.is_true(t.c1.engine:applyClicker(stand.standId, 40))
      w:advance(2)
      assert.is_nil(offerWindow())
      assert.is_true(t.lock.engine:respondClicker("Cee One", "COUNTER", 20))
      w:advance(2)
      assert.is_true(ui:shows("Dar Kbolt offers 20% instead (you asked 40%)."))
      assert.are.same({}, ui:find{ kind = "Button", text = "Counter" })
      ui:press("Take it", offerWindow())
      w:advance(2)
      assert.is_true(w:acceptInvite("Cee One"))
      w:advance(1)
      assert.are.equal(20, t.c1.engine.shift.pct)
      assert.is_nil(offerWindow())
    end)

    it("can be turned down", function()
      local stand = t.standOf(t.lock)
      assert.is_true(t.c1.engine:applyClicker(stand.standId, 40))
      w:advance(2)
      assert.is_true(t.lock.engine:respondClicker("Cee One", "COUNTER", 20))
      w:advance(2)
      ui:press("Decline", offerWindow())
      assert.is_nil(t.c1.engine.application)
      assert.is_nil(offerWindow())
    end)
  end)

  describe("the portal alert", function()
    before_each(function() start("me") end)

    it("says the portal is up, with a sound, and goes after a few seconds", function()
      t.me.engine:emit("PORTAL_UP", "ironforge")
      assert.is_true(ui:shows("Portal to Ironforge is up - click it!"))
      assert.are.same({ 8959 }, ui.sounds) -- SOUNDKIT.RAID_WARNING
      ui:update(3)
      assert.is_true(ui:shows("Portal to Ironforge is up - click it!"))
      ui:update(4)
      assert.is_false(ui:shows("is up"))
    end)

    it("says it without a destination when a stand's portal is up (a clicker's alert)", function()
      t.me.engine:emit("PORTAL_UP", nil)
      assert.is_true(ui:shows("Portal is up - click it!"))
    end)
  end)
end)
