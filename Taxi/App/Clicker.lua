local _, ns = ...

-- Clicker: clicking a warlock's summoning portal for a share of the tips, as
-- methods and handlers on the Engine. The clicker applies to a stand, haggles
-- over the share, keeps its own ledger of the tips while on shift, and rates
-- the warlock's Share at the end of the shift.
--
-- Nobody's word is taken for the tips: a tip counts once the traveler's TIP
-- and the warlock's TIP_ACK agree (Ledger). A TIP is taken only from the
-- ride's own traveler and a TIP_ACK only from the stand's owner, both only for
-- a ride of that owner whose start this client heard from its traveler (the
-- witness keeps those), and never above Config.MAX_TIP (R39).
--
-- State on the Engine:
--   application  the Negotiation of my pending sign-up, or nil
--   shift        { standId, owner, pct, shiftId, joinTs, inGroup, arrivedTs }
--   lastShift    the summary of the shift that ended last
--   endedShifts  shiftId -> summary, for the Share rating
--
-- Pure Lua: no WoW API (this file is also loaded in-game for /taxi sim).
local Engine, Config, Names = ns.Engine, ns.Config, ns.Names
local Board, Ride, Negotiation, Ledger, Ratings = ns.Board, ns.Ride, ns.Negotiation, ns.Ledger, ns.Ratings

-- The most a share can be. The owner's share left is only known on the
-- owner's side, so here a share is only checked to be a share.
local MAX_PCT = 99

-- True only for a real, finite number (not nil, not NaN, not +-infinity).
local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function tipAmount(x)
  return finite(x) and x >= 0 and x <= Config.MAX_TIP
end

-- The owner a stand id names (ids are owner@seconds, R41), or nil.
local function idOwner(standId)
  return type(standId) == "string" and standId:match("^(.+)@%d+$") or nil
end

local function endedShifts(e)
  local t = e.endedShifts
  if t == nil then
    t = {}
    e.endedShifts = t
  end
  return t
end

-- True when rideId is a ride of my shift's owner whose start I heard from
-- `traveler` (R39: TIPs for unknown rides are ignored).
local function ownersRide(e, shift, rideId, traveler)
  local driver, rider = Ride.parseId(rideId)
  if not (Names.same(driver, shift.owner) and Names.same(rider, traveler)) then
    return false
  end
  local heard = e.witness.rides[rideId]
  return heard ~= nil and Names.same(heard.victim, traveler) and Names.same(heard.warlock, shift.owner)
end

-- Signing up -----------------------------------------------------------------------------

-- Asks the stand's owner to let me click for askedPct of every tip. The stand
-- need not be on my board yet: its id names its owner. Returns true, or nil and
-- "disabled", "dead", "unknown_stand", "own_stand", "mage" (portal stands have
-- no clickers), "bad_pct" or "on_shift".
Engine.applyClicker = Engine.action(function(e, standId, askedPct)
  local view = type(standId) == "string" and Board.get(e.board, standId) or nil
  local owner = Names.normalize(view and view.owner or idOwner(standId))
  if owner == nil or owner == "" then
    return nil, "unknown_stand"
  end
  if Names.same(owner, e.me) then
    return nil, "own_stand"
  end
  if view and view.kind == "mage" then
    return nil, "mage"
  end
  if not Negotiation.validPct(askedPct, MAX_PCT) then
    return nil, "bad_pct"
  end
  if e.shift ~= nil then
    return nil, "on_shift"
  end
  e.application = Negotiation.new{
    standId = standId, owner = owner, clicker = Names.normalize(e.me),
    offeredPct = view and view.clickerPct or nil, askedPct = askedPct,
  }
  e:send("CLICK_APPLY", { standId = standId, askedPct = askedPct }, "WHISPER", owner)
  return true
end)

-- The application to standId, when sender is that stand's owner.
local function applicationFrom(e, standId, sender)
  local neg = e.application
  if neg ~= nil and neg.standId == standId and Names.same(sender, neg.owner) then
    return neg
  end
  return nil
end

