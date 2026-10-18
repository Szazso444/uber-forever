local _, ns = ...

-- /taxi sim: a made-up world to click the whole addon through alone, with no
-- group. The simulation (Taxi/Sim) is the one the tests use: every player has
-- a real Engine on a fake game and a fake message bus.
--
-- The local player becomes "You", a level 60 Hardcore hunter with 100g, in
-- Ironforge, and ns.engine is bound to You's Engine, so the real window, the
-- request dialog, the guard panel and the arrival window all drive it. The
-- other players:
--   Dar Kbolt   a guildmate's warlock stand at Gadgetzan, well rated, Cee One on his crew
--   Ann Other   a warlock stand in Searing Gorge, little rated, with a reported death
--   Mag Ic      a mage's portal stand in Ironforge (Stormwind, Ironforge, Darnassus)
--   Cee One, Cee Two   clickers (Cee Two is the one "Clicker applies" brings)
--   Stan Ger    a stranger, for the summon nobody asked for
-- The other side of every flow is yours to answer: the sim players get the same
-- windows You has (the driver toast, the clicker offer, the shift-end window),
-- marked "(sim)" in their title, and the "Sim controls" buttons do what they
-- would do in the world (cast, trade, leave, die). Accepting a summon,
-- opening the trade and putting the gold in it stay yours, as in the game.
--
-- The simulation's clock runs on the screen's: one OnUpdate advances it by the
-- time that passed. While the sim runs the real Engine is muted (Engine:mute),
-- so nothing reaches the real channel, and the real windows are quiet; /taxi
-- sim off puts everything back. The sim's data is never saved.
local L, Money, Names = ns.L, ns.Money, ns.Names
local UI = ns.UI
local W = UI.Widgets

local M = {}
UI.Sim = M

local YOU, DAR, ANN, CEE1, CEE2, MAG, STAN = "You", "Dar Kbolt", "Ann Other", "Cee One", "Cee Two", "Mag Ic", "Stan Ger"
local TICK = 0.1 -- the sim clock moves at least this often (seconds of screen time)
local MAX_STEP = 1 -- and by no more than this at once, so a stall doesn't make the world race
local CLICKER_ASK = 40 -- the share Cee Two asks for (the stand offers 25)

local function say(text)
  print(L.CHAT_PREFIX .. text)
end

function M.active()
  return M.state ~= nil
end

-- Time passing --------------------------------------------------------------------------------

-- Moves the world's clock on. The world's players (but You) accept the group
-- invites they get, as the made-up people they are; You is asked by the
-- "Accept invite" button. Engine errors of the sim go to the real Engine's log.
local function step(s, seconds)
  local world = s.world
  world:advance(seconds)
  local joined = false
  for name, p in pairs(world.players) do
    if name ~= YOU and p.invitedBy ~= nil then
      joined = world:acceptInvite(name) or joined
    end
  end
  if joined then
    world:advance(1)
  end
  if #world.errors > 0 then
    for _, line in ipairs(world.errors) do
      pcall(s.real.log, "sim: " .. tostring(line))
    end
    world.errors = {}
  end
end

-- Building the world ------------------------------------------------------------------------

-- Ratings You has heard of, so the board shows both a trusted warlock (Dar:
-- six summons, five or more make a rating established, so his summon can be
-- GREEN) and a doubtful one (Ann: three, "New", and a reported death).
local function seedRatings(world, db)
  local now = world.clock:now()
  local function trust(target, rater, stars, ts)
    assert(ns.Ratings.addDirect(db, {
      kind = "trust", rater = rater, target = target, stars = stars, id = ns.Ride.makeId(target, rater, ts), ts = ts,
    }, rater, now))
  end
  for i, stars in ipairs({ 5, 5, 4, 5, 4, 5 }) do
    trust(DAR, "Old Rider" .. string.char(96 + i), stars, now - 86400 + i)
  end
  for i = 1, 3 do
    trust(ANN, "New Rider" .. string.char(96 + i), 4, now - 86400 + i)
  end
  local ts = now - 3000
  assert(ns.Ratings.addDeath(db, {
    target = ANN, victim = "Vic Tim", id = ns.Ride.makeId(ANN, "Vic Tim", ts), ts = ts + 100, heavy = true,
    source = "observed",
  }, now))
