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

-- Decoded single-chunk messages of one type on the bus, optionally from one sender.
local function wireOf(ns, w, msgType, sender)
  local out = {}
  for _, sent in ipairs(w.bus:sent()) do
    local text = sent.text:match("^[^:]+:1/1:(.*)$")
    local msg = text and ns.Protocol.decode(text)
    if msg and msg.type == msgType and (sender == nil or sent.sender == sender) then
      msg.dist, msg.to = sent.dist, sent.target
      out[#out + 1] = msg
    end
  end
  return out
end

describe("portal flow", function()
  local ns, w, mage, t
  before_each(function()
    ns = Taxi.load(); w = ns.World.new{seed = 7, start = 60000}
    mage = w:addPlayer{name = "Mag Ister", class = "MAGE", level = 50, place = "ironforge"}
    t = w:addPlayer{name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000}
  end)
  after_each(function() assert.are.same({}, w.errors) end)

  -- Opens the mage's stand and brings the traveler's ride to Stormwind as far as grouped.
  local function grouped()
    local s = mage.engine:openStand{kind = "mage", seats = 3}; w:advance(1)
    local ride = t.engine:requestRide(s.standId, 5000, "stormwind"); w:advance(2)
    assert.is_string(mage.engine:acceptRequest("Tra Veler#" .. s.standId)); w:advance(2)
    assert.is_true(w:acceptInvite("Tra Veler")); w:advance(1)
    assert.are.equal("grouped", ride.state)
    return s, ride
  end

  it("mage stand lists known portals", function()
    local s = mage.engine:openStand{kind = "mage", seats = 3}
    assert.are.same({"stormwind", "ironforge", "darnassus"}, s.portals)
    w:advance(1)
    local view = ns.Board.get(t.engine.board, s.standId)
    assert.are.equal("mage", view.kind)
    assert.are.same({"stormwind", "ironforge", "darnassus"}, view.portals)
  end)

  it("request → accept → invite → castPortal → usePortal → ARRIVED → tip", function()
    local s, ride = grouped()
    assert.are.same({"portal", "stormwind", 5000}, {ride.kind, ride.dest, ride.offer})
    assert.are.equal("stormwind", mage.engine.rides["Tra Veler#" .. s.standId].dest)
    assert.are.same({}, wireOf(ns, w, "RIDE_START")) -- portal rides are not witnessed
    assert.are.equal("Tra Veler", mage.engine:nextTraveler()); w:advance(1)
    local up = wireOf(ns, w, "PORTAL_UP", "Mag Ister")[1]
    assert.are.same({"stormwind", "PARTY"}, {up.dest, up.dist})
    assert.are.equal("portal", ride.state)
    assert.are.same({"PORTAL_UP", "stormwind"}, last(t, "PORTAL_UP"))
    assert.is_true(w:castPortal("Mag Ister", "stormwind"))
    assert.is_true(w:usePortal("Tra Veler", "stormwind"))
    assert.are.equal("arrived", ride.state)
    assert.are.same({"ARRIVED", ride}, last(t, "ARRIVED"))
    w:advance(2)
    assert.are.equal("arrived", mage.engine.rides["Tra Veler#" .. s.standId].state)
    local arrived = wireOf(ns, w, "ARRIVED", "Tra Veler") -- on the channel, and by whisper to the mage (R50)
    assert.are.same({{"CHANNEL", nil}, {"WHISPER", "Mag Ister"}}, {{arrived[1].dist, arrived[1].to}, {arrived[2].dist, arrived[2].to}})
    assert.are.equal(2, #arrived)
    assert.is_true(t.engine:submitArrival(ride.rideId, nil, 5000))
    assert.are.equal("Mag Ister", t.tradeWith)
    assert.is_true(w:trade("Tra Veler", "Mag Ister", 5000)); w:advance(2)
    assert.are.equal("done", ride.state)
    assert.are.equal(5000, wireOf(ns, w, "TIP", "Tra Veler")[1].amount)
    assert.are.equal(5000, wireOf(ns, w, "TIP_ACK", "Mag Ister")[1].amount)
    assert.are.same({}, wireOf(ns, w, "RATING"))
    assert.are.same({}, wireOf(ns, w, "RIDE_LOG")) -- nothing to rate, so nothing to prove
  end)

  it("Open portal moves the mage's ride to portal; an ARRIVED before that is ignored (R52)", function()
    local s, ride = grouped()
    local mine = mage.engine.rides["Tra Veler#" .. s.standId]
    t.engine:send("ARRIVED", {rideId = ride.rideId, warlock = "Mag Ister"}, "WHISPER", "Mag Ister"); w:advance(2)
    assert.are.equal("grouped", mine.state)
    assert.are.equal("Tra Veler", mage.engine:nextTraveler())
    assert.are.equal("portal", mine.state)
    w:advance(1)
    assert.is_true(w:castPortal("Mag Ister", "stormwind"))
    assert.is_true(w:usePortal("Tra Veler", "stormwind")); w:advance(2)
    assert.are.equal("arrived", mine.state)
  end)

  it("one Open portal serves every rider to that city: both arrive on the mage's side and both tips are acknowledged (R70)", function()
    local t2 = w:addPlayer{name = "Tre Two", class = "PRIEST", level = 40, place = "ironforge", money = 50000}
    local s = mage.engine:openStand{kind = "mage", seats = 3}; w:advance(1)
    local rides = {}
    for _, p in ipairs{t, t2} do
      rides[p.name] = assert(p.engine:requestRide(s.standId, 5000, "stormwind"))
    end
    w:advance(2)
    for _, p in ipairs{t, t2} do
      assert.is_string(mage.engine:acceptRequest(p.name .. "#" .. s.standId))
    end
    w:advance(2)
    for _, p in ipairs{t, t2} do assert.is_true(w:acceptInvite(p.name)) end
    w:advance(1)
    local function mine(p) return mage.engine.rides[p.name .. "#" .. s.standId] end
    assert.are.equal("Tra Veler", mage.engine:nextTraveler()) -- Open portal, once
    assert.are.same({"portal", "portal"}, {mine(t).state, mine(t2).state})
    w:advance(1)
    assert.is_true(w:castPortal("Mag Ister", "stormwind"))
    for _, p in ipairs{t, t2} do assert.is_true(w:usePortal(p.name, "stormwind")) end
    w:advance(2)
    assert.are.same({"arrived", "arrived"}, {mine(t).state, mine(t2).state})
    for _, p in ipairs{t, t2} do
      assert.is_true(p.engine:submitArrival(rides[p.name].rideId, nil, 5000))
      assert.is_true(w:trade(p.name, "Mag Ister", 5000)); w:advance(2)
    end
    assert.are.equal(2, #wireOf(ns, w, "TIP_ACK", "Mag Ister"))
    assert.are.same({"done", "done"}, {mine(t).state, mine(t2).state})
  end)

  it("Open portal moves only the riders to that city (R70)", function()
    local t2 = w:addPlayer{name = "Tre Two", class = "PRIEST", level = 40, place = "ironforge"}
    local s = mage.engine:openStand{kind = "mage", seats = 3}; w:advance(1)
    t.engine:requestRide(s.standId, 0, "stormwind"); t2.engine:requestRide(s.standId, 0, "darnassus"); w:advance(2)
    for _, p in ipairs{t, t2} do assert.is_string(mage.engine:acceptRequest(p.name .. "#" .. s.standId)) end
    w:advance(2)
    for _, p in ipairs{t, t2} do assert.is_true(w:acceptInvite(p.name)) end
    w:advance(1)
    assert.are.equal("Tra Veler", mage.engine:nextTraveler())
    assert.are.same({"portal", "grouped"},
      {mage.engine.rides["Tra Veler#" .. s.standId].state, mage.engine.rides["Tre Two#" .. s.standId].state})
  end)

  it("stars rejected for portal rides", function()
    local _, ride = grouped()
    mage.engine:nextTraveler(); w:advance(1)
    w:castPortal("Mag Ister", "stormwind"); w:usePortal("Tra Veler", "stormwind")
    assert.are.same({nil, "no_rating_for_portals"}, {t.engine:submitArrival(ride.rideId, 5)})
    assert.are.same({}, t.db.given)
  end)

  -- Beyond the brief --------------------------------------------------------------

  it("refuses a destination the stand doesn't offer", function()
    local s = mage.engine:openStand{kind = "mage"}; w:advance(1)
    assert.are.same({nil, "bad_dest"}, {t.engine:requestRide(s.standId, 0, "orgrimmar")})
    assert.are.same({nil, "bad_dest"}, {t.engine:requestRide(s.standId, 0)})
  end)

  it("a portal stand has no clickers", function()
    local s = mage.engine:openStand{kind = "mage"}; w:advance(1)
    assert.are.same({nil, "mage"}, {t.engine:applyClicker(s.standId, 25)})
  end)

  it("arrives only in the city the ride was for", function()
    local _, ride = grouped()
    mage.engine:nextTraveler(); w:advance(1)
    w:moveTo("Tra Veler", "gadgetzan")
    assert.are.equal("portal", ride.state)
    w:moveTo("Tra Veler", "stormwind")
    assert.are.equal("arrived", ride.state)
  end)

  it("a PORTAL_UP to another city or from someone else leaves the ride waiting", function()
    local _, ride = grouped()
    mage.engine:send("PORTAL_UP", {dest = "darnassus"}, "PARTY"); w:advance(1)
    assert.are.equal("grouped", ride.state)
    local other = w:addPlayer{name = "Oth Er", class = "MAGE", level = 50, place = "ironforge"}
    mage.game:invite("Oth Er"); assert.is_true(w:acceptInvite("Oth Er"))
    other.engine:send("PORTAL_UP", {dest = "stormwind"}, "PARTY"); w:advance(1)
    assert.are.equal("grouped", ride.state)
    assert.are.same({}, emitted(t, "PORTAL_UP"))
  end)
end)
