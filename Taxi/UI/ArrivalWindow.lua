local _, ns = ...

-- The arrival window, shown when a ride of mine arrives (the Engine's ARRIVED).
--
--   summon rides   the driver's Trust rating (1-5 stars, optional), the tip
--                  (none / 50s / 1g / custom, with the tip I offered when I
--                  asked already picked), Open trade with <driver>, Stay and
--                  click (sign up to the same stand), Leave group;
--   portal rides   the same without the stars and Stay and click: portals are
--                  never rated, and a mage has no clickers.
--
-- Open trade is Engine:submitArrival, which sends the rating and opens the
-- trade. Whether an addon may set the money in the trade window in Forever is
-- not known: SetTradeMoney is restricted and has no way to read the amount
-- back (checklist I1, I2). Taxi tries (right after the window opens, R63) and
-- can't tell whether it worked, so the window always says "Put 1g in the
-- trade" and the player checks or types it; the Engine learns of the tip from
-- the finished trade, not from this window. A rating is sent once: opening the
-- trade again sends none.
--
-- A plain free-standing window (Widgets.window): it shows in combat, and the
-- player closes it with its X.
local L, Money = ns.L, ns.Money
local UI = ns.UI
local W = UI.Widgets

local M = {}
UI.ArrivalWindow = M

local WIDTH = 360

local function explain(why)
  return UI.Main.explain(nil, why)
end

local function build(view, link)
  local f = W.window{ width = WIDTH, height = 340, title = L.ARRIVE_TITLE, label = link.label, slot = link.slot, y = 40 }
  f.what = W.text(f, "GameFontNormal")
  f.what:SetWidth(328)
  f.warn = W.text(f, "GameFontHighlightSmall")
  f.warn:SetWidth(328)
  f.warn:SetWordWrap(true)
  W.paint(f.warn, W.COLOR.red)
  f.rateLabel = W.text(f, "GameFontNormalSmall")
  f.rateLabel:SetWidth(328)
  f.stars = W.stars(f, function()
    view:PaintTrade()
  end)
  f.tipLabel = W.text(f, "GameFontNormalSmall")
  f.tipLabel:SetText(L.ARRIVE_TIP)
  f.picker = W.tipPicker(f, function()
    view:PaintTrade()
  end)
  f.put = W.text(f, "GameFontHighlight")
  f.put:SetWidth(328)
  f.put:SetWordWrap(true)
  W.paint(f.put, W.COLOR.gold)
  f.msg = W.text(f, "GameFontHighlightSmall")
  f.msg:SetWidth(328)
  f.msg:SetWordWrap(true)
  f.trade = W.button(f, L.ARRIVE_SEND_RATING, 240, function()
    view:Trade()
  end)
  f.stay = W.button(f, L.ARRIVE_STAY, 150, function()
    view:Stay()
  end)
  f.leave = W.button(f, L.ARRIVE_LEAVE, 150, function()
    view:Leave()
  end)
  return f
end

local function newView(link)
  local view = {}

  local function at(widget, y, x)
    widget:ClearAllPoints()
    widget:SetPoint("TOPLEFT", view.frame, "TOPLEFT", x or 16, -y)
  end

  function view:Close()
    self.state = nil
    if self.frame then
      self.frame:Hide()
    end
  end

  -- The Open trade / Send rating button: what it would do now, and whether it
  -- can. Open trade is there whenever a tip is picked (a custom amount that
  -- holds nothing is told so when it is clicked); Send rating needs stars.
  function view:PaintTrade()
    local f, state = self.frame, self.state
    if f == nil or state == nil then
      return
    end
    local ride = state.ride
    local tipping = f.picker.choice ~= "none"
    local canRate = ride.kind == "summon" and not state.rated and f.stars:GetValue() > 0
    W.setText(f.trade, tipping and L.fmt("ARRIVE_TRADE", ride.driver) or L.ARRIVE_SEND_RATING)
    f.trade:SetEnabled(not link:dead() and (tipping or canRate))
  end

  -- Lays the window out for the ride on show (a portal ride has no stars).
  function view:Paint()
    local f, state = self.frame, self.state
    local ride = state.ride
    local summon = ride.kind == "summon"
    local dead = link:dead()
    W.setText(f.what, summon and L.fmt("ARRIVE_SUMMON", ride.driver)
      or L.fmt("ARRIVE_PORTAL", W.portalName(ride.dest), ride.driver))
    local y = 36
    at(f.what, y)
    y = y + 22
    local wrong = summon and ride.wrongPlace == true
    f.warn:SetShown(wrong)
    if wrong then
      W.setText(f.warn, L.ARRIVE_WRONG)
      at(f.warn, y)
      y = y + 30
    end
    f.rateLabel:SetShown(summon)
    f.stars:SetShown(summon)
    if summon then
      W.setText(f.rateLabel, L.fmt("ARRIVE_RATE", ride.driver))
      at(f.rateLabel, y)
      y = y + 18
      at(f.stars, y)
      y = y + 30
    end
    at(f.tipLabel, y)
    y = y + 18
    at(f.picker, y)
    y = y + 62
    at(f.put, y)
    y = y + 34
    at(f.msg, y)
    y = y + 34
    at(f.trade, y)
    y = y + 30
    f.stay:SetShown(summon)
    f.stay:SetEnabled(not dead and not state.applied)
    f.leave:SetEnabled(not dead and not state.left)
    if summon then
      at(f.stay, y)
      at(f.leave, y, 16 + 160)
    else
      at(f.leave, y)
    end
    y = y + 30
    f:SetHeight(y + 10)
    if dead then
      W.say(f.msg, L.STATUS_HC_DEAD, W.COLOR.red)
    end
    self:PaintTrade()
  end

  -- Shows the window for an arrived ride (the Engine's ARRIVED).
  function view:Show(ride)
    if ride.kind ~= "summon" and ride.kind ~= "portal" then
      return
    end
    self.state = { ride = ride, rated = false, applied = false, left = false }
    self.frame = self.frame or build(self, link)
    local f = self.frame
    f.stars:SetValue(0)
    f.stars:SetPickable(true)
    f.picker:SetOffer(ride.offer) -- the tip I offered when I asked is picked already
    W.setText(f.put, "")
    W.setText(f.msg, "")
    self:Paint()
    f:Show()
  end

  -- Open trade (with a tip picked) or Send rating (without one): the rating goes
  -- out with the first of these that has stars; the trade opens when a tip is picked.
  function view:Trade()
    local f, state, engine = self.frame, self.state, link.engine
    local ride = state.ride
    local valid, tip = f.picker:Read()
    if not valid then
      W.say(f.msg, explain("bad_offer"), W.COLOR.red)
      return
    end
    local stars = ride.kind == "summon" and not state.rated and f.stars:GetValue() or 0
    local ok, second = engine:submitArrival(ride.rideId, stars > 0 and stars or nil, tip)
    if not ok then
      if second == "no_trade" and stars > 0 then
        state.rated = true -- the rating went out before the game refused the trade
        f.stars:SetPickable(false)
      end
      W.say(f.msg, explain(second), W.COLOR.red)
      self:PaintTrade()
      return
    end
    if stars > 0 then
      state.rated = true
      f.stars:SetPickable(false)
      W.say(f.msg, L.ARRIVE_RATED, W.COLOR.white)
    else
      W.setText(f.msg, "")
    end
    if tip ~= nil then
      local money = Money.format(tip)
      W.setText(f.put, second == true and L.fmt("ARRIVE_SET", money) or L.fmt("ARRIVE_PUT", money))
    end
    self:PaintTrade()
  end

  function view:Stay()
    local f, state = self.frame, self.state
    local ok, why = link.engine:stayAndClick(state.ride.rideId)
    if ok then
      state.applied = true
      f.stay:SetEnabled(false)
      W.say(f.msg, L.fmt("NOTICE_APPLIED", tostring(state.ride.driver)), W.COLOR.white)
    else
      W.say(f.msg, explain(why), W.COLOR.red)
    end
  end

  function view:Leave()
    local f, state = self.frame, self.state
    link.engine:leaveGroup()
    state.left = true
    f.leave:SetEnabled(false)
    W.say(f.msg, L.ARRIVE_LEFT, W.COLOR.white)
  end

  return view
end

-- Gives `engine` its arrival window. Returns { Refresh(), Detach() }.
function M.attach(engine, opts)
  local link = W.link(engine, opts)
  local view = newView(link)
  link:on("ARRIVED", function(ride)
    view:Show(ride)
  end)
  return {
    Refresh = function()
      if not link:live() then
        view:Close()
      end
    end,
    Detach = function()
      link:detach()
      view:Close()
    end,
  }
end