end

-- The players, their stands, Cee One on Dar's crew. Uses only the Engines'
-- own actions, as the tests do.
local function buildWorld(s)
  local now = s.real.clock:now()
  local world = ns.World.new{ seed = math.floor(now) % 100000, start = now }
  s.world = world
  local function add(name, class, level, place, extra)
    local o = extra or {}
    o.name, o.class, o.level, o.place = name, class, level, place
    return world:addPlayer(o)
  end
  s.you = add(YOU, "HUNTER", 60, "ironforge", { guild = "Sim Guild", money = 1000000 })
  s.dar = add(DAR, "WARLOCK", 60, "gadgetzan", { guild = "Sim Guild" })
  s.ann = add(ANN, "WARLOCK", 55, "searing")
  s.mag = add(MAG, "MAGE", 60, "ironforge")
  s.cee1 = add(CEE1, "PRIEST", 55, "gadgetzan")
  s.cee2 = add(CEE2, "ROGUE", 55, "gadgetzan")
  s.stan = add(STAN, "WARLOCK", 60, "searing")
  -- Forever can't put gold in a trade window from an addon; the sim says so too,
  -- so the arrival window shows "Put 1g in the trade" here as it will in the game.
  function s.you.game:trySetTradeMoney(copper)
    self.p.tradeMoney = copper
    return false
  end
  seedRatings(world, s.you.db)

  assert(s.dar.engine:openStand{ kind = "lock", seats = 3, clickerPct = 25, note = "Sim stand: summons to Tanaris" })
  assert(s.ann.engine:openStand{ kind = "lock", seats = 2, clickerPct = 30, note = "Sim stand: needs clickers" })
  assert(s.mag.engine:openStand{ kind = "mage", seats = 3, note = "Sim portals" })
  step(s, 2)
  assert(s.cee1.engine:applyClicker(s.dar.engine.stand.standId, 25))
  step(s, 2)
  assert(s.dar.engine:respondClicker(CEE1, "ACCEPT"))
  step(s, 2)
  step(s, 2)
  assert(s.cee1.engine.shift ~= nil, "Cee One did not join the crew")
  step(s, 61) -- one heartbeat on, so the boards show the crew (a stand's count travels with its heartbeat)
end

-- What the buttons do ---------------------------------------------------------------------------

local function explain(why)
  return UI.Main.explain(nil, why)
end

-- My ride with `driver` that is in one of `states`, or nil.
local function rideWith(s, driver, states)
  for _, ride in pairs(s.you.engine.rides) do
    if Names.same(ride.driver, driver) and Names.same(ride.traveler, YOU) and states[ride.state] then
      return ride
    end
  end
  return nil
end

-- The warlock casts the summon from `placeKey` for an instant, without moving
-- (a move would close the stand) and without telling anyone: only the summon
-- popup and the position the guard reads show it.
local function castFrom(s, placeKey)
  local dar = s.dar
  local home, dx, dy = dar.place, dar.dx, dar.dy
  dar.place, dar.dx, dar.dy = placeKey, 0, 0
  local ok, err = pcall(s.world.offerSummon, s.world, DAR, YOU)
  dar.place, dar.dx, dar.dy = home, dx, dy
  assert(ok, err)
end

local function darSummons(s, placeKey)
  if rideWith(s, DAR, { grouped = true, summoning = true }) == nil then
    return L.fmt("SIM_NEED_RIDE", DAR, DAR)
  end
  s.dar.engine:nextTraveler() -- his Summon next button: the group is told the portal is up
  if placeKey then
    castFrom(s, placeKey)
  else
    s.world:offerSummon(DAR, YOU)
  end
  step(s, 0.5)
  return L.fmt("SIM_SUMMONED", DAR)
end

local ACTIONS = {}

-- You take the invite you were sent. The game does not take a second group, so
-- the first is left before, as the player would have to (the Engine said so:
-- "Leave your group so the driver can invite you.").
function ACTIONS.invite(s)
  local inviter = s.you.invitedBy
  if inviter == nil then
    return L.SIM_NO_INVITE
  end
  local switched = s.you.group ~= nil
  if switched then
    s.world:leaveGroup(s.you, false)
  end
  if not s.world:acceptInvite(YOU) then
    return L.SIM_NO_INVITE
  end
  step(s, 1)
  return L.fmt(switched and "SIM_SWITCHED" or "SIM_JOINED", tostring(inviter))
end

function ACTIONS.green(s)
  return darSummons(s, nil)
end

function ACTIONS.wrong(s)
  return darSummons(s, "searing")
end

function ACTIONS.stranger(s)
  s.world:offerSummon(STAN, YOU)
  step(s, 0.5)
  return L.fmt("SIM_STRANGER", STAN)
end

function ACTIONS.accept(s)
  local summon = s.you.summon
  if summon == nil then
    return L.SIM_NO_SUMMON
  end
  s.world:fire(s.you, "SUMMON_GONE") -- the popup closes on accepting, before the landing is seen
  s.world:acceptSummon(YOU)
  step(s, 1)
  return L.fmt("SIM_LANDED", tostring(summon.summoner), ns.World.PLACES[s.you.place].zone)
end

function ACTIONS.portal(s)
  local ride = rideWith(s, MAG, { grouped = true, portal = true })
  if ride == nil then
    return L.fmt("SIM_NEED_PORTAL", MAG, MAG)
  end
  if ride.state == "portal" then
    return L.SIM_PORTAL_ALREADY
  end
  s.mag.engine:nextTraveler() -- his Open portal button: PORTAL_UP goes to the group
  s.world:castPortal(MAG, ride.dest)
  step(s, 1)
  return L.fmt("SIM_PORTAL_OPEN", MAG, W.portalName(ride.dest))
end

function ACTIONS.step(s)
  local ride = rideWith(s, MAG, { portal = true })
  if ride == nil then
    return L.SIM_NO_PORTAL
  end
  if s.you.place ~= s.mag.place then
    s.world:moveTo(YOU, s.mag.place) -- you walk to the mage first
  end
  if not s.world:usePortal(YOU, ride.dest) then
    return L.SIM_PORTAL_FAILED
  end
  step(s, 1)
  return L.fmt("SIM_STEPPED", W.portalName(ride.dest))
end

function ACTIONS.clicker(s)
  local stand = s.dar.engine.stand
  local ok, why = s.cee2.engine:applyClicker(stand.standId, CLICKER_ASK)
  if not ok then
    return explain(why)
  end
  step(s, 1)
  return L.fmt("SIM_CLICKER_ASKS", CEE2, DAR, CLICKER_ASK, DAR)
end

function ACTIONS.kill(s)
  s.world:kill(YOU)
  s.you.engine:status("STATUS_HC_DEAD") -- as Core/Init does when the real character dies
  step(s, 1)
  return L.SIM_KILLED
end

-- Completes the trade the arrival window opened, with what it asked you to put in it.
function ACTIONS.tip(s)
  local you = s.you
  local partner, amount = you.tradeWith, you.tradeMoney
  if partner == nil or type(amount) ~= "number" or amount <= 0 then
    return L.SIM_NO_TRADE
  end
  you.tradeWith, you.tradeMoney = nil, nil
  if not s.world:trade(YOU, partner, amount) then
    return L.SIM_TRADE_FAILED
  end
  step(s, 2)
  return L.fmt("SIM_TRADED", Money.format(amount), partner)
end

function ACTIONS.shift(s)
  for _, p in ipairs({ s.you, s.cee1, s.cee2 }) do
    if p.engine.shift ~= nil then
      p.engine:leaveStand()
      step(s, 1)
      return L.fmt("SIM_SHIFT_ENDED", p.name)
    end
  end
  return L.SIM_NO_SHIFT
end

function ACTIONS.advance(s)
  step(s, 60)
  return L.SIM_ADVANCED
end

function ACTIONS.stop()
  M.stop()
  return ""
end

-- The buttons, top to bottom: the label (Locale key) and the action.
local BUTTONS = {
  { "SIM_B_INVITE", "invite" },
  { "SIM_B_GREEN", "green" },
  { "SIM_B_WRONG", "wrong" },
  { "SIM_B_STRANGER", "stranger" },
  { "SIM_B_ACCEPT", "accept" },
  { "SIM_B_PORTAL", "portal" },
  { "SIM_B_STEP", "step" },
  { "SIM_B_CLICKER", "clicker" },
  { "SIM_B_KILL", "kill" },
  { "SIM_B_TIP", "tip" },
  { "SIM_B_SHIFT", "shift" },
  { "SIM_B_ADVANCE", "advance" },
  { "SIM_B_STOP", "stop" },
}

-- The "Sim controls" window ---------------------------------------------------------------------

-- Runs a button's action: what it answers (or what went wrong) is shown at the top.
local function press(s, name)
  local ok, text = pcall(ACTIONS[name], s)
  if not M.state then
    return
  end
  if not ok then
    pcall(s.real.log, "sim " .. name .. ": " .. tostring(text))
    text = L.fmt("SIM_ERROR", tostring(text))
  end
  W.setText(s.frame.status, text)
end

local function buildControls(s)
  local f = W.window{
    width = 230, height = 70 + #BUTTONS * 26 + 12, title = L.SIM_TITLE, point = "LEFT", x = 20, y = 0,
  }
  f.status = W.text(f, "GameFontHighlightSmall")
  f.status:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -34)
  f.status:SetWidth(202)
  f.status:SetWordWrap(true)
  for i, def in ipairs(BUTTONS) do
    local b = W.button(f, L[def[1]], 202, function()
      press(s, def[2])
    end)
    b:SetPoint("TOPLEFT", f, "TOPLEFT", 14, -(92 + (i - 1) * 26))
  end
  return f
