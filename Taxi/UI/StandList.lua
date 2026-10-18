local _, ns = ...

-- The Travel tab: the live and paused stands on the board (SHOWN), summons or
-- portals, filtered by zone. Guildmates come first and are green; the rest are
-- ordered by trust (Board.list). Picking a row shows its details and asks the
-- channel about its owner (Engine:query, once per cooldown); Request asks for
-- a seat.
--
-- The Board is re-read on every repaint, which the window does every 5 s while
-- it is open: BOARD_CHANGED only comes with the Engine's 30 s sweep, but a stand
-- that went quiet must leave the list at its TTL (R51).
local L, Board, Names, Ride = ns.L, ns.Board, ns.Names, ns.Ride
local UI = ns.UI
local W = UI.Widgets

local M = {}
UI.StandList = M

local ROWS = 6
local WIDTH = 576
-- The stands travelers see (R69): live ones, and paused ones marked "Paused"
-- with their Request button off. A warlock's stand still recruiting clickers
-- is on the Clicking tab only.
local SHOWN = { live = true, paused = true }

local function seatsText(view)
  local free = view.seatsFree or 0
  if free <= 0 then
    return L.SEATS_FULL
  end
  return free == 1 and L.SEATS_FREE_ONE or L.fmt("SEATS_FREE_MANY", free)
end

