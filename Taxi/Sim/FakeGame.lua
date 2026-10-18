local _, ns = ...

-- The game adapter over a simulated World: what Game/WoW.lua answers from the
-- WoW API, this answers from one World player. The contract (all methods
-- called with ":"):
--   identity   me, faction, level, class, isHardcore, isDead
--   location   location -> {mapID, x, y, wx, wy, zone, subzone, inInstance};
--              mapName(mapID) in the player's language; zoneLevels(mapID) -> min, max
--   group      unitFor(name) -> unit, unitPos(unit) -> wx, wy, mapID,
--              unitInCombat(unit), unitDead(unit), groupNames, groupSize, isRaid,
--              invite(name), convertToRaid, leaveGroup
--   summon     summonFacts -> {summoner, areaName} | nil, cancelSummon
--   money      money, openTrade(name), trySetTradeMoney(copper) -> bool
--   other      isGuildmate(name), knownPortals -> {{spellId, key}}, soulShards,
--              joinChannel(name) -> true | nil, "full"
-- Anything unknown is nil, never a stand-in like 0 or "" (R21).
-- Pure Lua: no WoW API.
local M = {}

local Names, Config = ns.Names, ns.Config

local Game = {}
Game.__index = Game

-- Map names in other client languages; any map missing here has its English name.
local LOCALIZED = {
  deDE = { [1455] = "Eisenschmiede" },
}

-- The portals each faction's mages learn, at level 40.
local FACTION_PORTALS = {
  Alliance = { stormwind = true, ironforge = true, darnassus = true },
  Horde = { orgrimmar = true, undercity = true, thunderbluff = true },
}
local PORTAL_LEVEL = 40

function M.new(world, player)
  return setmetatable({ world = world, p = player }, Game)
end

local function places()
  return ns.World.PLACES
end

local function placeByMap(mapID)
  for _, place in pairs(places()) do
    if place.mapID == mapID then
      return place
    end
  end
  return nil
end

-- Identity -----------------------------------------------------------------------

function Game:me()
  return self.p.name
end

function Game:faction()
  return self.p.faction
end

function Game:level()
  return self.p.level
end

function Game:class()
  return self.p.class
end

function Game:isHardcore()
  return self.p.hardcore
end

function Game:isDead()
  return self.p.dead
end

-- Location -----------------------------------------------------------------------

-- The zone is in the player's language, as the game shows it; the subzone is
-- always English here.
function Game:location()
  local p = self.p
  local place = places()[p.place]
  return {
    mapID = place.mapID,
    x = 0.5 + p.dx / 1000,
    y = 0.5 + p.dy / 1000,
    wx = place.wx + p.dx,
    wy = place.wy + p.dy,
    zone = self:mapName(place.mapID),
    subzone = place.subzone,
    inInstance = place.inInstance == true,
  }
end

function Game:mapName(mapID)
  local place = placeByMap(mapID)
  if place == nil then
    return nil
  end
  local names = LOCALIZED[self.p.locale]
  return names and names[mapID] or place.zone
end

function Game.zoneLevels(_, mapID)
  local place = placeByMap(mapID)
  if place == nil then
    return nil, nil
  end
  return place.levels[1], place.levels[2]
end

-- Group ----------------------------------------------------------------------------
-- Unit ids follow the game: "player" is me; in a party the others are
-- "party1".."party4" in the order they joined; in a raid everyone, me
-- included, is "raid1".."raid40".

function Game:unitFor(name)
  local p = self.p
  if Names.same(name, p.name) then
    return "player"
  end
  local group = p.group
  if group == nil then
    return nil
  end
  local others = 0
  for i, member in ipairs(group.members) do
    if member ~= p.name then
      others = others + 1
    end
    if Names.same(member, name) then
      return group.raid and ("raid" .. i) or ("party" .. others)
    end
  end
  return nil
end