-- The owner counters with another share.
Engine.handlers.CLICK_OFFER = function(e, msg, sender)
  local neg = applicationFrom(e, msg.standId, sender)
  if neg ~= nil and Negotiation.apply(neg, "COUNTER", msg.offeredPct, MAX_PCT) then
    e:emit("CLICK_OFFER", neg)
  end
end

-- Takes (accept true) or turns down the owner's counter-offer. Returns true,
-- or nil and "no_offer".
Engine.respondOffer = Engine.action(function(e, standId, accept)
  local neg = e.application
  if neg == nil or neg.standId ~= standId or neg.state ~= "countered" then
    return nil, "no_offer"
  end
  if accept then
    Negotiation.apply(neg, "CLICKER_ACCEPT", nil, MAX_PCT)
    e:send("CLICK_OK", { standId = standId, agreedPct = neg.pct }, "WHISPER", neg.owner)
  else
    Negotiation.apply(neg, "DECLINE", nil, MAX_PCT)
    e.application = nil
    e:send("CLICK_NO", { standId = standId }, "WHISPER", neg.owner)
  end
  return true
end)

-- The owner confirms the deal at the share both sides agreed: my shift starts.
Engine.handlers.CLICK_OK = function(e, msg, sender)
  local neg = applicationFrom(e, msg.standId, sender)
  if neg == nil or msg.agreedPct ~= neg.pct then
    return
  end
  if neg.state == "asked" then
    Negotiation.apply(neg, "ACCEPT", nil, MAX_PCT) -- the owner took my ask
  end
  if neg.state ~= "agreed" then
    return
  end
  local l = e.ledgers[neg.standId] or Ledger.new(neg.standId, neg.owner)
  local shift = l and Ledger.join(l, e.me, neg.pct, e.clock:now())
  if not shift then
    return
  end
  e.ledgers[neg.standId] = l
  e.application = nil
  e.shift = {
    standId = neg.standId, owner = neg.owner, pct = neg.pct, shiftId = shift.shiftId, joinTs = shift.joinTs,
    inGroup = e:inGroup(neg.owner), arrivedTs = {},
  }
  e:emit("SHIFT_STARTED", e.shift)
end

-- The owner said no (to the application, or to my taking the counter-offer).
Engine.handlers.CLICK_NO = function(e, msg, sender)
  local neg = applicationFrom(e, msg.standId, sender)
  if neg ~= nil then
    Negotiation.apply(neg, "DECLINE", nil, MAX_PCT)
    e.application = nil
    e:emit("CLICK_DECLINED", neg)
  end
end

-- The shift ------------------------------------------------------------------------------

-- Owed (agreed tips only), received, the Share stars to suggest, and the
-- disputed tips, as the ledger has them now.
local function tally(e, summary)
  local l = e.ledgers[summary.standId]
  local owed, disputed = Ledger.owed(l, e.me)
  summary.owed, summary.disputed = owed, disputed
  summary.received = Ledger.receivedBy(l, e.me)
  summary.prefill = Ledger.prefill(summary.owed, summary.received)
end

-- Ends my shift (telling the owner with CLICK_LEAVE when `tell`) and emits
-- SHIFT_ENDED with its summary {shiftId, standId, owner, pct, owed, received,
-- prefill, disputed}. Returns the summary.
local function endShift(e, tell)
  local shift = e.shift
  e.shift = nil
  if tell then
    e:send("CLICK_LEAVE", { standId = shift.standId }, "WHISPER", shift.owner)
  end
  Ledger.leave(e.ledgers[shift.standId], e.me, e.clock:now())
  local summary = { shiftId = shift.shiftId, standId = shift.standId, owner = shift.owner, pct = shift.pct }
  tally(e, summary)
  e.lastShift = summary
  endedShifts(e)[shift.shiftId] = summary
  e:emit("SHIFT_ENDED", summary)
  return summary
end

-- Stops clicking. Returns the shift's summary, or nil and "not_on_shift".
Engine.leaveStand = Engine.action(function(e)
  if e.shift == nil then
    return nil, "not_on_shift"
  end
  return endShift(e, true)
end)