-- The Request button: a mage stand with several portals asks which one first.
-- Either way the request dialog (UI/Dialogs.lua) takes the tip offer and sends it.
local function onRequest(view, button)
  if view.kind ~= "mage" then
    UI.Dialogs.request(view, nil)
    return
  end
  local items = {}
  for _, key in ipairs(view.portals or {}) do
    items[#items + 1] = { value = key, text = W.portalName(key) }
  end
  if #items == 1 then
    UI.Dialogs.request(view, items[1].value)
  elseif #items > 1 then
    W.popupMenu(button, items, function(key)
      UI.Dialogs.request(view, key)
    end)
  end
end

function M.new(parent, main)
  local view = { kind = "lock", zone = nil, selected = nil, zones = {} }

  view.summons = W.button(parent, L.TRAVEL_SUMMONS, 90, function()
    view:SetKind("lock")
  end)
  view.summons:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
  view.portals = W.button(parent, L.TRAVEL_PORTALS, 90, function()
    view:SetKind("mage")
  end)
  view.portals:SetPoint("LEFT", view.summons, "RIGHT", 4, 0)
  view.dropdown = W.dropdown(parent, 200, function(zone)
    view.zone = zone
    main:Refresh()
  end)
  view.dropdown:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -22, 0)

  view.list = W.list(parent, { width = WIDTH, rows = ROWS, buttons = 1 })
  view.list.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -28)
  view.empty = W.text(parent, "GameFontHighlight", "CENTER")
  view.empty:SetPoint("CENTER", view.list.frame, "CENTER", -10, 0)
  view.empty:SetWidth(WIDTH - 80)

  -- What the picked stand says about itself.
  view.detail = {}
  for i = 1, 4 do
    local line = W.text(parent, "GameFontHighlightSmall")
    line:SetPoint("TOPLEFT", parent, "TOPLEFT", 8, -28 - ROWS * W.ROW_HEIGHT - 6 - (i - 1) * 15)
    line:SetWidth(WIDTH - 16)
    view.detail[i] = line
  end

  function view:SetKind(kind)
    self.kind, self.zone, self.selected = kind, nil, nil
    main:Refresh()
  end

  -- Picking a row asks the channel about the owner (a cooldown inside Engine:query
  -- keeps that to once per ten minutes).
  function view:Select(stand)
    self.selected = stand.standId
    if stand.kind == "lock" then
      ns.engine:query(stand.owner)
    end
    main:Refresh()
  end

  function view:Refresh()
    local engine = ns.engine
    local game = engine.game
    local now = engine.clock:now()
    local actions = main:actionsEnabled()
    local mine = Names.normalize(engine.me)

    local trusts = {}
    local function trust(owner)
      if trusts[owner] == nil then
        trusts[owner] = engine:summary(owner, "trust")
      end
      return trusts[owner]
    end

    local stands = Board.list(engine.board, {
      kind = self.kind, faction = game:faction(), now = now, statuses = SHOWN,
      isGuildmate = function(owner)
        return game:isGuildmate(owner)
      end,
      rank = function(owner)
        local s = trust(owner)
        return s.score, s.count
      end,
    })

    -- Zones with a stand, then the zone filter applied.
    local seen, zones = {}, {}
    for _, stand in ipairs(stands) do
      local zone = stand.zone
      if zone ~= nil and not seen[zone] then
        seen[zone] = true
        zones[#zones + 1] = zone
      end
    end
    table.sort(zones)
    if self.zone ~= nil and not seen[self.zone] then
      self.zone = nil -- the last stand of that zone left the board
    end
    local items = { { value = nil, text = L.ZONE_ALL } }
    for _, zone in ipairs(zones) do
      items[#items + 1] = { value = zone, text = zone }
    end
    self.dropdown:SetItems(items)
    self.dropdown:Select(self.zone)
    self.summons:SetEnabled(self.kind ~= "lock")
    self.portals:SetEnabled(self.kind ~= "mage")

    local specs, picked = {}, nil
    for _, stand in ipairs(stands) do
      if self.zone == nil or stand.zone == self.zone then
        local ride = engine.rides[mine .. "#" .. stand.standId]
        local live = ride ~= nil and not Ride.isFinal(ride)
        local paused = stand.status ~= "live"
        local right = paused and L.TRAVEL_PAUSED or seatsText(stand)
        local spec = {
          title = stand.owner,
          titleColor = game:isGuildmate(stand.owner) and W.COLOR.green or nil,
          sub = W.place(stand),
          right = live and (rawget(L, "RIDE_" .. ride.state) or ride.state) or right,
          selected = self.selected == stand.standId,
          onClick = function()
            self:Select(stand)
          end,
        }
        if stand.kind == "mage" then
          spec.sub2 = L.fmt("PORTALS_TO", W.portalNames(stand.portals)) -- a mage has no trust rating
        else
          spec.sub2, spec.warn = W.trustLine(trust(stand.owner))
        end
        if not live then
          spec.buttons = {
            {
              text = L.REQUEST,
              enabled = actions and not paused and (stand.seatsFree or 0) > 0,
              onClick = function(_, row)
                onRequest(stand, row.buttons[1])
              end,
            },
          }
        end
        specs[#specs + 1] = spec
        if self.selected == stand.standId then
          picked = stand
        end
      end
    end
    if picked == nil then
      self.selected = nil
    end
    self.list:SetRows(specs)
    W.setText(self.empty, #specs == 0 and L.TRAVEL_EMPTY or "")
    self:ShowDetail(picked, trust)
  end

  -- The four detail lines for the picked stand (or a hint).
  function view:ShowDetail(stand, trust)
    local lines = {}
    if stand == nil then
      lines[1] = L.DETAIL_PICK
    else
      lines[1] = tostring(stand.owner) .. " - " .. W.place(stand)
      if stand.kind == "mage" then
        lines[2] = L.fmt("DETAIL_PORTALS", W.portalNames(stand.portals))
      else
        local text, warn = W.trustLine(trust(stand.owner))
        lines[2] = warn and (text .. "  " .. warn) or text
        lines[4] = L.fmt("DETAIL_CREW", stand.clickers or 0, stand.clickerPct or 0)
      end
      local note = stand.note
      lines[3] = (note == nil or note == "") and L.DETAIL_NO_NOTE or L.fmt("DETAIL_NOTE", note)
    end
    for i, line in ipairs(self.detail) do
      W.setText(line, lines[i] or "")
    end
  end

  return view
end
