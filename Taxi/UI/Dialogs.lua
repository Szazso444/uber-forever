local _, ns = ...

-- The small windows a driver and a traveler answer:
--   the request dialog   a traveler asks a stand for a ride and may offer a tip
--                        (none / 50s / 1g / custom); Send is the Engine's requestRide;
--   the driver toast     a request came in: name, level, guild, offer, and Accept /
--                        Decline, or "Convert to raid & invite" when the group would
--                        pass five, with a sound;
--   the clicker offer    a clicker asks my stand for a share: the share I offered,
--                        the share asked, Accept / Counter (a % box) / Decline; and,
--                        on the clicker's side, the owner's counter-offer to take or
--                        refuse;
--   the portal alert     "Portal is up - click it!", with a sound.
--
-- They only call Engine methods and listen to Engine events. The toast and the
-- offer are views over the Engine's own state (the requests waiting on my open
-- stand, its open talks, my countered application): they work it out again on
-- every event and every half second, so a request answered anywhere else (the
-- My stand tab, the traveler giving up) takes its toast away. A toast shows for
-- TOAST_SECONDS and then leaves the request to the My stand tab; closing it
-- does the same. They are free-standing windows (Widgets.window), never part
-- of the main window, so they show in combat too.
--
-- M.attach(engine, opts) gives one engine its toast, offer and alert; the
-- engine is the real one, or a player of /taxi sim (opts: see Widgets.link).
local L, Money, Names, Stand = ns.L, ns.Money, ns.Names, ns.Stand
local UI = ns.UI
local W = UI.Widgets

local M = {}
UI.Dialogs = M

local TOAST_SECONDS = 60 -- how long a request keeps its toast
local POLL_SECONDS = 0.5 -- how often an open toast or offer checks the Engine's state
local ALERT_SECONDS = 6

local function explain(why)
  return UI.Main.explain(nil, why)
end

local function sound(name)
  local kit = SOUNDKIT and SOUNDKIT[name]
  if kit and PlaySound then
    pcall(PlaySound, kit)
  end
end

-- A table whose keys (rides, talks) don't keep them alive.
local function weak()
  return setmetatable({}, { __mode = "k" })
end

-- The request dialog -----------------------------------------------------------------

local request -- the one dialog, built on first use

-- Send: the request goes out with the chosen offer. A refusal stays on the
-- dialog, in words, so the player can fix it (a custom tip left empty) or cancel.
local function send()
  local f, engine = request, ns.engine
  if f == nil or engine == nil then
    return
  end
  local valid, offer = f.picker:Read()
  if not valid then
    W.say(f.msg, explain("bad_offer"), W.COLOR.red)
    return
  end
  local ride, why = engine:requestRide(f.standId, offer or 0, f.dest)
  if ride then
    f:Hide()
    UI.Main:report(ride, nil, L.fmt("NOTICE_REQUESTED", tostring(f.owner)))
  else
    W.say(f.msg, explain(why), W.COLOR.red)
  end
end

local function buildRequest()
  local f = W.window{ name = "TaxiRequestFrame", width = 360, height = 252, title = L.REQ_TITLE, y = 60 }
  f.who = W.text(f, "GameFontNormal")
  f.who:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -36)
  f.who:SetWidth(328)
  f.where = W.text(f, "GameFontHighlightSmall")
  f.where:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -56)
  f.where:SetWidth(328)
  local label = W.text(f, "GameFontNormalSmall")
  label:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -86)
  label:SetText(L.REQ_TIP)
  f.picker = W.tipPicker(f)
  f.picker:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -104)
  f.hint = W.text(f, "GameFontHighlightSmall")
  f.hint:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -166)
  f.hint:SetWidth(328)
  f.hint:SetWordWrap(true)
  W.paint(f.hint, W.COLOR.gray)
  f.hint:SetText(L.REQ_HINT)
  f.msg = W.text(f, "GameFontHighlightSmall")
  f.msg:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -196)
  f.msg:SetWidth(328)
  f.send = W.button(f, L.REQ_SEND, 100, send)
  f.send:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
  f.cancel = W.button(f, L.CANCEL, 100, function()
    f:Hide()
  end)
  f.cancel:SetPoint("RIGHT", f.send, "LEFT", -8, 0)
  if UISpecialFrames then
    table.insert(UISpecialFrames, "TaxiRequestFrame") -- Esc closes it (expected; verify in game)
  end
  return f