-- Leaving the owner's group (after having been in it) ends the shift.
Engine.gameHandlers.GROUP_CHANGED = function(e)
  local shift = e.shift
  if shift == nil then
    return
  end
  if e:inGroup(shift.owner) then
    shift.inGroup = true
  elseif shift.inGroup then
    endShift(e, true)
  end
end

-- The stand closing ends the shift, and any application to it.
Engine.handlers.STAND_END = function(e, msg, sender)
  local shift = e.shift
  if shift ~= nil and msg.standId == shift.standId and Names.same(sender, shift.owner) then
    endShift(e, false)
  end
  local neg = applicationFrom(e, msg.standId, sender)
  if neg ~= nil then
    e.application = nil
    e:emit("CLICK_DECLINED", neg)
  end
end

-- The owner's portal is up: click it.
Engine.handlers.PORTAL_UP = function(e, msg, sender)
  if e.shift ~= nil and Names.same(sender, e.shift.owner) then
    e:emit("PORTAL_UP", msg.dest)
  end
end

-- A traveler of my owner arrived. A tip heard earlier now counts for the
-- shift it arrived in (R39).
Engine.handlers.ARRIVED = function(e, msg, sender)
  local shift = e.shift
  if shift == nil or not Names.same(msg.warlock, shift.owner) or not ownersRide(e, shift, msg.rideId, sender) then
    return
  end
  local at = shift.arrivedTs[msg.rideId]
  if at == nil then
    at = e.clock:now()
    shift.arrivedTs[msg.rideId] = at
  end
  local l = e.ledgers[shift.standId]
  local tip = l.tips[msg.rideId]
  if tip ~= nil and tip.arrivedTs == nil then
    Ledger.tip(l, msg.rideId, tip.amount, at)
  end
end

-- The traveler's report of their tip.
Engine.handlers.TIP = function(e, msg, sender)
  local shift = e.shift
  if shift == nil or not tipAmount(msg.amount) or not ownersRide(e, shift, msg.rideId, sender) then
    return
  end
  Ledger.tip(e.ledgers[shift.standId], msg.rideId, msg.amount, shift.arrivedTs[msg.rideId])
end

-- The owner's report of the tip they got.
Engine.handlers.TIP_ACK = function(e, msg, sender)
  local shift = e.shift
  if shift == nil or not Names.same(sender, shift.owner) or not tipAmount(msg.amount) then
    return
  end
  local _, traveler = Ride.parseId(msg.rideId)
  if traveler ~= nil and ownersRide(e, shift, msg.rideId, traveler) then
    Ledger.ack(e.ledgers[shift.standId], msg.rideId, msg.amount)
  end
end

-- Copper the owner gave me in a trade is my pay. Pay often comes right after
-- the shift, so it also counts for the shift that just ended, whose summary
-- is brought up to date and shown again (SHIFT_ENDED).
Engine.gameHandlers.TRADE_DONE = function(e, partner, _, got)
  if not (finite(got) and got > 0) then
    return
  end
  local shift = e.shift
  if shift ~= nil and Names.same(partner, shift.owner) then
    Ledger.received(e.ledgers[shift.standId], e.me, got)
    return
  end
  local last = e.lastShift
  if last ~= nil and Names.same(partner, last.owner) then
    Ledger.received(e.ledgers[last.standId], e.me, got)
    tally(e, last)
    e:emit("SHIFT_ENDED", last)
  end
end

-- The Share rating for an ended shift, sent with its ledger summary as proof.
-- Returns true, or nil and "unknown_shift" or a Ratings reason.
Engine.submitShiftRating = Engine.action(function(e, shiftId, stars)
  local summary = type(shiftId) == "string" and endedShifts(e)[shiftId] or nil
  if summary == nil then
    return nil, "unknown_shift"
  end
  local now = e.clock:now()
  local rating = {
    kind = "share", rater = Names.normalize(e.me), target = summary.owner, stars = stars, id = shiftId,
    ts = math.floor(now), owed = summary.owed, received = summary.received, pct = summary.pct,
  }
  local ok, why = Ratings.give(e.db, rating, now)
  if not ok then
    return nil, why
  end
  e.dirty = true
  e:send("RATING", rating, "CHANNEL")
  return true
end)
