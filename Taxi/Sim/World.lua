local _, ns = ...

-- A simulated world for many Taxi clients: players with places, groups,
-- summons, portals, trades, combat and deaths. Each player runs a real Engine
-- on a FakeGame adapter and a Transport over the shared simulated server (Bus),
-- so whole multi-player flows run on a PC, and in game for /taxi sim.
--
--   local w = ns.World.new{seed = 1, start = 10000}
--   local p = w:addPlayer{name = "Ana Smith", class = "PRIEST", level = 30, place = "ironforge"}
--   w:advance(2)   -- time passes; transports are pumped every 0.2 s
--
-- A player p has p.engine, p.game, p.events (every event p.engine emitted, as
-- {event, ...}) and p.db. Engine errors from every player are collected in
-- w.errors. Events the world causes (a summon offered, a death) reach the
-- engine at once; events caused by a player's own API calls (leaving the
-- group, say) arrive on the next step of the clock, as in the game.
-- Pure Lua: no WoW API.
local M = {}

local World = {}
World.__index = World

-- Places, by key. wx/wy are world yards; levels the zone's level range.
M.PLACES = {
  ironforge = { mapID = 1455, zone = "Ironforge", subzone = "The Commons", wx = 0, wy = 0, levels = { 1, 60 } },
  gadgetzan = { mapID = 1446, zone = "Tanaris", subzone = "Gadgetzan", wx = 5000, wy = 5000, levels = { 40, 50 } },
  searing = { mapID = 1427, zone = "Searing Gorge", subzone = "Thorium Point", wx = -3000, wy = 900, levels = { 43, 50 } },
  stormwind = { mapID = 1453, zone = "Stormwind City", subzone = "Trade District", wx = -8000, wy = 600, levels = { 1, 60 } },
  darnassus = { mapID = 1457, zone = "Darnassus", subzone = "Craftsmen's Terrace", wx = -9000, wy = -9000, levels = { 1, 60 } },
  deadmines = { mapID = 291, zone = "The Deadmines", subzone = "", wx = 0, wy = 0, levels = { 15, 25 }, inInstance = true },
}

local STEP = 0.2 -- seconds per step of advance(); the game pumps every 0.2 s too
local EPSILON = 1e-9
local PARTY_MAX, RAID_MAX = 5, 40

