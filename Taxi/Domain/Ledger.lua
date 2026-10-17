local _, ns = ...

-- Ledger: one clicker's own record of the tips earned on a warlock's stand.
--
-- Nobody takes the warlock's word, or the traveler's, for what was tipped. A
-- tip counts only when the traveler's report (TIP) and the warlock's report
-- (TIP_ACK) name the same amount for the same ride; a mismatch is shown as
-- disputed and left out. Each clicker's addon keeps its own ledger and works
-- out its own share: the agreed tips of rides that arrived during that
-- clicker's shift, times that clicker's agreed percentage.
--
-- A report is final once it is on file: a repeated TIP or TIP_ACK for the same
-- ride keeps the first amount, so nobody can revise a report after the fact
-- (a mismatch, if any, then shows as disputed). A report with a bad amount is
-- ignored and does not use up the ride's one report.
--
-- Who may send a TIP (the ride's traveler) or a TIP_ACK (the stand's owner) is
-- checked by the caller, which also knows when each ride arrived; the ledger
-- only holds what it is given. One ledger belongs to one stand. A clicker who
-- leaves and joins again starts a new shift, and only the latest shift of each
-- clicker is kept.
local Names, Util = ns.Names, ns.Util

local M = {}

-- True only for a real, finite number (not nil, not NaN, not +-infinity).
local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

-- A copper amount: a finite whole number, zero or more.
local function validAmount(x)
  return finite(x) and x >= 0 and x == math.floor(x)
end

local function nonEmptyString(x)
  return type(x) == "string" and x ~= ""
end

-- A player name tidied the way Names.same compares, or nil when x is not a
-- usable name. Every per-clicker table is keyed by this.
local function nameOf(x)
  local n = Names.normalize(x)
  if n == nil or n == "" then
    return nil
  end
  return n
end

-- The keys of t in a fixed order, so the lists owed() returns are stable.
local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  return keys
end

-- A ledger for one stand. Returns nil, "bad_args" without a stand id or owner.
function M.new(standId, owner)
  local ownerName = nameOf(owner)
  if not nonEmptyString(standId) or ownerName == nil then
    return nil, "bad_args"
  end
  return {
    standId = standId,
    owner = ownerName,
    shifts = {}, -- clicker -> the clicker's latest shift
    tips = {}, -- rideId -> { amount, arrivedTs } as the traveler reported it
    acks = {}, -- rideId -> amount as the warlock reported it
    got = {}, -- clicker -> copper received since that clicker's latest join
  }
end

