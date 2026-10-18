local _, ns = ...

-- The shift-end window, shown when a clicker's shift ends (the Engine's
-- SHIFT_ENDED): "Owed 25s · Received 25s ✓", any tip the traveler and the
-- warlock disagree about, and the Share rating of the warlock with its stars
-- already filled in from what was paid (Ledger.prefill; none when nothing was
-- owed), for the clicker to change and Submit.
--
-- The Engine sends SHIFT_ENDED again when a payout comes in after the shift
-- (the summary is brought up to date): the same window shows the new numbers,
-- and the stars follow the new suggestion until the player picks their own.
-- A rating that has been submitted is not asked for again.
local L, Money = ns.L, ns.Money
local UI = ns.UI
local W = UI.Widgets

local M = {}
UI.ShiftEndWindow = M

local WIDTH = 360
local MAX_DISPUTED = 3

local function explain(why)
  return UI.Main.explain(nil, why)
end

local function build(view, link)
  local f = W.window{ width = WIDTH, height = 270, title = L.SHIFTEND_TITLE, label = link.label, slot = link.slot, y = 40 }
  f.who = W.text(f, "GameFontNormal")
  f.who:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -36)
  f.who:SetWidth(328)
  f.money = W.text(f, "GameFontHighlight")
  f.money:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -58)
  f.money:SetWidth(328)
  f.disputed = {}
  for i = 1, MAX_DISPUTED + 1 do
    local line = W.text(f, "GameFontHighlightSmall")
    line:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -78 - (i - 1) * 14)
    line:SetWidth(328)
    W.paint(line, W.COLOR.red)
    f.disputed[i] = line
  end
  f.rateLabel = W.text(f, "GameFontNormalSmall")
  f.rateLabel:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -142)
  f.rateLabel:SetWidth(328)
  f.stars = W.stars(f, function()
    view.picked = true
  end)
  f.stars:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -160)
  f.hint = W.text(f, "GameFontHighlightSmall")
  f.hint:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -188)
  f.hint:SetWidth(328)
  f.hint:SetWordWrap(true)
  W.paint(f.hint, W.COLOR.gray)
  f.msg = W.text(f, "GameFontHighlightSmall")
  f.msg:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -214)
  f.msg:SetWidth(328)
  f.submit = W.button(f, L.SHIFTEND_SUBMIT, 100, function()
    view:Submit()
  end)
  f.submit:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
  f.close = W.button(f, L.SHIFTEND_CLOSE, 100, function()
    f:Hide()
  end)
  f.close:SetPoint("RIGHT", f.submit, "LEFT", -8, 0)
  return f
end

local function newView(link)
  local view = { submitted = {} }

  function view:Close()
    if self.frame then
      self.frame:Hide()
    end
  end

  -- Fills the window from a shift summary ({ shiftId, owner, pct, owed,
  -- received, prefill, disputed }).
  function view:Paint(summary)
    local f = self.frame
    local owed, received = summary.owed or 0, summary.received or 0
    W.setText(f.who, L.fmt("SHIFTEND_FOR", tostring(summary.owner), summary.pct or 0))
    local money = L.fmt("SHIFTEND_MONEY", Money.format(owed), Money.format(received))
    W.setText(f.money, owed > 0 and received >= owed and (money .. " " .. W.CHECK) or money)
    local disputed = type(summary.disputed) == "table" and summary.disputed or {}
    for i, line in ipairs(f.disputed) do
      local d = disputed[i]
      if i <= MAX_DISPUTED and d then
        W.setText(line, L.fmt("SHIFTEND_DISPUTED", Money.format(d.tip), Money.format(d.ack)))
      elseif i == MAX_DISPUTED + 1 and #disputed > MAX_DISPUTED then
        W.setText(line, L.fmt("SHIFTEND_DISPUTED_MORE", #disputed - MAX_DISPUTED))
      else
        W.setText(line, "")
      end
    end
    W.setText(f.rateLabel, L.fmt("SHIFTEND_RATE", tostring(summary.owner)))
    if not self.picked then
      f.stars:SetValue(summary.prefill or 0)
    end
    W.setText(f.hint, summary.prefill ~= nil and L.SHIFTEND_PREFILL or L.SHIFTEND_NO_PREFILL)
    f.submit:SetEnabled(not link:dead())
  end

  -- Shows the window for a shift summary. The same shift again (a payout came
  -- in) keeps the player's own stars; a new shift starts clean.
  function view:Show(summary)
    if self.submitted[summary.shiftId] then
      return
    end
    self.frame = self.frame or build(self, link)
    if self.summary == nil or self.summary.shiftId ~= summary.shiftId then
      self.picked = false
      W.setText(self.frame.msg, "")
    end
    self.summary = summary
    self:Paint(summary)
    self.frame:Show()
  end

  function view:Submit()
    local f, summary = self.frame, self.summary
    local stars = f.stars:GetValue()
    if stars < 1 then
      W.say(f.msg, L.SHIFTEND_PICK, W.COLOR.red)
      return
    end
    local ok, why = link.engine:submitShiftRating(summary.shiftId, stars)
    if not ok then
      W.say(f.msg, explain(why), W.COLOR.red)
      return
    end
    self.submitted[summary.shiftId] = true
    f:Hide()
  end

  return view
end

-- Gives `engine` its shift-end window. Returns { Refresh(), Detach() }.
function M.attach(engine, opts)
  local link = W.link(engine, opts)
  local view = newView(link)
  link:on("SHIFT_ENDED", function(summary)
    view:Show(summary)
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
