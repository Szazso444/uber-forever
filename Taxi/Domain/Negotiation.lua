local _, ns = ...

-- A clicker's share of the tips, agreed between a stand's owner and the clicker.
-- A small state machine, pure data and rules; the messages that carry the events
-- between the two players belong to the layers above.
--
--   asked --ACCEPT--------------> agreed
--   asked --COUNTER pct---------> countered --CLICKER_ACCEPT--> agreed
--   asked or countered --DECLINE--> declined
--
-- The owner keeps what the clickers leave over, so a share is only agreed while
-- it fits in what the owner has left (`available`, from Stand.ownerPct).
local M = {}

-- What each event needs. `from` lists the states it may arrive in and `to` the
-- state it leads to. `share` says which share must fit before it is allowed:
-- "current" is n.pct (the share on the table), "given" is the event's own pct;
-- no `share` means the event needs no check.
local EVENTS = {
  ACCEPT = { from = { asked = true }, to = "agreed", share = "current" },
  COUNTER = { from = { asked = true }, to = "countered", share = "given" },
  CLICKER_ACCEPT = { from = { countered = true }, to = "agreed", share = "current" },
  DECLINE = { from = { asked = true, countered = true }, to = "declined" },
}

-- `o`: standId, owner, clicker, offeredPct (what the stand advertised) and
-- askedPct (what the clicker asks for, which is where the haggling starts).
function M.new(o)
  return {
    standId = o.standId,
    owner = o.owner,
    clicker = o.clicker,
    offeredPct = o.offeredPct,
    askedPct = o.askedPct,
    state = "asked",
    pct = o.askedPct,
  }
end

-- Whether `pct` can be agreed while the owner has `available` percent left.
-- Returns true, or nil plus why not: "bad_pct" (not a whole number from 1 to 99,
-- the same rule as Stand.addClicker) or "over_share" (more than `available`).
function M.validPct(pct, available)
  if type(pct) ~= "number" or pct ~= math.floor(pct) or pct < 1 or pct > 99 then
    return nil, "bad_pct"
  end
  if pct > available then
    return nil, "over_share"
  end
  return true
end

-- Applies `event` to `n`: "ACCEPT" (the owner takes the asked share), "COUNTER"
-- (the owner proposes `pct`), "CLICKER_ACCEPT" (the clicker takes the countered
-- share) or "DECLINE" (either side walks away). `available` is the owner's
-- share before this clicker is added. Returns true, or nil plus why not:
-- "bad_state" (the event does not fit the negotiation's state), "bad_pct" or
-- "over_share" (see validPct). A failed call leaves `n` untouched.
function M.apply(n, event, pct, available)
  local rule = EVENTS[event]
  if rule == nil or not rule.from[n.state] then
    return nil, "bad_state"
  end
  local agreed = n.pct
  if rule.share == "given" then
    agreed = pct
  end
  if rule.share ~= nil then
    local ok, why = M.validPct(agreed, available)
    if not ok then
      return nil, why
    end
  end
  n.state = rule.to
  n.pct = agreed
  return true
end

ns.Negotiation = M
