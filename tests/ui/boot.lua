-- A world for the window specs (dialogs_spec, summon_ui_spec, sim_spec): the
-- real UI files on the strict fake frame API (fake_ui.lua), one player's real
-- Engine behind them, and the other players acting through their own engines.
--
--   local boot = dofile("tests/ui/boot.lua")
--   local t = boot("me", { trusted = true })
--   t.ns, t.w (the World), t.ui, t.Main
--   t.lock  Dar Kbolt, a level 45 warlock at Gadgetzan, guild "Crew"
--   t.me    Tra Veler, a level 44 hunter in Ironforge with 5g, guild "Crew"
--   t.c1, t.c2  Cee One (priest) and Cee Two (rogue) at Gadgetzan
--   t.mage  Mag Ic, a mage at Gadgetzan
-- `viewer` is the key of the player whose Engine the window shows; the window
-- is started the way Core/Init starts it. With opts.trusted the viewer knows
-- five 5-star ratings of Dar Kbolt, so a summon from him can be GREEN (a
-- warlock nobody has rated is "New", and the guard warns about that).
local FakeUI = dofile("tests/ui/fake_ui.lua")

local function trustedDb(ns, warlock, now)
  local db = ns.Store.init(nil)
  for i = 1, 5 do
    local rater = "Old Rider" .. string.char(96 + i)
    local ts = now - 100 * i
    assert(ns.Ratings.addDirect(db, { kind = "trust", rater = rater, target = warlock, stars = 5,
      id = ns.Ride.makeId(warlock, rater, ts), ts = ts }, rater, now))
  end
  return db
end

return function(viewer, opts)
  opts = opts or {}
  local ns = Taxi.load()
  local w = ns.World.new{ seed = 5, start = 50000 }
  local t = { ns = ns, w = w }
  t.lock = w:addPlayer{ name = "Dar Kbolt", class = "WARLOCK", level = 45, place = "gadgetzan", guild = "Crew" }
  t.me = w:addPlayer{ name = "Tra Veler", class = "HUNTER", level = 44, place = "ironforge", money = 50000,
    guild = "Crew", db = opts.trusted and trustedDb(ns, "Dar Kbolt", 50000) or nil }
  t.c1 = w:addPlayer{ name = "Cee One", class = "PRIEST", level = 40, place = "gadgetzan" }
  t.c2 = w:addPlayer{ name = "Cee Two", class = "ROGUE", level = 40, place = "gadgetzan" }
  t.mage = w:addPlayer{ name = "Mag Ic", class = "MAGE", level = 45, place = "gadgetzan" }

  t.ui = FakeUI.new()
  t.ui.load(ns)
  local p = ({ lock = t.lock, me = t.me, c1 = t.c1, c2 = t.c2, mage = t.mage })[viewer]
  ns.engine, ns.db = p.engine, p.db
  t.Main = ns.UI.Main
  t.Main:Start()

  -- p opens a stand and the others hear it.
  function t.standOf(who, o)
    local stand = assert(who.engine:openStand(o or { kind = "lock" }))
    w:advance(2)
    return stand
  end

  -- `who` asks the stand for a ride (offering `offer`), its owner accepts, and
  -- `who` joins the owner's group. Returns who's ride.
  function t.groupUp(who, stand, offer, owner, dest)
    owner = owner or t.lock
    local ride = assert(who.engine:requestRide(stand.standId, offer or 0, dest))
    w:advance(2)
    assert(owner.engine:acceptRequest(who.name .. "#" .. stand.standId))
    w:advance(2)
    assert(w:acceptInvite(who.name), "no invite for " .. who.name)
    w:advance(1)
    assert(ride.state == "grouped", "the ride is " .. ride.state)
    return ride
  end

  -- Decoded single-chunk messages of one type on the bus, optionally from one sender.
  function t.wireOf(msgType, sender)
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

  -- Every visible text shows "|" only doubled (R14). (Plain asserts: this file
  -- runs outside busted's environment.)
  function t.noRawPipes()
    for _, text in ipairs(t.ui:texts()) do
      local rest = text:gsub("||", "")
      assert(rest:find("|", 1, true) == nil, text)
    end
  end

  -- p's engine handles a message from sender as it would come off the wire.
  function t.hear(who, sender, msgType, fields, dist)
    local msg = assert(ns.Protocol.decode(ns.Protocol.encode(msgType, "t1", fields)))
    who.engine:handle(msg, sender, dist or "WHISPER")
  end

  return t
end