end

-- Opens the request dialog for the stand `view` (a Board view); dest is the
-- portal asked of a mage's stand. Nothing is sent until Send.
function M.request(view, dest)
  local main = UI.Main
  if ns.engine == nil then
    return
  end
  if main.dead() then
    main:notify(explain("dead"))
    return
  end
  request = request or buildRequest()
  local f = request
  f.standId, f.owner, f.dest = view.standId, view.owner, dest
  W.setText(f.who, dest ~= nil and view.kind == "mage" and L.fmt("REQ_PORTAL", W.portalName(dest), tostring(view.owner))
    or L.fmt("REQ_SUMMON", tostring(view.owner)))
  W.setText(f.where, W.place(view))
  f.picker:SetOffer(nil)
  W.setText(f.msg, "")
  f.send:SetEnabled(main.actionsEnabled())
  f:Show()
end

-- Takes the request dialog away (the sim starting or stopping changes whose engine it would ask).
function M.closeRequest()
  if request then
    request:Hide()
  end
end

-- The driver toast ---------------------------------------------------------------------

-- The requests waiting on my open stand, oldest first.
local function pendingRequests(engine)
  local stand, out = engine.stand, {}
  if stand ~= nil then
    for _, ride in pairs(engine.rides) do
      if ride.state == "requested" and ride.standId == stand.standId and Names.same(ride.driver, engine.me) then
        out[#out + 1] = ride
      end
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

-- What the owner can do with a waiting request: "accept", "convert" (the group
-- would pass five: Convert to raid & invite), "converting" (that is under way)
-- or "full" (no free seat).
local function answerFor(engine, stand, ride)
  if Stand.seatsFree(stand) == 0 then
    return "full"
  end
  for _, key in ipairs(engine.raidPending or {}) do
    if key == ride.key then
      return "converting"
    end
  end
  if Stand.needsRaid(stand, 1) and not engine.game:isRaid() then
    return "convert"
  end
  return "accept"
end

local function buildToast(t, link)
  local f = W.window{
    width = 340, height = 178, title = L.TOAST_TITLE, label = link.label, slot = link.slot, point = "TOP", y = -120,
  }
  f.who = W.text(f, "GameFontNormal")
  f.who:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -36)
  f.who:SetWidth(308)
  f.what = W.text(f, "GameFontHighlightSmall")
  f.what:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -58)
  f.what:SetWidth(308)
  f.offer = W.text(f, "GameFontHighlightSmall")
  f.offer:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -76)
  f.offer:SetWidth(308)
  f.msg = W.text(f, "GameFontHighlightSmall")
  f.msg:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -98)
  f.msg:SetWidth(308)
  f.more = W.text(f, "GameFontHighlightSmall")
  f.more:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -116)
  f.more:SetWidth(308)
  W.paint(f.more, W.COLOR.gray)
  f.accept = W.button(f, L.ACCEPT, 100, nil)
  f.accept:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
  f.decline = W.button(f, L.DECLINE, 90, nil)
  f.decline:SetPoint("RIGHT", f.accept, "LEFT", -8, 0)
  -- The X: this request stays with the My stand tab and the next one comes up.
  -- (Not OnHide, which also fires when the screen's UI is hidden.)
  if f.CloseButton then
    f.CloseButton:HookScript("OnClick", function()
      if t.current then
        t.dismissed[t.current] = true
        t.current = nil
      end
      t:Refresh()
    end)
  end
  f:SetScript("OnUpdate", function(_, elapsed)
    t.elapsed = (t.elapsed or 0) + elapsed
    if t.elapsed >= POLL_SECONDS then
      t.elapsed = 0
      link.engine:safely("toast", t.Refresh, t)
    end
  end)
  return f
end

local function newToast(link)
  local t = { firstSeen = weak(), dismissed = weak() }

  function t:Close()
    self.current = nil
    if self.frame then
      self.frame:Hide()
    end
  end

  -- Accept, Decline or Convert on the request on show; what the Engine says is kept as the note.
  function t:Answer(ride, method)
    local engine = link.engine
    local result, why = engine[method](engine, ride.key)
    self.note = result == nil and { ride = ride, text = explain(why) } or nil
    self:Refresh()
  end

  function t:Paint(engine, stand, ride, more)
    local f = self.frame
    W.setText(f.who, type(ride.level) == "number" and L.fmt("REQUEST_ROW", ride.traveler, ride.level) or ride.traveler)
    local what = ride.kind == "portal" and L.fmt("TOAST_PORTAL", W.portalName(ride.dest)) or L.TOAST_SUMMON
    if engine.game:isGuildmate(ride.traveler) then
      what = L.TOAST_GUILD .. " · " .. what
    end
    W.setText(f.what, what)
    W.setText(f.offer, (ride.offer or 0) > 0 and L.fmt("REQUEST_OFFER", Money.format(ride.offer)) or L.REQUEST_NO_OFFER)
    W.setText(f.more, more == 0 and "" or more == 1 and L.TOAST_MORE_ONE or L.fmt("TOAST_MORE_MANY", more))

    local mode = answerFor(engine, stand, ride)
    if self.note and self.note.ride == ride then
      W.say(f.msg, self.note.text, W.COLOR.red)
    elseif mode == "full" then
      W.say(f.msg, L.REQUEST_NO_SEAT, W.COLOR.red)
    elseif mode == "converting" then
      W.say(f.msg, L.REQUEST_CONVERTING, W.COLOR.gold)
    else
      W.setText(f.msg, "")
    end

    local actions = not link:dead()
    f.decline.onClick = function()
      self:Answer(ride, "declineRequest")
    end
    f.decline:SetEnabled(actions)
    local answerable = mode == "accept" or mode == "convert"
    f.accept:SetShown(answerable)
    if answerable then
      W.setText(f.accept, mode == "convert" and L.CONVERT or L.ACCEPT)
      f.accept:SetWidth(mode == "convert" and 170 or 100)
      f.accept:SetEnabled(actions)
      f.accept.onClick = function()
        self:Answer(ride, mode == "convert" and "convertAndAccept" or "acceptRequest")
      end
    end
  end

  -- Shows the oldest waiting request that has not been closed or timed out,
  -- with a sound the first time any request is seen; hides the toast when
  -- there is none (or the engine is not the one the UI shows).
  function t:Refresh()
    if not link:live() then
      self:Close()
      return
    end
    local engine = link.engine
    local now = engine.clock:now()
    local current, more = nil, 0
    for _, ride in ipairs(pendingRequests(engine)) do
      if self.firstSeen[ride] == nil then
        self.firstSeen[ride] = now
        sound("READY_CHECK")
      end
      if not self.dismissed[ride] and now - self.firstSeen[ride] < TOAST_SECONDS then
        if current == nil then
          current = ride
        else
          more = more + 1
        end
      end
    end
    if current == nil then
      self:Close()
      return
    end
    self.frame = self.frame or buildToast(self, link)
    self:Paint(engine, engine.stand, current, more)
    self.current = current
    self.frame:Show()
  end

  return t
end

-- The clicker offer --------------------------------------------------------------------

-- What there is to answer: the oldest application to my stand that waits for me
-- ("ask"), else the owner's counter-offer to my own application ("counter").
local function nextOffer(engine, dismissed)
  local stand = engine.stand
  local names = {}
  for name, neg in pairs(stand and stand.talks or {}) do
    if neg.state == "asked" and not dismissed[neg] then
      names[#names + 1] = name
    end
  end
  table.sort(names)
  if names[1] ~= nil then
    return { kind = "ask", neg = stand.talks[names[1]], stand = stand }
  end
  local app = engine.application
  if app ~= nil and app.state == "countered" and not dismissed[app] then
    return { kind = "counter", neg = app }
  end
  return nil
end

local function buildOffer(o, link)
  local f = W.window{
    width = 340, height = 176, title = L.OFFER_TITLE, label = link.label, slot = link.slot, point = "TOP", y = -310,
  }
  f.line1 = W.text(f, "GameFontNormal")
  f.line1:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -36)
  f.line1:SetWidth(308)
  f.line2 = W.text(f, "GameFontHighlightSmall")
  f.line2:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -58)
  f.line2:SetWidth(308)
  f.counterLabel = W.text(f, "GameFontNormalSmall")
  f.counterLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -88)
  f.counterLabel:SetText(L.OFFER_COUNTER_WITH)
  f.counter = W.editBox(f, 34, { numeric = true, maxLetters = 2 })
  f.counter:SetPoint("TOPLEFT", f, "TOPLEFT", 110, -84)
  f.percent = W.text(f, "GameFontNormalSmall")
  f.percent:SetPoint("LEFT", f.counter, "RIGHT", 4, 0)
  f.percent:SetText(L.CREW_ADD_PCT)
  f.msg = W.text(f, "GameFontHighlightSmall")
  f.msg:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -112)
  f.msg:SetWidth(308)
  f.accept = W.button(f, L.ACCEPT, 80, nil)
  f.accept:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
  f.counterButton = W.button(f, L.OFFER_COUNTER, 90, nil)
  f.counterButton:SetPoint("RIGHT", f.accept, "LEFT", -6, 0)
  f.decline = W.button(f, L.DECLINE, 80, nil)
  f.decline:SetPoint("RIGHT", f.counterButton, "LEFT", -6, 0)
  if f.CloseButton then
    f.CloseButton:HookScript("OnClick", function()
      if o.current then
        o.dismissed[o.current] = true
        o.current = nil
      end
      o:Refresh()
    end)
  end
  f:SetScript("OnUpdate", function(_, elapsed)
    o.elapsed = (o.elapsed or 0) + elapsed
    if o.elapsed >= POLL_SECONDS then
      o.elapsed = 0
      link.engine:safely("clicker offer", o.Refresh, o)
    end
  end)
  return f
