-- The events p's engine emitted with this name, and the last of them.
local function emitted(p, name)
  local out = {}
  for _, ev in ipairs(p.events) do
    if ev[1] == name then out[#out + 1] = ev end
  end
  return out
end
local function last(p, name)
  local list = emitted(p, name)
  return list[#list]
end

-- Decoded single-chunk messages on the bus whose type starts with `prefix`,
-- optionally from one sender.
local function wireOf(ns, w, prefix, sender)
  local out = {}
  for _, sent in ipairs(w.bus:sent()) do
    local text = sent.text:match("^[^:]+:1/1:(.*)$")
    local msg = text and ns.Protocol.decode(text)
    if msg and msg.type:sub(1, #prefix) == prefix and (sender == nil or sent.sender == sender) then
      msg.dist, msg.to = sent.dist, sent.target
      out[#out + 1] = msg
    end
  end
  return out
end

describe("clicker flow", function()
  local ns, w, lock, c1, c2, t
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 9, start = 70000}
    lock = w:addPlayer{name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan", money = 10000}
    c1 = w:addPlayer{name = "Cee One", class = "PRIEST", level = 40, place = "gadgetzan"}
    c2 = w:addPlayer{name = "Cee Two", class = "ROGUE", level = 40, place = "gadgetzan"}
    t = w:addPlayer{name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000}
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  -- p's engine handles a message from sender exactly as it would come off the wire.
  local function hear(p, sender, msgType, fields, dist)
    local msg = assert(ns.Protocol.decode(ns.Protocol.encode(msgType, "t1", fields)))
    p.engine:handle(msg, sender, dist or "CHANNEL")
  end

  -- Dar's stand with Cee One signed up at 25% and in the group.
  local function onShift()
    local s = lock.engine:openStand{kind = "lock", clickerPct = 25}
    assert.is_true(c1.engine:applyClicker(s.standId, 25)); w:advance(2)
    assert.is_true(lock.engine:respondClicker("Cee One", "ACCEPT")); w:advance(2)
    assert.is_true(w:acceptInvite("Cee One")); w:advance(1)
    assert.are.equal(25, c1.engine.shift.pct)
    return s
  end

  -- A ride of Tra Veler's on Dar's stand as Cee One hears it: start, arrival, the
  -- traveler's TIP and the warlock's TIP_ACK.
  local RIDE = "Dar Kbolt@Tra Veler@70010"
  local function tipped(tip, ack)
    hear(c1, "Tra Veler", "RIDE_START", {rideId = RIDE, warlock = "Dar Kbolt"})
    hear(c1, "Tra Veler", "ARRIVED", {rideId = RIDE, warlock = "Dar Kbolt"})
    hear(c1, "Tra Veler", "TIP", {rideId = RIDE, amount = tip}, "PARTY")
    hear(c1, "Dar Kbolt", "TIP_ACK", {rideId = RIDE, amount = ack}, "PARTY")
  end

  it("counter-offer agreed at 20%", function()
    local s = lock.engine:openStand{kind = "lock", clickerPct = 25}
    assert.is_true(c1.engine:applyClicker(s.standId, 30)); w:advance(2)
    local neg = last(lock, "CLICKER_APPLIED")[2]
    assert.are.same({"Cee One", 30, 25, "asked"}, {neg.clicker, neg.askedPct, neg.offeredPct, neg.state})
    assert.is_true(lock.engine:respondClicker("Cee One", "COUNTER", 20)); w:advance(2)
    local offer = last(c1, "CLICK_OFFER")[2]
    assert.are.same({20, "countered"}, {offer.pct, offer.state})
    assert.is_true(c1.engine:respondOffer(s.standId, true)); w:advance(2)
    assert.are.equal(20, lock.engine.stand.clickers["Cee One"].pct)
    assert.are.equal("Dar Kbolt", c1.invitedBy)
    w:advance(2)
    assert.are.same({s.standId, "Dar Kbolt", 20}, {c1.engine.shift.standId, c1.engine.shift.owner, c1.engine.shift.pct})
    assert.are.equal(c1.engine.shift, last(c1, "SHIFT_STARTED")[2])
    assert.are.equal(80, ns.Stand.ownerPct(lock.engine.stand))
    local ok = wireOf(ns, w, "CLICK_OK", "Dar Kbolt")
    assert.are.same({20, "WHISPER", "Cee One"}, {ok[1].agreedPct, ok[1].dist, ok[1].to})
  end)

  it("over-share refused", function()
    local s = lock.engine:openStand{kind = "lock", clickerPct = 25}
    c1.engine:applyClicker(s.standId, 60); c2.engine:applyClicker(s.standId, 50); w:advance(2)
    assert.is_true(lock.engine:respondClicker("Cee One", "ACCEPT"))
    assert.are.same({nil, "over_share"}, {lock.engine:respondClicker("Cee Two", "ACCEPT")})
    assert.are.same({nil, "over_share"}, {lock.engine:respondClicker("Cee Two", "COUNTER", 50)})
    assert.are.same({nil, "bad_action"}, {lock.engine:respondClicker("Cee Two", "CLICKER_ACCEPT")})
    assert.are.same({nil, "unknown_clicker"}, {lock.engine:respondClicker("Nob Ody", "ACCEPT")})
    assert.is_true(lock.engine:respondClicker("Cee Two", "COUNTER", 40)); w:advance(2)
    -- Meanwhile the owner gives 10% to a crew member, so when the clicker takes
    -- the 40% counter it no longer fits: refused.
    w:addPlayer{name = "Cee Three", class = "MAGE", level = 40, place = "gadgetzan"}
    lock.game:invite("Cee Three"); assert.is_true(w:acceptInvite("Cee Three"))
    assert.is_true(lock.engine:addOwnCrew("Cee Three", 10))
    c2.engine:respondOffer(s.standId, true); w:advance(2)
    assert.is_nil(lock.engine.stand.clickers["Cee Two"])
    w:advance(2)
    assert.is_nil(c2.engine.shift)
    assert.are.equal(1, #emitted(c2, "CLICK_DECLINED"))
  end)

  it("own crew without negotiation messages", function()
    local s = lock.engine:openStand{kind = "lock"}
    assert.are.same({nil, "not_in_group"}, {lock.engine:addOwnCrew("Cee One", 25)})
    lock.game:invite("Cee One"); assert.is_true(w:acceptInvite("Cee One"))
    assert.are.same({nil, "bad_pct"}, {lock.engine:addOwnCrew("Cee One", 100)})
    assert.are.same({nil, "is_owner"}, {lock.engine:addOwnCrew("Dar Kbolt", 25)})
    assert.is_true(lock.engine:addOwnCrew("Cee One", 30))
    assert.are.equal(30, s.clickers["Cee One"].pct)
    assert.are.same({{clicker = "Cee One", owed = 0, received = 0}}, lock.engine:payoutList())
    w:advance(2)
    assert.are.same({}, wireOf(ns, w, "CLICK"))
  end)

  it("disputed tip excluded from prefill", function()
    onShift()
    tipped(10000, 5000)
    local summary = c1.engine:leaveStand()
    local ended = last(c1, "SHIFT_ENDED")[2]
    assert.are.equal(summary, ended)
    assert.are.same({0, 0}, {ended.owed, ended.received})
    assert.is_nil(ended.prefill)
    assert.are.same({{rideId = RIDE, tip = 10000, ack = 5000}}, ended.disputed)
  end)

  it("paid in full prefills 5", function()
    onShift()
    tipped(10000, 10000)
    assert.is_true(w:trade("Dar Kbolt", "Cee One", 2500)); w:advance(1)
    c1.engine:leaveStand()
    local ended = last(c1, "SHIFT_ENDED")[2]
    assert.are.same({2500, 2500, 5, 25, "Dar Kbolt"}, {ended.owed, ended.received, ended.prefill, ended.pct, ended.owner})
    assert.are.same({}, ended.disputed)
  end)

  it("stay and click starts sign-up with the stand's share", function()
    local s = lock.engine:openStand{kind = "lock", clickerPct = 30}; w:advance(1)
    local ride = t.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest("Tra Veler#" .. s.standId); w:advance(2)
    w:acceptInvite("Tra Veler"); w:advance(1)
    assert.are.same({"Tra Veler"}, s.travelers)
    w:offerSummon("Dar Kbolt", "Tra Veler"); w:acceptSummon("Tra Veler"); w:advance(2)
    assert.is_true(t.engine:stayAndClick(ride.rideId)); w:advance(2)
    local neg = last(lock, "CLICKER_APPLIED")[2]
    assert.are.same({"Tra Veler", 30}, {neg.clicker, neg.askedPct})
    assert.is_true(lock.engine:respondClicker("Tra Veler", "ACCEPT")); w:advance(2)
    assert.are.same({}, s.travelers) -- the seat is given up for the clicker's place
    assert.are.equal(30, s.clickers["Tra Veler"].pct)
    assert.are.equal(30, t.engine.shift.pct)
  end)

  -- Beyond the brief --------------------------------------------------------------

  it("a traveler still waiting for the summon can't sign up (R19)", function()
    local s = lock.engine:openStand{kind = "lock"}; w:advance(1)
    t.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest("Tra Veler#" .. s.standId); w:advance(2)
    assert.is_true(t.engine:applyClicker(s.standId, 25)); w:advance(2)
    assert.are.same({}, emitted(lock, "CLICKER_APPLIED"))
    assert.are.equal(1, #wireOf(ns, w, "CLICK_NO", "Dar Kbolt"))
    assert.are.equal(1, #emitted(t, "CLICK_DECLINED"))
    assert.is_nil(t.engine.shift)
  end)

  it("applyClicker refuses what it can't send", function()
    local s = onShift()
    assert.are.same({nil, "unknown_stand"}, {c2.engine:applyClicker("nonsense", 25)})
    assert.are.same({nil, "bad_pct"}, {c2.engine:applyClicker(s.standId, 0)})
    assert.are.same({nil, "bad_pct"}, {c2.engine:applyClicker(s.standId, 12.5)})
    assert.are.same({nil, "own_stand"}, {lock.engine:applyClicker(s.standId, 25)})
    assert.are.same({nil, "no_offer"}, {c2.engine:respondOffer(s.standId, true)})
    assert.are.same({nil, "on_shift"}, {c1.engine:applyClicker(s.standId, 25)})
  end)

  it("a declined application tells the clicker", function()
    local s = lock.engine:openStand{kind = "lock"}
    c1.engine:applyClicker(s.standId, 40); w:advance(2)
    assert.is_true(lock.engine:respondClicker("Cee One", "DECLINE")); w:advance(2)
    assert.are.equal("declined", last(c1, "CLICK_DECLINED")[2].state)
    assert.is_nil(c1.engine.shift)
    assert.are.same({}, lock.engine.stand.clickers)
  end)

  it("leaveStand whispers CLICK_LEAVE; the owner ends the shift and the stand drops back", function()
    local s = onShift()
    assert.is_true(c2.engine:applyClicker(s.standId, 25)); w:advance(2)
    lock.engine:respondClicker("Cee Two", "ACCEPT"); w:advance(2)
    assert.is_true(w:acceptInvite("Cee Two")); w:advance(1)
    assert.are.equal("live", ns.Stand.status(s))
    assert.is_table(c1.engine:leaveStand()); w:advance(2)
    local leave = wireOf(ns, w, "CLICK_LEAVE", "Cee One")[1]
    assert.are.same({s.standId, "WHISPER", "Dar Kbolt"}, {leave.standId, leave.dist, leave.to})
    assert.is_nil(s.clickers["Cee One"])
    assert.are.equal("paused", ns.Stand.status(s))
    assert.is_number(lock.engine.ledgers[s.standId].shifts["Cee One"].leaveTs)
    assert.is_nil(c1.engine.shift)
    assert.are.same({nil, "not_on_shift"}, {c1.engine:leaveStand()})
  end)

  it("leaving the owner's group ends the shift", function()
    local s = onShift()
    c1.engine:leaveGroup(); w:advance(1)
    assert.is_nil(c1.engine.shift)
    assert.are.equal(1, #emitted(c1, "SHIFT_ENDED"))
    w:advance(1)
    assert.is_nil(s.clickers["Cee One"])
  end)

  it("the stand closing ends the shift", function()
    onShift()
    lock.engine:closeStand(); w:advance(1)
    assert.is_nil(c1.engine.shift)
    assert.are.equal(1, #emitted(c1, "SHIFT_ENDED"))
  end)

  it("a payment right after the shift updates its summary, and the Share rating carries it", function()
    onShift()
    tipped(10000, 10000)
    c1.engine:leaveStand()
    local ended = last(c1, "SHIFT_ENDED")[2]
    assert.are.same({2500, 0, 1}, {ended.owed, ended.received, ended.prefill})
    w:trade("Dar Kbolt", "Cee One", 2500); w:advance(1)
    assert.are.equal(2, #emitted(c1, "SHIFT_ENDED"))
    assert.are.equal(ended, last(c1, "SHIFT_ENDED")[2])
    assert.are.same({2500, 2500, 5}, {ended.owed, ended.received, ended.prefill})
    assert.are.same({nil, "unknown_shift"}, {c1.engine:submitShiftRating("nope", 5)})
    assert.is_true(c1.engine:submitShiftRating(ended.shiftId, 5)); w:advance(1)
    local r = wireOf(ns, w, "RATING", "Cee One")[1]
    assert.are.same({"share", "Dar Kbolt", 5, ended.shiftId, 2500, 2500, 25},
      {r.kind, r.target, r.stars, r.id, r.owed, r.received, r.pct})
    assert.are.equal(5, c2.engine:summary("Dar Kbolt", "share").stars)
  end)

  it("takes a TIP only from the ride's traveler for a known ride, capped, and a TIP_ACK only from the owner (R39)", function()
    onShift()
    local other = "Dar Kbolt@Oth Er@70011"
    hear(c1, "Tra Veler", "RIDE_START", {rideId = RIDE, warlock = "Dar Kbolt"})
    hear(c1, "Tra Veler", "ARRIVED", {rideId = RIDE, warlock = "Dar Kbolt"})
    hear(c1, "Oth Er", "TIP", {rideId = RIDE, amount = 1}, "PARTY")                 -- not the traveler
    hear(c1, "Oth Er", "TIP", {rideId = other, amount = 1}, "PARTY")                -- a ride never started
    hear(c1, "Tra Veler", "TIP", {rideId = RIDE, amount = 100000001}, "PARTY")      -- over the cap
    hear(c1, "Cee Two", "TIP_ACK", {rideId = RIDE, amount = 1}, "PARTY")            -- not the owner
    local l = c1.engine.ledgers[c1.engine.shift.standId]
    assert.are.same({}, l.tips)
    assert.are.same({}, l.acks)
    hear(c1, "Tra Veler", "TIP", {rideId = RIDE, amount = 10000}, "PARTY")
    hear(c1, "Dar Kbolt", "TIP_ACK", {rideId = RIDE, amount = 10000}, "PARTY")
    assert.are.equal(2500, (ns.Ledger.owed(l, "Cee One")))
  end)

  it("an ARRIVED that lands after an early TIP still counts the tip for the shift (R39)", function()
    onShift()
    hear(c1, "Tra Veler", "RIDE_START", {rideId = RIDE, warlock = "Dar Kbolt"})
    hear(c1, "Tra Veler", "TIP", {rideId = RIDE, amount = 10000}, "PARTY")
    hear(c1, "Dar Kbolt", "TIP_ACK", {rideId = RIDE, amount = 10000}, "PARTY")
    local l = c1.engine.ledgers[c1.engine.shift.standId]
    assert.are.equal(0, (ns.Ledger.owed(l, "Cee One")))
    hear(c1, "Tra Veler", "ARRIVED", {rideId = RIDE, warlock = "Dar Kbolt"})
    assert.are.equal(2500, (ns.Ledger.owed(l, "Cee One")))
  end)

  it("tells the clicker when the portal is up", function()
    local s = onShift()
    t.engine:requestRide(s.standId, 0); w:advance(2)
    lock.engine:acceptRequest("Tra Veler#" .. s.standId); w:advance(2)
    w:acceptInvite("Tra Veler"); w:advance(1)
    assert.are.equal("Tra Veler", lock.engine:nextTraveler()); w:advance(1)
    assert.are.equal(1, #emitted(c1, "PORTAL_UP"))
    assert.are.same({}, emitted(t, "PORTAL_UP")) -- a summon traveler doesn't click the portal
  end)
end)
