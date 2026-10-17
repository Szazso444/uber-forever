local _, ns = ...

-- One ride: a traveler's trip with one provider, a warlock summon (Ritual of
-- Summoning) or a mage portal. Both players' addons track it as this state
-- machine; the messages and game events that drive it belong to the layers above.
--
--   requested --ACCEPT--> accepted --JOINED--> grouped
--   requested --DECLINE--> declined
--   grouped --SUMMON_OFFERED (summon rides)--> summoning
--   grouped --PORTAL_UP (portal rides)--------> portal
--   summoning --SUMMON_FAILED--> grouped, once; the second failure cancels
--   summoning or portal --ARRIVED--> arrived --FINISHED--> done
--   any live state --CANCEL--> cancelled
--
-- done, declined and cancelled are final: nothing leaves them.
local M = {}

local FINAL = { done = true, declined = true, cancelled = true }

-- What each event needs. `from` lists the states it may arrive in (no `from`
-- means any state that is not final) and `to` the state it leads to. `kind`
-- limits it to summon or portal rides. `takesRideId` is ACCEPT, which brings
-- the rideId the driver made. `oneRetry` is SUMMON_FAILED: the first failure
-- goes back to `to` and spends the retry, the next cancels the ride.
local EVENTS = {
  ACCEPT = { from = { requested = true }, to = "accepted", takesRideId = true },
  DECLINE = { from = { requested = true }, to = "declined" },
  JOINED = { from = { accepted = true }, to = "grouped" },
  SUMMON_OFFERED = { from = { grouped = true }, to = "summoning", kind = "summon" },
  PORTAL_UP = { from = { grouped = true }, to = "portal", kind = "portal" },
  SUMMON_FAILED = { from = { summoning = true }, to = "grouped", oneRetry = true },
  ARRIVED = { from = { summoning = true, portal = true }, to = "arrived" },
  FINISHED = { from = { arrived = true }, to = "done" },
  CANCEL = { to = "cancelled" },
}

-- The id both sides can agree on without talking: who drives, who travels, and
-- when the ride was requested, in whole seconds (the clock may be fractional).
function M.makeId(driver, traveler, now)
  return driver .. "@" .. traveler .. "@" .. math.floor(now)
end

-- The driver and traveler an id from makeId names, or nil for anything not in
-- the driver@traveler@seconds form. Ids come off the wire, so nothing about
-- them is trusted: the caller still checks the names against the sender.
function M.parseId(id)
  if type(id) ~= "string" then
    return nil
  end
  local driver, traveler = id:match("^([^@]+)@([^@]+)@%d+$")
  if driver == nil then
    return nil
  end
  return driver, traveler
end

-- `o`: rideId (nil until the driver accepts), kind ("summon" or "portal"),
-- driver, traveler, standId, offer (the tip offered, in copper), dest and now.
function M.new(o)
  return {
    rideId = o.rideId,
    kind = o.kind,
    driver = o.driver,
    traveler = o.traveler,
    standId = o.standId,
    offer = o.offer,
    dest = o.dest,
    state = "requested",
    retries = 0,
    times = { requested = o.now },
  }
end

-- Applies `event` to `r` at time `now` and stamps `r.times[newState]`. A state
-- entered again (grouped after a failed summon) gets its newer time. `data` is
-- only read by ACCEPT, which needs `data.rideId` (a string) and stores it.
-- Returns true, or nil plus "bad_transition" when the event does not fit the
-- ride's state or kind, or ACCEPT has no rideId. A failed call leaves `r`
-- untouched.
function M.apply(r, event, now, data)
  local rule = EVENTS[event]
  if rule == nil or FINAL[r.state] then
    return nil, "bad_transition"
  end
  if rule.from ~= nil and not rule.from[r.state] then
    return nil, "bad_transition"
  end
  if rule.kind ~= nil and rule.kind ~= r.kind then
    return nil, "bad_transition"
  end
  local rideId
  if rule.takesRideId then
    rideId = type(data) == "table" and data.rideId
    if type(rideId) ~= "string" then
      return nil, "bad_transition"
    end
  end

  -- Every check has passed, so from here on the ride changes.
  local to = rule.to
  if rule.oneRetry then
    if r.retries == 0 then
      r.retries = 1
    else
      to = "cancelled"
    end
  end
  if rideId ~= nil then
    r.rideId = rideId
  end
  r.state = to
  r.times[to] = now
  return true
end

-- Whether the ride has ended (done, declined or cancelled).
function M.isFinal(r)
  return FINAL[r.state] == true
end

ns.Ride = M
