local _, ns = ...

-- The My stand tab. With no stand open it is the form (warlock or mage, seats,
-- the share offered to each clicker, a note, Open). With a stand open it is the
-- stand's header (status, seats, Close, the secure Summon next / Open portal
-- button, adding crew by hand) over one list of what needs the owner: requests
-- and riders, clicker applications, crew and payouts.
--
-- The secure button casts the ritual or the portal spell on a click, which
-- only the game may do (it is a SecureActionButtonTemplate). Its attributes
-- name the spell and, for a summon, the unit token of the traveler
-- Engine:nextRide names; they are set from here only out of combat. In combat
-- the button keeps what it had (text included, so it never says one thing and
-- does another) and the end of combat repaints the window.
local L, Config, Names, Stand, Money, Util = ns.L, ns.Config, ns.Names, ns.Stand, ns.Money, ns.Util
local UI = ns.UI
local W = UI.Widgets

local M = {}
UI.MyStand = M

local WIDTH = 576
local HEAD_HEIGHT = 112
local ROWS = 5

local WAITING = { requested = true }
local RIDING = { accepted = true, grouped = true, summoning = true, portal = true }

-- My rides as a driver on this stand that are in one of `states`, oldest first.
local function ridesOf(engine, stand, states)
  local out = {}
  for _, ride in pairs(engine.rides) do
    if ride.standId == stand.standId and Names.same(ride.driver, engine.me) and states[ride.state] then
      out[#out + 1] = ride
    end
  end
  table.sort(out, function(a, b)
    if a.times.requested ~= b.times.requested then
      return a.times.requested < b.times.requested
    end
    return a.traveler < b.traveler
  end)
  return out
end

local function sortedKeys(t)
  local keys = {}
  for key in pairs(t or {}) do
    keys[#keys + 1] = key
  end
  table.sort(keys)
  return keys
end

function M.new(parent, main)
  local view = { kind = "lock", showingHead = false }

  -- The form of a stand that is not open ------------------------------------------------

  local form = CreateFrame("Frame", nil, parent)
  form:SetSize(WIDTH, HEAD_HEIGHT)
  form:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
  view.form = form

  local function label(text, x, y)
    local fs = W.text(form, "GameFontNormalSmall")
    fs:SetPoint("TOPLEFT", form, "TOPLEFT", x, y)
    fs:SetText(text)
    return fs
  end

  form.lock = W.button(form, L.KIND_LOCK, 150, function()
    view:SetKind("lock")
  end)
  form.lock:SetPoint("TOPLEFT", form, "TOPLEFT", 0, 0)
  form.mage = W.button(form, L.KIND_MAGE, 150, function()
    view:SetKind("mage")
  end)
  form.mage:SetPoint("LEFT", form.lock, "RIGHT", 4, 0)
  label(L.FORM_SEATS, 0, -37)
  form.seats = W.editBox(form, 40, { numeric = true, maxLetters = 2 })
  form.seats:SetPoint("TOPLEFT", form, "TOPLEFT", 110, -33)
  form.shareLabel = label(L.FORM_SHARE, 180, -37)
  form.share = W.editBox(form, 40, { numeric = true, maxLetters = 2 })
  form.share:SetPoint("TOPLEFT", form, "TOPLEFT", 290, -33)
  label(L.FORM_NOTE, 0, -65)
  form.note = W.editBox(form, 400, { maxLetters = 100 })
  form.note:SetPoint("TOPLEFT", form, "TOPLEFT", 110, -61)
  form.open = W.button(form, L.STAND_OPEN, 140, function()
    view:OpenStand()
  end)
  form.open:SetPoint("TOPLEFT", form, "TOPLEFT", 0, -88)

  -- The header of an open stand ---------------------------------------------------------------

  local head = CreateFrame("Frame", nil, parent)
  head:SetSize(WIDTH, HEAD_HEIGHT)
  head:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
  head:Hide()
  view.head = head

  head.title = W.text(head, "GameFontNormal")
  head.title:SetPoint("TOPLEFT", head, "TOPLEFT", 0, 0)
  head.title:SetWidth(400)
  head.state = W.text(head, "GameFontNormal", "RIGHT")
  head.state:SetPoint("TOPRIGHT", head, "TOPRIGHT", -22, 0)
  head.state:SetWidth(170)
  head.info = W.text(head, "GameFontHighlightSmall")
  head.info:SetPoint("TOPLEFT", head, "TOPLEFT", 0, -22)
  head.info:SetWidth(WIDTH - 24)

  -- Summon next / Open portal. Casting is the game's: the click runs the spell
  -- named by the attributes (see the top of the file); PostClick only tells the
  -- group (PORTAL_UP), because the click was the player's own. The button hears
  -- the press and the release and acts on one of them (on the release, as the
  -- attribute asks; on the press if the game's key-down setting wins), so the
  -- group is told on the release only, once per click.
  head.secure = CreateFrame("Button", nil, head, "SecureActionButtonTemplate,UIPanelButtonTemplate")
  head.secure:SetSize(230, 28)
  head.secure:SetPoint("TOPLEFT", head, "TOPLEFT", 0, -42)
  head.secure:RegisterForClicks("AnyUp", "AnyDown")
  head.secure:SetAttribute("useOnKeyDown", false)
  head.secure:HookScript("PostClick", function(button, _, down)
    if not down and button:GetAttribute("type") ~= nil then
      ns.engine:nextTraveler()
      main:Invalidate()
    end
  end)
  head.close = W.button(head, L.STAND_CLOSE, 120, function()
    main:report(ns.engine:closeStand(), "no_stand", L.NOTICE_STAND_CLOSED)
  end)
  head.close:SetPoint("TOPLEFT", head, "TOPLEFT", 238, -42) -- not anchored to the protected button
  head.waiting = W.text(head, "GameFontHighlightSmall")
  head.waiting:SetPoint("TOPLEFT", head, "TOPLEFT", 368, -50)
  head.waiting:SetWidth(WIDTH - 368)
  W.paint(head.waiting, W.COLOR.gray)

  head.crew = CreateFrame("Frame", nil, head)
  head.crew:SetSize(WIDTH, 24)
  head.crew:SetPoint("TOPLEFT", head, "TOPLEFT", 0, -80)
  local crewLabel = W.text(head.crew, "GameFontNormalSmall")
  crewLabel:SetPoint("LEFT", head.crew, "LEFT", 0, 0)
  crewLabel:SetText(L.CREW_ADD_NAME)
  head.crewName = W.editBox(head.crew, 150, { maxLetters = 40 })
  head.crewName:SetPoint("LEFT", head.crew, "LEFT", 100, 0)
  head.crewPct = W.editBox(head.crew, 34, { numeric = true, maxLetters = 2 })
  head.crewPct:SetPoint("LEFT", head.crewName, "RIGHT", 10, 0)
  local pctLabel = W.text(head.crew, "GameFontNormalSmall")
  pctLabel:SetPoint("LEFT", head.crewPct, "RIGHT", 4, 0)
  pctLabel:SetText(L.CREW_ADD_PCT)
  head.crewAdd = W.button(head.crew, L.CREW_ADD, 60, function()
    local ok, why = ns.engine:addOwnCrew(Util.trim(head.crewName:GetText()), head.crewPct:GetNumber())
    if main:report(ok, why) then
      head.crewName:SetText("")
    end
  end)
  head.crewAdd:SetPoint("LEFT", head.crewPct, "RIGHT", 28, 0)

  -- The list -----------------------------------------------------------------------------------

  view.list = W.list(parent, { width = WIDTH, rows = ROWS, buttons = 2 })
  view.list.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(HEAD_HEIGHT + 4))
  view.hint = W.text(parent, "GameFontHighlight", "CENTER")
  view.hint:SetPoint("CENTER", view.list.frame, "CENTER", -10, 0)
  view.hint:SetWidth(WIDTH - 80)

  -- Actions ------------------------------------------------------------------------------------

  function view:SetKind(kind)
    self.kind = kind == "mage" and "mage" or "lock"
    main:Refresh()
  end

  function view:OpenStand()
    local note = Util.trim(form.note:GetText())
    local stand, why = ns.engine:openStand{
      kind = self.kind,
      seats = form.seats:GetNumber(),
      clickerPct = self.kind == "lock" and form.share:GetNumber() or nil,
      note = note ~= "" and note or nil,
    }
    main:report(stand, why, L.NOTICE_STAND_OPEN)
  end

  -- Painting ---------------------------------------------------------------------------------------

  -- The form starts from what the last stand used.
  function view:FillForm(engine)
    if self.filled then
      return
    end
    self.filled = true
    local saved = engine.charDb.stand or {}
    form.seats:SetText(tostring(saved.seats or Config.DEFAULT_SEATS))
    form.share:SetText(tostring(saved.clickerPct or Config.DEFAULT_CLICKER_PCT))
    form.note:SetText(saved.note or "")
    self.kind = engine.game:class() == "MAGE" and "mage" or "lock"
  end

  -- Aims the secure button at the next traveler (a summon) or the next portal.
  local function aim(engine, stand, actions)
    local spell, unit, text
    local ride = actions and engine:nextRide() or nil
    if ride ~= nil then
      if stand.kind == "lock" then
        unit = engine.game:unitFor(ride.traveler)
        if unit ~= nil then
          spell, text = Config.RITUAL_SPELL, L.fmt("SUMMON_NAME", ride.traveler)
        end
      else
        for _, portal in ipairs(Config.PORTALS) do
          if portal.key == ride.dest then
            spell, text = portal.spellId, L.fmt("PORTAL_OPEN", W.portalName(ride.dest))
          end
        end
      end
    end
    if InCombatLockdown() then
      return
    end
    local button = head.secure
    W.setText(button, text or (stand.kind == "lock" and L.SUMMON_NEXT or L.PORTAL_NEXT))
    button:SetAttribute("type", spell and "spell" or nil)
    button:SetAttribute("spell", spell)
    button:SetAttribute("unit", unit)
    button:SetEnabled(spell ~= nil)
    W.setText(head.waiting, spell == nil and L.NOBODY_WAITING or "")
  end

  function view:PaintHead(engine, stand, actions)
    local lock = stand.kind == "lock"
    W.setText(head.title, L.fmt(lock and "STAND_TITLE_LOCK" or "STAND_TITLE_MAGE", W.place(stand)))
    local status = Stand.status(stand)
    local text = status == "live" and L.STAND_LIVE or status == "paused" and L.STAND_PAUSED or L.STAND_RECRUITING
    if stand.flags.combat then
      text = text .. " (" .. L.STAND_FLAG_COMBAT .. ")"
    elseif stand.flags.noShards then
      text = text .. " (" .. L.STAND_FLAG_SHARDS .. ")"
    end
    W.setText(head.state, text)
    W.paint(head.state, status == "live" and W.COLOR.green or status == "paused" and W.COLOR.red or W.COLOR.gold)
    if lock then
      W.setText(head.info, L.fmt("STAND_INFO_LOCK", stand.seats, Stand.seatsFree(stand), Stand.clickerCount(stand),
        stand.clickerPct))
    else
      W.setText(head.info, L.fmt("STAND_INFO_MAGE", stand.seats, Stand.seatsFree(stand),
        L.fmt("PORTALS_TO", W.portalNames(stand.portals))))
    end
    head.close:SetEnabled(actions)
    head.crew:SetShown(lock)
    head.crewAdd:SetEnabled(actions)
    if self.crewFor ~= stand.standId then
      self.crewFor = stand.standId
      head.crewPct:SetText(tostring(stand.clickerPct))
    end
    aim(engine, stand, actions)
  end

  function view:PaintForm(actions)
    local mage = self.kind == "mage"
    form.lock:SetEnabled(mage)
    form.mage:SetEnabled(not mage)
    form.shareLabel:SetShown(not mage)
    form.share:SetShown(not mage)
    form.open:SetEnabled(actions)
  end

  -- One request waiting for an answer.
  local function requestRow(engine, stand, ride, actions)
    local key = ride.key
    local converting = false
    for _, queued in ipairs(engine.raidPending or {}) do
      converting = converting or queued == key
    end
    local spec = {
      title = type(ride.level) == "number" and L.fmt("REQUEST_ROW", ride.traveler, ride.level) or ride.traveler,
      sub = (ride.offer or 0) > 0 and L.fmt("REQUEST_OFFER", Money.format(ride.offer)) or L.REQUEST_NO_OFFER,
      right = ride.kind == "portal" and W.portalName(ride.dest) or nil,
    }
    local decline = {
      text = L.DECLINE, width = 70, enabled = actions,
      onClick = function()
        main:report(engine:declineRequest(key))
      end,
    }
    local accept
    if Stand.seatsFree(stand) == 0 then
      spec.sub2 = L.REQUEST_NO_SEAT
    elseif converting then
      spec.sub2 = L.REQUEST_CONVERTING
    elseif Stand.needsRaid(stand, 1) and not engine.game:isRaid() then
      accept = {
        text = L.CONVERT, width = 150, enabled = actions,
        onClick = function()
          local result, why = engine:convertAndAccept(key)
          if result == nil then
            main:notify(main:explain(why))
          elseif result == true then
            main:notify(L.NOTICE_CONVERTING) -- the accept follows when the game has made the raid
          end
          main:Refresh()
        end,
      }
    else
      accept = {
        text = L.ACCEPT, width = 70, enabled = actions,
        onClick = function()
          main:report(engine:acceptRequest(key))
        end,
      }
    end
    spec.buttons = accept and { decline, accept } or { decline }
    return spec
  end

  -- One open talk with a clicker who wants to join.
  local function applicationRow(engine, stand, neg, actions)
    local decline = {
      text = L.DECLINE, width = 70, enabled = actions,
      onClick = function()
        main:report(engine:respondClicker(neg.clicker, "DECLINE"))
      end,
    }
    if neg.state == "asked" then
      return {
        title = L.fmt("APP_ASKS", neg.clicker, neg.askedPct),
        sub = L.fmt("APP_ASKED", neg.offeredPct or stand.clickerPct),
        buttons = {
          decline,
          {
            text = L.ACCEPT, width = 70, enabled = actions,
            onClick = function()
              main:report(engine:respondClicker(neg.clicker, "ACCEPT"))
            end,
          },
        },
      }
    end
    return { title = neg.clicker, sub = L.fmt("APP_COUNTERED", neg.pct), buttons = { decline } }
  end

  local function rows(engine, stand, actions)
    local specs = {}
    local function header(text)
      specs[#specs + 1] = { header = true, title = text }
    end
    if stand ~= nil then
      local waiting, riding = ridesOf(engine, stand, WAITING), ridesOf(engine, stand, RIDING)
      if #waiting + #riding > 0 then
        header(L.SEC_REQUESTS)
      end
      for _, ride in ipairs(waiting) do
        specs[#specs + 1] = requestRow(engine, stand, ride, actions)
      end
      for _, ride in ipairs(riding) do
        local spec = {
          title = ride.traveler,
          sub = rawget(L, "RIDER_" .. ride.state),
          right = ride.kind == "portal" and W.portalName(ride.dest) or nil,
        }
        if ride.state == "accepted" then
          -- Accepted but not in the group yet: the invite may have been lost
          -- or turned down (Engine.reinvite starts the wait for him over).
          local key, traveler = ride.key, ride.traveler
          spec.buttons = {
            {
              text = L.REINVITE, width = 80, enabled = actions,
              onClick = function()
                local ok, why = engine:reinvite(key)
                main:report(ok, why, L.fmt("NOTICE_REINVITED", tostring(traveler)))
              end,
            },
          }
        end
        specs[#specs + 1] = spec
      end

      local talks = sortedKeys(stand.talks)
      if #talks > 0 then
        header(L.SEC_APPLICATIONS)
      end
      for _, name in ipairs(talks) do
        specs[#specs + 1] = applicationRow(engine, stand, stand.talks[name], actions)
      end

      local crew = sortedKeys(stand.clickers)
      if #crew > 0 then
        header(L.SEC_CREW)
      end
      for _, name in ipairs(crew) do
        specs[#specs + 1] = {
          title = name,
          right = L.fmt("CREW_PCT", stand.clickers[name].pct),
          buttons = {
            {
              text = L.DISMISS, width = 80, enabled = actions,
              onClick = function()
                main:report(engine:dismissClicker(name))
              end,
            },
          },
        }
      end
    end

    local payouts = engine:payoutList()
    if #payouts > 0 then
      header(L.SEC_PAYOUTS)
    end
    for _, payout in ipairs(payouts) do
      local owed, received = payout.owed or 0, payout.received or 0
      specs[#specs + 1] = {
        title = payout.clicker,
        sub = L.fmt("PAYOUT_LINE", Money.format(owed), Money.format(received)),
        buttons = {
          {
            text = L.PAY, width = 70, enabled = actions and owed > received,
            onClick = function()
              main:report(engine:payClicker(payout.clicker))
            end,
          },
        },
      }
    end
    return specs
  end

  function view:Refresh()
    local engine = ns.engine
    local stand = engine.stand
    local actions = main:actionsEnabled()
    self:FillForm(engine)
    -- The form and the header swap only out of combat (the header holds the
    -- secure button, see MainWindow); until then the old one stays up.
    if (stand ~= nil) ~= self.showingHead and not InCombatLockdown() then
      self.showingHead = stand ~= nil
      head:SetShown(self.showingHead)
      form:SetShown(not self.showingHead)
    end
    if not self.showingHead then
      self:PaintForm(actions)
    elseif stand ~= nil then
      self:PaintHead(engine, stand, actions)
    end
    local specs = rows(engine, stand, actions)
    self.list:SetRows(specs)
    W.setText(self.hint, #specs == 0 and stand ~= nil and L.STAND_EMPTY or "")
  end

  return view
end
