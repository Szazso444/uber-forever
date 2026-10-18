local _, ns = ...

-- The History tab and the journal behind it. db.rides keeps one entry per ride
-- I was part of (as traveler or as the stand's owner: declined, cancelled or
-- arrived) and per clicker shift, written by attach() from the Engine's
-- RIDE_CHANGED and SHIFT_ENDED events; the tab lists them newest first.
--
-- Entry: { id, ts, role = "traveler" | "provider" | "clicker", kind = "summon" |
-- "portal" | "shift", other = the other player, outcome = "arrived" | "declined" |
-- "cancelled" | "shift", dest, offer (rides), pct, owed, received (shifts) }.
-- An entry with an id already on file replaces that entry and keeps its ts,
-- which is how a shift's figures are brought up to date after its payout.
local L, Names, Money = ns.L, ns.Names, ns.Money
local UI = ns.UI
local W = UI.Widgets

local M = {}
UI.History = M

local MAX_ENTRIES = 200 -- the oldest go first
local ROWS = 8
local WIDTH = 576
local OUTCOMES = { arrived = true, declined = true, cancelled = true }

-- Files an entry in db.rides (see the top of the file).
function M.record(db, entry)
  local rides = db.rides
  if type(rides) ~= "table" then
    return
  end
  for i = #rides, 1, -1 do
    local old = rides[i]
    if type(old) == "table" and old.id == entry.id then
      entry.ts = old.ts or entry.ts
      rides[i] = entry
      return
    end
  end
  rides[#rides + 1] = entry
  while #rides > MAX_ENTRIES do
    table.remove(rides, 1)
  end
end

-- The entries of db.rides, newest first (anything that is not an entry is left out).
function M.list(db)
  local ranked = {}
  for i, entry in ipairs(type(db.rides) == "table" and db.rides or {}) do
    if type(entry) == "table" then
      ranked[#ranked + 1] = { entry = entry, index = i }
    end
  end
  table.sort(ranked, function(a, b)
    local ta, tb = tonumber(a.entry.ts) or 0, tonumber(b.entry.ts) or 0
    if ta ~= tb then
      return ta > tb
    end
    return a.index > b.index
  end)
  local out = {}
  for i, item in ipairs(ranked) do
    out[i] = item.entry
  end
  return out
end

local function rideEntry(engine, ride)
  if not OUTCOMES[ride.state] or ride.key == nil then
    return nil
  end
  local role, other
  if Names.same(ride.traveler, engine.me) then
    role, other = "traveler", ride.driver
  elseif Names.same(ride.driver, engine.me) then
    role, other = "provider", ride.traveler
  else
    return nil
  end
  return {
    id = ride.key .. "@" .. math.floor(ride.times.requested),
    ts = math.floor(engine.clock:now()),
    role = role, kind = ride.kind, other = other, dest = ride.dest, outcome = ride.state, offer = ride.offer,
  }
end

local function shiftEntry(engine, summary)
  return {
    id = summary.shiftId, ts = math.floor(engine.clock:now()), role = "clicker", kind = "shift",
    other = summary.owner, outcome = "shift", pct = summary.pct, owed = summary.owed, received = summary.received,
  }
end

-- Starts journaling the Engine's rides and shifts into db.rides.
function M.attach(engine, db)
  if db == nil then
    return
  end
  engine:on("RIDE_CHANGED", function(ride)
    local entry = rideEntry(engine, ride)
    if entry then
      M.record(db, entry)
    end
  end)
  engine:on("SHIFT_ENDED", function(summary)
    M.record(db, shiftEntry(engine, summary))
  end)
end

-- The row of one entry; every field is checked, since SavedVariables can hold anything.
local function rowOf(entry)
  local other = tostring(entry.other or "?")
  local title
  if entry.role == "clicker" then
    title = L.fmt("HISTORY_clicker", other)
  elseif entry.kind == "portal" then
    title = L.fmt("HISTORY_" .. tostring(entry.role) .. "_portal", W.portalName(entry.dest), other)
  else
    title = L.fmt("HISTORY_" .. tostring(entry.role) .. "_summon", other)
  end
  local shown, when = pcall(date, "%d %b %H:%M", entry.ts)
  if not shown or type(when) ~= "string" then
    when = "?"
  end
  local spec = { title = title }
  local outcome = rawget(L, "OUTCOME_" .. tostring(entry.outcome)) or tostring(entry.outcome or "?")
  spec.sub = when .. " · " .. outcome
  if entry.role == "clicker" then
    spec.right = type(entry.pct) == "number" and L.fmt("HISTORY_SHARE", entry.pct) or nil
    if type(entry.owed) == "number" and type(entry.received) == "number" then
      spec.sub2 = L.fmt("PAYOUT_LINE", Money.format(entry.owed), Money.format(entry.received))
    end
  elseif type(entry.offer) == "number" and entry.offer > 0 then
    spec.sub2 = L.fmt("HISTORY_OFFER", Money.format(entry.offer))
  end
  return spec
end

function M.new(parent)
  local view = {}
  view.list = W.list(parent, { width = WIDTH, rows = ROWS })
  view.list.frame:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
  view.empty = W.text(parent, "GameFontHighlight", "CENTER")
  view.empty:SetPoint("CENTER", view.list.frame, "CENTER", -10, 0)
  view.empty:SetWidth(WIDTH - 80)

  function view:Refresh()
    local specs = {}
    for _, entry in ipairs(M.list(ns.db or {})) do
      specs[#specs + 1] = rowOf(entry)
    end
    self.list:SetRows(specs)
    W.setText(self.empty, #specs == 0 and L.HISTORY_EMPTY or "")
  end

  return view
end