-- The World player behind a unit id, or nil.
local function playerFor(self, unit)
  local p = self.p
  if unit == "player" then
    return p
  end
  local group = p.group
  if group == nil or type(unit) ~= "string" then
    return nil
  end
  local kind, n = unit:match("^(%a+)(%d+)$")
  n = tonumber(n)
  local name
  if group.raid and kind == "raid" then
    name = group.members[n]
  elseif not group.raid and kind == "party" then
    local others = 0
    for _, member in ipairs(group.members) do
      if member ~= p.name then
        others = others + 1
        if others == n then
          name = member
        end
      end
    end
  end
  return name and self.world.players[name] or nil
end

function Game:unitPos(unit)
  local q = playerFor(self, unit)
  if q == nil then
    return nil
  end
  local place = places()[q.place]
  return place.wx + q.dx, place.wy + q.dy, place.mapID
end

function Game:unitInCombat(unit)
  local q = playerFor(self, unit)
  if q == nil then
    return nil
  end
  return q.combat
end

function Game:unitDead(unit)
  local q = playerFor(self, unit)
  if q == nil then
    return nil
  end
  return q.dead
end

-- Every member, me included, in the order they joined; {} when not in a group.
function Game:groupNames()
  local out = {}
  if self.p.group then
    for i, member in ipairs(self.p.group.members) do
      out[i] = member
    end
  end
  return out
end

-- Members, me included; 0 when not in a group (as GetNumGroupMembers).
function Game:groupSize()
  return self.p.group and #self.p.group.members or 0
end

function Game:isRaid()
  return self.p.group ~= nil and self.p.group.raid
end

-- Invites go out at once; the invited player accepts with world:acceptInvite.
function Game:invite(name)
  local target = self.world.players[name]
  if target ~= nil then
    target.invitedBy = self.p.name
  end
end

-- As in the game, the conversion is not there yet when this returns: the group
-- becomes a raid on the next step of the clock, and then every member hears
-- GROUP_CHANGED (R53).
function Game:convertToRaid()
  local group = self.p.group
  if group == nil or group.raid then
    return
  end
  local world = self.world
  world.clock:after(0, function()
    if group.raid or #group.members == 0 then
      return
    end
    group.raid = true
    world:groupChanged(group.members, false)
  end)
end

function Game:leaveGroup()
  self.world:leaveGroup(self.p, true)
end

-- Summon ---------------------------------------------------------------------------

-- The summon dialog's facts: who summons, and the area in my own language.
function Game:summonFacts()
  local summon = self.p.summon
  if summon == nil then
    return nil
  end
  return { summoner = summon.summoner, areaName = self:mapName(places()[summon.place].mapID) }
end

function Game:cancelSummon()
  if self.p.summon ~= nil then
    self.p.summon = nil
    self.world:fireLater(self.p, "SUMMON_GONE")
  end
end

-- Money and trade -----------------------------------------------------------------

function Game:money()
  return self.p.money
end

-- Opens a trade window with an online player. The trade itself is
-- world:trade (the player clicks through it).
function Game:openTrade(name)
  if self.world.players[name] == nil then
    return false
  end
  self.p.tradeWith = name
  return true
end

function Game:trySetTradeMoney(copper)
  self.p.tradeMoney = copper
  return true
end

-- Other -------------------------------------------------------------------------------

function Game:isGuildmate(name)
  local other = self.world.players[name]
  return self.p.guild ~= nil and other ~= nil and other.guild == self.p.guild
end

function Game:knownPortals()
  local p = self.p
  local out = {}
  local mine = FACTION_PORTALS[p.faction]
  if p.class ~= "MAGE" or mine == nil or p.level < PORTAL_LEVEL then
    return out
  end
  for _, portal in ipairs(Config.PORTALS) do
    if mine[portal.key] then
      out[#out + 1] = { spellId = portal.spellId, key = portal.key }
    end
  end
  return out
end

function Game:soulShards()
  return self.p.shards
end

function Game:joinChannel(name)
  if self.p.channelsFull then
    return nil, "full"
  end
  self.p.channel = name
  return true
end

ns.FakeGame = M