end

local function newOffer(link)
  local o = { dismissed = weak() }

  function o:Close()
    self.current = nil
    if self.frame then
      self.frame:Hide()
    end
  end

  -- Runs the Engine call `fn` for the offer on show; a refusal is said on the window.
  function o:Answer(fn)
    local result, why = fn()
    if result == nil then
      W.say(self.frame.msg, explain(why), W.COLOR.red)
      return
    end
    self:Refresh()
  end

  function o:Paint(item)
    local f, engine, neg = self.frame, link.engine, item.neg
    local actions = not link:dead()
    local ask = item.kind == "ask"
    if f.TitleText then
      W.setText(f.TitleText, (link.label and (link.label .. " - ") or "") .. (ask and L.OFFER_TITLE or L.OFFER_COUNTER_TITLE))
    end
    if self.shownFor ~= neg then
      self.shownFor = neg
      W.setText(f.msg, "")
      if ask then
        f.counter:SetText(tostring(neg.offeredPct or item.stand.clickerPct))
      end
    end
    f.counterLabel:SetShown(ask)
    f.counter:SetShown(ask)
    f.percent:SetShown(ask)
    f.counterButton:SetShown(ask)
    f.decline:SetEnabled(actions)
    f.accept:SetEnabled(actions)
    f.counterButton:SetEnabled(actions)
    if ask then
      W.setText(f.line1, L.fmt("APP_ASKS", neg.clicker, neg.askedPct))
      W.setText(f.line2, L.fmt("APP_ASKED", neg.offeredPct or item.stand.clickerPct))
      W.setText(f.accept, L.ACCEPT)
      f.accept.onClick = function()
        self:Answer(function()
          return engine:respondClicker(neg.clicker, "ACCEPT")
        end)
      end
      f.counterButton.onClick = function()
        self:Answer(function()
          return engine:respondClicker(neg.clicker, "COUNTER", f.counter:GetNumber())
        end)
      end
      f.decline.onClick = function()
        self:Answer(function()
          return engine:respondClicker(neg.clicker, "DECLINE")
        end)
      end
    else
      W.setText(f.line1, L.fmt("APPLY_COUNTER", tostring(neg.owner), neg.pct, neg.askedPct))
      W.setText(f.line2, "")
      W.setText(f.accept, L.TAKE_OFFER)
      f.accept.onClick = function()
        self:Answer(function()
          return engine:respondOffer(neg.standId, true)
        end)
      end
      f.decline.onClick = function()
        self:Answer(function()
          return engine:respondOffer(neg.standId, false)
        end)
      end
    end
  end

  function o:Refresh()
    if not link:live() then
      self:Close()
      return
    end
    local item = nextOffer(link.engine, self.dismissed)
    if item == nil then
      self:Close()
      return
    end
    self.frame = self.frame or buildOffer(self, link)
    self:Paint(item)
    self.current = item.neg
    self.frame:Show()
  end

  return o