-- o: seed (default 1), start (the clock's first time, default 0), latency
-- (seconds a message takes on the bus, default 0.1).
function M.new(o)
  o = o or {}
  local clock = ns.Clock.new(o.start or 0)
  return setmetatable({
    clock = clock,
    bus = ns.Bus.new{ clock = clock, seed = o.seed, latency = o.latency },
    players = {}, -- name -> player
    order = {}, -- players in the order they were added
    portals = {}, -- open mage portals: { mage, key, place }
    groupCount = 0,
    errors = {}, -- "name: what: error" for every error an engine logged
  }, World)
end

-- A number in (0, 1) from the world's seeded generator.
function World:random()
  return self.bus:random()
end

function World:player(name)
  local p = self.players[name]
  if p == nil then
    error("unknown player " .. tostring(name), 2)
  end
  return p
end

local function placeOf(key)
  local place = M.PLACES[key]
  if place == nil then
    error("unknown place " .. tostring(key), 3)
  end
  return place
end

-- Game events -------------------------------------------------------------------

-- Gives a game event to p's engine now, if p is in the world.
function World:fire(p, event, ...)
  if self.players[p.name] == p then
    p.engine:onGame(event, ...)
  end
end

-- Gives a game event to p's engine on the next step of the clock, if p is
-- still in the world then.
function World:fireLater(p, event, ...)
  local args = { n = select("#", ...), ... }
  self.clock:after(0, function()
    if self.players[p.name] == p then
      p.engine:onGame(event, unpack(args, 1, args.n))
    end
  end)
end

-- Players -------------------------------------------------------------------------

-- o: name, faction ("Alliance"), class ("WARRIOR"), level (60), guild, place
-- ("ironforge"), money (0, copper), locale ("enUS"; "deDE" names Ironforge
-- "Eisenschmiede"), hardcore (true unless false), channelsFull (joining the
-- channel fails), shards (soul shards; 10 for a warlock, else 0), zoneText and
-- subzoneText (the zone / subzone text the player's game reports wherever they
-- are, so their stand advertises it: a liar's; the map stays the real one), db
-- (reuse a TaxiDB; default a fresh Store.init(nil)), charDb. The engine is
-- started before addPlayer returns, with p.events already recording.
function World:addPlayer(o)
  local name = o.name
  local placeKey = o.place or "ironforge"
  local place = placeOf(placeKey)
  local p = {
    name = name,
    faction = o.faction or "Alliance",
    class = o.class or "WARRIOR",
    level = o.level or 60,
    guild = o.guild,
    place = placeKey,
    dx = 0,
    dy = 0,
    money = o.money or 0,
    locale = o.locale or "enUS",
    hardcore = o.hardcore ~= false,
    channelsFull = o.channelsFull == true,
    shards = o.shards or (o.class == "WARLOCK" and 10 or 0),
    zoneText = o.zoneText,
    subzoneText = o.subzoneText,
    dead = false,
    combat = false,
    events = {},
    db = o.db or ns.Store.init(nil),
    charDb = o.charDb or {},
  }
  local backend = self.bus:attach(name, p.faction, function(prefix, text, dist, sender)
    p.transport:receive(prefix, text, dist, sender)
  end)
  self.bus:setLockdown(name, place.inInstance == true)
  p.game = ns.FakeGame.new(self, p)
  p.transport = ns.Transport.new{ backend = backend, clock = self.clock, prefix = ns.Config.PREFIX }
  p.engine = ns.Engine.new{
    game = p.game,
    transport = p.transport,
    clock = self.clock,
    db = p.db,
    charDb = p.charDb,
    rng = function()
      return self:random()
    end,
    log = function(text)
      self.errors[#self.errors + 1] = text
    end,
  }
  -- Record every event before the engine starts, so startup events are kept.
  local emit = p.engine.emit
  p.engine.emit = function(e, event, ...)
    p.events[#p.events + 1] = { event, ... }
    return emit(e, event, ...)
  end
  self.players[name] = p
  self.order[#self.order + 1] = p
  p.engine:start()
  return p
end

-- The player logs out: engine stopped, out of their group (the others hear
-- GROUP_CHANGED), off the bus. A player added later under the same name is a
-- new one, with a fresh db unless one is passed.
function World:removePlayer(name)
  local p = self:player(name)
  p.engine:stop()
  self:leaveGroup(p, false) -- while still on the bus, which leaving updates
  self.bus:detach(name)
  self.players[name] = nil
  for i, q in ipairs(self.order) do
    if q == p then
      table.remove(self.order, i)
      break
    end
  end
end

-- Puts the player at a place, dx/dy yards from its centre. Inside an instance
-- the player is in messaging lockdown. The player's engine gets MOVED.
function World:moveTo(name, placeKey, dx, dy)
  local p = self:player(name)
  local place = placeOf(placeKey)
  p.place, p.dx, p.dy = placeKey, dx or 0, dy or 0
  self.bus:setLockdown(name, place.inInstance == true)
  self:fire(p, "MOVED")
end

-- Time -------------------------------------------------------------------------------

-- Moves time forward in steps of 0.2 s, pumping every transport after each.
-- The last step takes whatever is left, so time ends exactly at now + seconds
-- (repeated 0.2 steps alone drift) and a timer due then runs.
function World:advance(seconds)
  local target = self.clock:now() + seconds
  repeat
    local left = target - self.clock:now()
    local step = left <= STEP + EPSILON and left or STEP
    self.clock:advance(math.max(step, 0))
    for _, p in ipairs(self.order) do
      p.transport:pump()
    end
  until self.clock:now() >= target
end

-- Groups -------------------------------------------------------------------------------

-- Tells every listed player their group changed: now, or on the next step.
function World:groupChanged(names, later)
  for _, name in ipairs(names) do
    local p = self.players[name]
    if p ~= nil then
      if later then
        self:fireLater(p, "GROUP_CHANGED")
      else
        self:fire(p, "GROUP_CHANGED")
      end
    end
  end
end

local function setGroup(self, p, group)
  p.group = group
  self.bus:setGroup(p.name, group and group.id or nil)
end

-- The invited player accepts the last invite they got. The inviter's group is
-- made if they have none. Returns false when there is no invite, the player is
-- already in a group, or the group is full (5 in a party, 40 in a raid).
function World:acceptInvite(name)
  local p = self:player(name)
  local inviter = p.invitedBy and self.players[p.invitedBy]
  p.invitedBy = nil
  if inviter == nil or p.group ~= nil then
    return false
  end
  local group = inviter.group
  if group == nil then
    self.groupCount = self.groupCount + 1
    group = { id = "g" .. self.groupCount, members = { inviter.name }, raid = false }
    setGroup(self, inviter, group)
  end
  if #group.members >= (group.raid and RAID_MAX or PARTY_MAX) then
    return false
  end
  group.members[#group.members + 1] = p.name
  setGroup(self, p, group)
  self:groupChanged(group.members, false)
  return true
end

-- p leaves their group; a group left with one member breaks up. Everyone
-- affected hears GROUP_CHANGED (on the next step when `later`).
function World:leaveGroup(p, later)
  local group = p.group
  if group == nil then
    return
  end
  for i, member in ipairs(group.members) do
    if member == p.name then
      table.remove(group.members, i)
      break
    end
  end
  setGroup(self, p, nil)
  local told = { p.name }
  for _, member in ipairs(group.members) do
    told[#told + 1] = member
  end
  if #group.members == 1 then
    local last = self.players[group.members[1]]
    group.members = {}
    if last ~= nil then
      setGroup(self, last, nil)
    end
  end
  self:groupChanged(told, later)
end

-- Combat and death -------------------------------------------------------------------

-- The player's combat state changes; they and their group hear COMBAT_CHANGED.
function World:setCombat(name, inCombat)
  local p = self:player(name)
  p.combat = inCombat and true or false
  local names = p.group and p.group.members or { p.name }
  for _, member in ipairs(names) do
    local q = self.players[member]
    if q ~= nil then
      self:fire(q, "COMBAT_CHANGED", p.name, p.combat)
    end
  end
end

-- The player dies: PLAYER_DIED for them, then the server's death notice
-- (HC_DEATH) for every player, the victim and non-Hardcore players included.
-- Each engine decides what the notice means to it (a non-Hardcore engine and
-- the victim's own engine ignore it). There is no MEMBER_DIED (R36).
function World:kill(name)
  local victim = self:player(name)
  victim.dead = true
  self:fire(victim, "PLAYER_DIED")
  for _, p in ipairs(self.order) do
    self:fire(p, "HC_DEATH", victim.name)
  end
end

-- Summons and portals -------------------------------------------------------------------

-- The warlock's Ritual of Summoning reaches the traveler, who gets SUMMON_OFFERED.
-- There is no group check: a stranger's summon is exactly what the guard is for.
function World:offerSummon(warlockName, travelerName)
  local warlock, traveler = self:player(warlockName), self:player(travelerName)
  traveler.summon = { summoner = warlock.name, place = warlock.place, dx = warlock.dx, dy = warlock.dy }
  self:fire(traveler, "SUMMON_OFFERED")
end

-- The traveler clicks accept: they land on the summoner's spot. Returns false
-- with no summon waiting.
function World:acceptSummon(travelerName)
  local traveler = self:player(travelerName)
  local summon = traveler.summon
  if summon == nil then
    return false
  end
  traveler.summon = nil
  self:moveTo(traveler.name, summon.place, summon.dx, summon.dy)
  return true
end

-- The mage opens a portal to key where they stand. Returns false for a portal
-- they don't know.
function World:castPortal(mageName, key)
  local mage = self:player(mageName)
  for _, portal in ipairs(mage.game:knownPortals()) do
    if portal.key == key then
      self.portals[#self.portals + 1] = { mage = mage.name, key = key, place = mage.place }
      return true
    end
  end
  return false
end

-- The traveler clicks an open portal to key at their place and lands at its
-- destination. Returns false when there is no such portal there, or the
-- destination is not a place of this world.
function World:usePortal(travelerName, key)
  local traveler = self:player(travelerName)
  if M.PLACES[key] == nil then
    return false
  end
  for _, portal in ipairs(self.portals) do
    if portal.key == key and portal.place == traveler.place then
      self:moveTo(traveler.name, key, 0, 0)
      return true
    end
  end
  return false
end

-- Trade ----------------------------------------------------------------------------------

-- A finished trade of copper from one player to another. Both hear
-- TRADE_DONE(partner, gaveCopper, gotCopper). Returns false when the giver
-- can't pay.
function World:trade(fromName, toName, copper)
  local from, to = self:player(fromName), self:player(toName)
  if type(copper) ~= "number" or copper < 0 or from.money < copper then
    return false
  end
  from.money = from.money - copper
  to.money = to.money + copper
  self:fire(from, "TRADE_DONE", to.name, copper, 0)
  self:fire(to, "TRADE_DONE", from.name, 0, copper)
  return true
end

ns.World = M