end

-- Starting and stopping -----------------------------------------------------------------------

-- Undoes whatever start() got done, in the reverse order. Safe on a half-built sim.
local function teardown(s)
  for _, views in ipairs(s.windows or {}) do
    pcall(views.Detach)
  end
  if s.driver then
    s.driver:SetScript("OnUpdate", nil)
  end
  if s.frame then
    s.frame:Hide()
  end
  if s.bound then
    ns.engine, ns.db = s.real, s.realDb
  end
  if s.muted then
    s.real:mute(false)
  end
  UI.Dialogs.closeRequest()
  M.state = nil
  local main = UI.Main
  if main.windows then
    main.windows.Refresh() -- the real engine's windows may have something to show again
  end
  main:Invalidate()
end

-- Starts the sim. Raises when it could not be built (nothing is left changed).
function M.start()
  local main = UI.Main
  if M.state then
    M.state.frame:Show()
    say(L.SIM_ALREADY)
    return
  end
  if ns.engine == nil then
    say(L.UI_NOT_RUNNING)
    return
  end
  local s = { real = ns.engine, realDb = ns.db, acc = 0, windows = {} }
  local ok, err = pcall(function()
    buildWorld(s)
    s.real:mute(true)
    s.muted = true
    ns.engine, ns.db = s.you.engine, s.you.db
    s.bound = true
    UI.Dialogs.closeRequest()
    if main.windows then
      main.windows.Refresh() -- the real windows go quiet
    end
    -- You's own windows, then one set for each sim player whose side You answers.
    s.windows[1] = main:Listen(s.you.engine, s.you.db)
    s.you.engine:on("STATUS", function(_, line)
      if not main:IsShown() then
        say(line)
      end
    end)
    for i, p in ipairs({ s.dar, s.mag, s.cee1, s.cee2 }) do
      s.windows[#s.windows + 1] = main.attachWindows(p.engine, { label = p.name .. " (sim)", always = true, slot = i })
    end
    s.frame = buildControls(s)
    W.setText(s.frame.status, L.SIM_HINT)
    s.driver = CreateFrame("Frame")
    s.driver:SetScript("OnUpdate", function(_, elapsed)
      s.acc = s.acc + elapsed
      if s.acc >= TICK then
        local seconds = math.min(s.acc, MAX_STEP)
        s.acc = 0
        local stepped, why = pcall(step, s, seconds)
        if not stepped then
          pcall(s.real.log, "sim clock: " .. tostring(why))
        end
      end
    end)
    M.state = s
    s.frame:Show()
  end)
  if not ok then
    teardown(s)
    error(err, 0)
  end
  main:Invalidate()
  say(L.SIM_STARTED)
  main:Show("travel")
end

-- Ends the sim: the real Engine is back, unmuted, and the sim's windows are gone.
function M.stop()
  local s = M.state
  if s == nil then
    say(L.SIM_NOT_RUNNING)
    return
  end
  teardown(s)
  say(L.SIM_STOPPED)
end