end

-- The portal alert ---------------------------------------------------------------------

local alert -- one line across the top of the screen; it does not take the mouse

-- Says `text` for ALERT_SECONDS, with a sound.
function M.alert(text)
  if alert == nil then
    local f = CreateFrame("Frame", nil, UIParent)
    f:Hide()
    f:SetSize(460, 40)
    f:SetPoint("TOP", UIParent, "TOP", 0, -64)
    f:SetFrameStrata("FULLSCREEN_DIALOG")
    local bg = f:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0, 0, 0, 0.6)
    f.text = W.text(f, "GameFontNormalLarge", "CENTER")
    f.text:SetPoint("CENTER", f, "CENTER", 0, 0)
    f.text:SetWidth(440)
    f:SetScript("OnUpdate", function(frame, elapsed)
      frame.left = frame.left - elapsed
      if frame.left <= 0 then
        frame:Hide()
      end
    end)
    alert = f
  end
  W.say(alert.text, text, W.COLOR.gold)
  alert.left = ALERT_SECONDS
  alert:Show()
  sound("RAID_WARNING")
end

-- One engine's dialogs ---------------------------------------------------------------------

-- Gives `engine` its toast, clicker offer and portal alert. Returns
-- { Refresh(), Detach() }: Refresh shows or hides them to match the Engine's
-- state now (the sim starting or stopping), Detach ends them for good.
function M.attach(engine, opts)
  local link = W.link(engine, opts)
  local toast, offer = newToast(link), newOffer(link)
  local function both()
    toast:Refresh()
    offer:Refresh()
  end
  link:on("REQUEST_RECEIVED", function()
    toast:Refresh()
  end)
  link:on("RIDE_CHANGED", function()
    toast:Refresh()
  end)
  link:on("STAND_CHANGED", both)
  link:on("CLICKER_APPLIED", function()
    offer:Refresh()
  end)
  link:on("CLICK_OFFER", function()
    offer:Refresh()
  end)
  link:on("CLICK_DECLINED", function()
    offer:Refresh()
  end)
  link:on("SHIFT_STARTED", function()
    offer:Refresh()
  end)
  if not link.always then -- a sim player's alert would only add to yours
    link:on("PORTAL_UP", function(dest)
      M.alert(dest ~= nil and L.fmt("PORTAL_ALERT_TO", W.portalName(dest)) or L.PORTAL_ALERT)
    end)
  end
  return {
    Refresh = both,
    Detach = function()
      link:detach()
      toast:Close()
      offer:Close()
    end,
  }
end