-- Starts a shift for `clicker` at `pct` percent of every tip, from `ts`.
-- Returns a copy of the shift, { shiftId, clicker, pct, joinTs }, or nil plus
-- "bad_clicker", "is_owner", "bad_pct" (not a whole number from 1 to 99),
-- "bad_ts" or "on_shift" (the clicker's shift is still open). The new shift
-- replaces the clicker's earlier one and starts the received total again.
function M.join(l, clicker, pct, ts)
  local name = nameOf(clicker)
  if name == nil then
    return nil, "bad_clicker"
  end
  if Names.same(name, l.owner) then
    return nil, "is_owner"
  end
  if not (finite(pct) and pct == math.floor(pct) and pct >= 1 and pct <= 99) then
    return nil, "bad_pct"
  end
  if not finite(ts) then
    return nil, "bad_ts"
  end
  local open = l.shifts[name]
  if open ~= nil and open.leaveTs == nil then
    return nil, "on_shift"
  end
  local shift = {
    shiftId = l.standId .. ":" .. name .. ":" .. math.floor(ts),
    clicker = name,
    pct = pct,
    joinTs = ts,
  }
  l.shifts[name] = shift
  l.got[name] = nil
  return Util.copy(shift)
end

-- Ends the clicker's open shift at `ts` and returns a copy of it, now with
-- `leaveTs`. Returns nil plus "not_on_shift" (no shift, or it already ended)
-- or "bad_ts" (not a number, or before the join).
function M.leave(l, clicker, ts)
  local name = nameOf(clicker)
  local shift = name and l.shifts[name]
  if shift == nil or shift.leaveTs ~= nil then
    return nil, "not_on_shift"
  end
  if not finite(ts) or ts < shift.joinTs then
    return nil, "bad_ts"
  end
  shift.leaveTs = ts
  return Util.copy(shift)
end

-- The traveler's report (TIP) of what they tipped on `rideId`, and when this
-- client saw that ride arrive. Without a usable arrivedTs the tip belongs to
-- no shift, so it counts for nobody; a repeat of the same TIP may still supply
-- the arrival, because that is this client's own observation and not the
-- traveler's word. Returns true, or nil plus "bad_ride", "bad_amount" or
-- "duplicate" (the first report is kept).
function M.tip(l, rideId, amount, arrivedTs)
  if not nonEmptyString(rideId) then
    return nil, "bad_ride"
  end
  if not validAmount(amount) then
    return nil, "bad_amount"
  end
  local arrived = finite(arrivedTs) and arrivedTs or nil
  local known = l.tips[rideId]
  if known == nil then
    l.tips[rideId] = { amount = amount, arrivedTs = arrived }
    return true
  end
  if known.arrivedTs == nil and arrived ~= nil then
    known.arrivedTs = arrived
    return true
  end
  return nil, "duplicate"
end

-- The warlock's report (TIP_ACK) of the gold they received on `rideId`.
-- Returns true, or nil plus "bad_ride", "bad_amount" or "duplicate" (the first
-- report is kept).
function M.ack(l, rideId, amount)
  if not nonEmptyString(rideId) then
    return nil, "bad_ride"
  end
  if not validAmount(amount) then
    return nil, "bad_amount"
  end
  if l.acks[rideId] ~= nil then
    return nil, "duplicate"
  end
  l.acks[rideId] = amount
  return true
end

-- Gold this clicker actually got from the warlock in a trade. It adds up until
-- the clicker joins again. Returns true, or nil plus "bad_clicker" or
-- "bad_amount".
function M.received(l, clicker, amount)
  local name = nameOf(clicker)
  if name == nil then
    return nil, "bad_clicker"
  end
  if not validAmount(amount) then
    return nil, "bad_amount"
  end
  l.got[name] = (l.got[name] or 0) + amount
  return true
end

-- Copper received so far (0 for a clicker the ledger has not seen).
function M.receivedBy(l, clicker)
  local name = nameOf(clicker)
  return name and l.got[name] or 0
end

-- What the clicker is owed for their latest shift: the share of every agreed
-- tip whose ride arrived inside the shift, each rounded down to whole copper.
-- Also returns `disputed` ({ rideId, tip, ack } where both reports exist and
-- differ) and `pending` ({ rideId, tip } where the warlock has not confirmed
-- yet); neither is part of the total. A tip with no known arrival is in
-- nobody's list. Both lists are in ride id order.
function M.owed(l, clicker)
  local owed, disputed, pending = 0, {}, {}
  local name = nameOf(clicker)
  local shift = name and l.shifts[name]
  if shift == nil then
    return owed, disputed, pending
  end
  local last = shift.leaveTs or math.huge
  for _, rideId in ipairs(sortedKeys(l.tips)) do
    local tip = l.tips[rideId]
    local arrived = tip.arrivedTs
    if arrived ~= nil and arrived >= shift.joinTs and arrived <= last then
      local ack = l.acks[rideId]
      if ack == nil then
        pending[#pending + 1] = { rideId = rideId, tip = tip.amount }
      elseif ack == tip.amount then
        owed = owed + math.floor(tip.amount * shift.pct / 100)
      else
        disputed[#disputed + 1] = { rideId = rideId, tip = tip.amount, ack = ack }
      end
    end
  end
  return owed, disputed, pending
end

-- The Share rating to suggest at shift end, 1 to 5, or nil when there is
-- nothing to base it on (nothing owed, or numbers that are not usable). All of
-- it received is 5 stars, nothing is 1, and in between it scales with the part
-- received, rounded to the nearest star.
function M.prefill(owed, received)
  if not (finite(owed) and owed > 0 and finite(received) and received >= 0) then
    return nil
  end
  if received >= owed then
    return 5
  end
  if received == 0 then
    return 1
  end
  return math.max(1, math.min(5, math.floor(1 + 4 * received / owed + 0.5)))
end

ns.Ledger = M
