local _, ns = ...

-- The Clicking tab: summon stands that still need clickers, each with the
-- owner's Share rating, the share they offer and an Apply button with a box for
-- the share to ask for; and, below, the state of my own application or shift.
local L, Board, Ledger, Money = ns.L, ns.Board, ns.Ledger, ns.Money
local UI = ns.UI
local W = UI.Widgets

local M = {}
UI.Clicking = M

local ROWS = 5
local WIDTH = 576
local MAX_CLICKERS = 2 -- a stand takes two (Stand.addClicker)

function M.new(parent, main)
  local view = {}

  view.list = W.list(parent, { width = WIDTH, rows = ROWS, buttons = 1, edit = true })
  view.list.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
  view.empty = W.text(parent, "GameFontHighlight", "CENTER")
  view.empty:SetPoint("CENTER", view.list.frame, "CENTER", -10, 0)
  view.empty:SetWidth(WIDTH - 80)

  -- My application and shift.
  local panel = CreateFrame("Frame", nil, parent)
  panel:SetSize(WIDTH, 120)
  panel:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(ROWS * W.ROW_HEIGHT + 8))
  view.status = W.text(panel, "GameFontNormal")
  view.status:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -4)
  view.status:SetWidth(WIDTH - 16)
  view.money = W.text(panel, "GameFontHighlightSmall")
  view.money:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -26)
  view.money:SetWidth(WIDTH - 16)
  view.leave = W.button(panel, L.SHIFT_LEAVE, 100, function()
    main:report(ns.engine:leaveStand())
  end)
  view.leave:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -52)
  view.take = W.button(panel, L.TAKE_OFFER, 100, function()
    local neg = ns.engine.application
    if neg then
      main:report(ns.engine:respondOffer(neg.standId, true))
    end
  end)
  view.take:SetPoint("TOPLEFT", panel, "TOPLEFT", 8, -52)
  view.refuse = W.button(panel, L.DECLINE, 100, function()
    local neg = ns.engine.application
    if neg then
      main:report(ns.engine:respondOffer(neg.standId, false))
    end
  end)
  view.refuse:SetPoint("LEFT", view.take, "RIGHT", 6, 0)

  local function apply(stand, pct)
    local ok, why = ns.engine:applyClicker(stand.standId, pct)
    main:report(ok, why, L.fmt("NOTICE_APPLIED", tostring(stand.owner)))
  end

  -- Owed and received (agreed tips only) on my ledger for a shift's stand.
  local function money(engine, standId)
    local l = engine.ledgers[standId]
    if l == nil then
      return 0, 0
    end
    return (Ledger.owed(l, engine.me)), Ledger.receivedBy(l, engine.me)
  end

  function view:Refresh()
    local engine = ns.engine
    local game = engine.game
    local actions = main:actionsEnabled()
    local shift, application = engine.shift, engine.application

    local shares = {}
    local function share(owner)
      if shares[owner] == nil then
        shares[owner] = engine:summary(owner, "share")
      end
      return shares[owner]
    end
    local stands = Board.list(engine.board, {
      kind = "lock", faction = game:faction(), now = engine.clock:now(),
      isGuildmate = function(owner)
        return game:isGuildmate(owner)
      end,
      rank = function(owner)
        local s = share(owner)
        return s.score, s.count
      end,
    })

    local specs = {}
    for _, stand in ipairs(stands) do
      local needed = MAX_CLICKERS - (stand.clickers or 0)
      if needed > 0 then
        specs[#specs + 1] = {
          title = stand.owner,
          titleColor = game:isGuildmate(stand.owner) and W.COLOR.green or nil,
          sub = W.place(stand) .. " · " .. (needed == 1 and L.CLICK_NEEDS_ONE or L.fmt("CLICK_NEEDS_MANY", needed)),
          sub2 = W.shareLine(share(stand.owner)),
          right = L.fmt("CLICK_OFFERS", stand.clickerPct or 0),
          edit = { key = stand.standId, text = tostring(stand.clickerPct or "") },
          buttons = {
            {
              text = L.APPLY, width = 70,
              enabled = actions and shift == nil and application == nil,
              onClick = function(_, row)
                apply(stand, row.edit:GetNumber())
              end,
            },
          },
        }
      end
    end
    self.list:SetRows(specs)
    W.setText(self.empty, #specs == 0 and L.CLICK_EMPTY or "")

    -- Below the list: the shift, the application, or the last shift.
    local status, moneyLine = L.SHIFT_NONE, ""
    local countered = false
    if shift ~= nil then
      status = L.fmt("SHIFT_NOW", tostring(shift.owner), shift.pct)
      local owed, received = money(engine, shift.standId)
      moneyLine = L.fmt("SHIFT_MONEY", Money.format(owed), Money.format(received))
    elseif application ~= nil then
      if application.state == "countered" then
        countered = true
        status = L.fmt("APPLY_COUNTER", tostring(application.owner), application.pct, application.askedPct)
      else
        status = L.fmt("APPLY_WAIT", tostring(application.owner), application.askedPct)
      end
    elseif engine.lastShift ~= nil then
      local last = engine.lastShift
      moneyLine = L.fmt("SHIFT_LAST", tostring(last.owner), Money.format(last.owed), Money.format(last.received))
    end
    W.setText(self.status, status)
    W.setText(self.money, moneyLine)
    self.leave:SetShown(shift ~= nil)
    self.leave:SetEnabled(actions)
    self.take:SetShown(countered)
    self.take:SetEnabled(actions)
    self.refuse:SetShown(countered)
    self.refuse:SetEnabled(actions)
  end

  return view
end
