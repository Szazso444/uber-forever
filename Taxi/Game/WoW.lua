local _, ns = ...

-- The game adapter over the real WoW API (Forever 1.60.1, interface 16001):
-- the same contract Sim/FakeGame.lua implements over a simulated World (see
-- its header for the method list), plus the transport backend Comms/Transport
-- sends through and the two clocks. This is the only file that reads the game
-- for the Engine; it can't run on a PC, so tests/game/wow_spec.lua runs it
-- against a fake of the API. It has not yet been run against the real game:
-- docs/testing/in-game-checklist.md lists what to check.
--
--   local game = ns.WoWGame.new()
--   game:listen(function(event, ...) engine:onGame(event, ...) end, log)
--   local backend = ns.WoWBackend.new(Config.CHANNEL)
--   backend.listen(function(prefix, text, dist, sender) transport:receive(prefix, text, dist, sender) end, log)
--
-- Game events the Engine gets from listen():
--   SUMMON_OFFERED          CONFIRM_SUMMON
--   SUMMON_GONE             CANCEL_SUMMON, or the poll finds no summon pending
--                           any more (accepted on the popup, declined, expired);
--                           once per summon
--   MOVED                   ZONE_CHANGED, ZONE_CHANGED_NEW_AREA,
--                           PLAYER_ENTERING_WORLD, and the 1 s poll whenever I
--                           changed map or moved more than MOVE_YARDS
--   GROUP_CHANGED           GROUP_ROSTER_UPDATE
--   COMBAT_CHANGED(name, b) PLAYER_REGEN_DISABLED / _ENABLED for me; UNIT_FLAGS
--                           for a group member whose combat state changed
--   PLAYER_DIED             PLAYER_DEAD
--   HC_DEATH(name)          HARDCORE_DEATHS
--   TRADE_DONE(partner, gave, got)
--                           a trade the game called complete ("Trade complete."),
--                           with the money it moved (GetMoney before and after)
-- There is no MEMBER_DIED: a group member's health or ghost state is never
-- taken as a death (R36).
--
-- Names: a player is their full two-part name as the game gives it, surname
-- separator included (Forever's C_NameUtil speaks of one), never re-spelled.
-- A realm is added as "-Realm" when the game gives one, and my own realm is
-- dropped, so UnitName, the CHAT_MSG_ADDON sender, the summoner, the guild
-- roster and HARDCORE_DEATHS all come out the same way (canonical below).
-- Assumed, not proven: area C of the in-game checklist checks the forms in game.
--
-- Anything unknown is nil, never a stand-in like 0 or "" (R21).
local Config, Names = ns.Config, ns.Names

local POLL_SECONDS = 1 -- position and summon poll
local MOVE_YARDS = 5 -- a poll that finds me farther than this from the last MOVED fires MOVED again
local TRADE_SETTLE_SECONDS = 3 -- a completed trade's money must show up this soon after the window closed


-- Enum.SendAddonMessageResult (ChatConstantsDocumentation): Forever's numbers
-- are the very codes Transport reads (3 AddonMessageThrottle, 8 ChannelThrottle,
-- 11 AddOnMessageLockdown), so a number passes through unchanged.
local SEND_OK, SEND_INVALID_CHANNEL, SEND_GENERAL_ERROR = 0, 7, 9

-- Values ----------------------------------------------------------------------------

-- Forever's API can return "secret" values (its docs flag UnitName with
-- SecretWhenUnitNameIdentityRestricted). Addon code can't compare those, so a
-- secret counts as unknown.
local function isSecret(v)
  if issecretvalue == nil then
    return false
  end
  local ok, secret = pcall(issecretvalue, v)
  return not ok or secret == true
end

-- A real, non-empty text; the secret check comes before any comparison.
local function text(s)
  if type(s) ~= "string" or isSecret(s) or s == "" then
    return nil
  end
  return s
end

local function number(n)
  if type(n) ~= "number" or isSecret(n) or n ~= n or n == math.huge or n == -math.huge then
    return nil
  end
  return n
end

local function positive(n)
  n = number(n)
  return n ~= nil and n > 0 and n or nil
end

-- Names -----------------------------------------------------------------------------

-- A player's name as Taxi keeps it: tidied (Names.normalize), my own realm's
-- "-Realm" dropped, any other realm kept. nil for anything that isn't a name.
local function canonical(name)
  name = text(name)
  if name == nil then
    return nil
  end
  local realm = text(GetNormalizedRealmName())
  if realm ~= nil then
    local suffix = "-" .. realm
    if #name > #suffix and name:sub(-#suffix) == suffix then
      name = name:sub(1, #name - #suffix)
    end
  end
  return text(Names.normalize(name))
end

-- The full name of a unit ("player", "party1", "raid7", "NPC"), or nil. The
-- game's placeholder for a name it hasn't loaded yet (UNKNOWNOBJECT, "Unknown")
-- is no name (R55).
local function fullName(unit)
  if type(unit) ~= "string" or not UnitExists(unit) then
    return nil
  end
  local name, realm = UnitName(unit)
  name, realm = text(name), text(realm)
  if name == nil or name == UNKNOWNOBJECT or name == "Unknown" then
    return nil
  end
  if realm ~= nil then
    name = name .. "-" .. realm
  end
  return canonical(name)
end

-- The unit ids of the other group members: party1..party4, or every raid unit
-- in a raid (one of which is me).
local function groupUnits()
  local units = {}
  if IsInRaid() then
    for i = 1, GetNumGroupMembers() do
      units[#units + 1] = "raid" .. i
    end
  else
    for i = 1, GetNumSubgroupMembers() do
      units[#units + 1] = "party" .. i
    end
  end
  return units
end

local function isGroupUnit(unit)
  return type(unit) == "string" and (unit:match("^party%d+$") or unit:match("^raid%d+$")) ~= nil
end

-- The id of a chat channel I am in, or nil.
local function channelId(name)
  local id = GetChannelName(name)
  return positive(id)
end

-- The game adapter -------------------------------------------------------------------

local M = {}

local Game = {}
Game.__index = Game

function M.new()
  return setmetatable({
    guild = {}, -- canonical name -> true, from the guild roster
    combat = {}, -- group member name -> last combat state reported
    tradeOpen = false,
  }, Game)
end

-- Identity ------------------------------------------------------------------------------

function Game.me()
  return fullName("player")
end

function Game.faction()
  return text((UnitFactionGroup("player")))
end

function Game.level()
  return positive(UnitLevel("player"))
end

-- The class file name ("WARLOCK", "MAGE"), the same in every client language.
function Game.class()
  local _, classFile = UnitClass("player")
  return text(classFile)
end

function Game.isHardcore()
  return C_GameRules.IsHardcoreActive() == true
end

-- Dead or a ghost; Feign Death is not dead.
function Game.isDead()
  return UnitIsDeadOrGhost("player") == true and UnitIsFeignDeath("player") ~= true
end

-- Location ------------------------------------------------------------------------------

-- mapID is the uiMapID; x, y the map position (0..1); wx, wy world yards from
-- UnitPosition (nil inside instances, where the game hides them).
function Game:location()
  local mapID = C_Map.GetBestMapForUnit("player")
  local x, y
  if mapID ~= nil then
    local pos = C_Map.GetPlayerMapPosition(mapID, "player")
    if pos ~= nil then
      x, y = number(pos.x), number(pos.y)
    end
  end
  local wx, wy = UnitPosition("player")
  return {
    mapID = number(mapID),
    x = x,
    y = y,
    wx = number(wx),
    wy = number(wy),
    zone = text(GetZoneText()) or self:mapName(mapID),
    subzone = text(GetSubZoneText()),
    inInstance = IsInInstance() and true or false,
  }
end

-- The map's name in the player's language.
function Game.mapName(_, mapID)
  if number(mapID) == nil then
    return nil
  end
  local info = C_Map.GetMapInfo(mapID)
  return info ~= nil and text(info.name) or nil
end

function Game.zoneLevels(_, mapID)
  if number(mapID) == nil then
    return nil, nil
  end
  local low, high = C_Map.GetMapLevels(mapID)
  return positive(low), positive(high)
end

-- Group --------------------------------------------------------------------------------

function Game.unitFor(_, name)
  local wanted = canonical(name)
  if wanted == nil then
    return nil
  end
  if Names.same(fullName("player"), wanted) then
    return "player"
  end
  for _, unit in ipairs(groupUnits()) do
    if Names.same(fullName(unit), wanted) then
      return unit
    end
  end
  return nil
end

-- World yards and uiMapID of a unit (the player or a group member).
function Game.unitPos(_, unit)
  if type(unit) ~= "string" or not UnitExists(unit) then
    return nil
  end
  local wx, wy = UnitPosition(unit)
  return number(wx), number(wy), number(C_Map.GetBestMapForUnit(unit))
end

function Game.unitInCombat(_, unit)
  if type(unit) ~= "string" or not UnitExists(unit) then
    return nil
  end
  return UnitAffectingCombat(unit) == true
end

function Game.unitDead(_, unit)
  if type(unit) ~= "string" or not UnitExists(unit) then
    return nil
  end
  return UnitIsDeadOrGhost(unit) == true and UnitIsFeignDeath(unit) ~= true
end

-- Every member, me included; {} when not in a group. A member whose name the
-- game doesn't give (yet) is left out.
function Game.groupNames()
  local out = {}
  if GetNumGroupMembers() == 0 then
    return out
  end
  if not IsInRaid() then
    out[1] = fullName("player")
  end
  for _, unit in ipairs(groupUnits()) do
    local name = fullName(unit)
    if name ~= nil then
      out[#out + 1] = name
    end
  end
  return out
end

-- Members, me included; 0 when not in a group.
function Game.groupSize()
  return GetNumGroupMembers()
end

function Game.isRaid()
  return IsInRaid() == true
end

function Game.invite(_, name)
  C_PartyInfo.InviteUnit(name)
end

-- Restricted in Forever (HasRestrictions): call it from a click.
function Game.convertToRaid()
  C_PartyInfo.ConvertToRaid()
end

function Game.leaveGroup()
  C_PartyInfo.LeaveParty()
end

-- Summon ---------------------------------------------------------------------------------

-- The summon popup's facts: the summoner, and the area in my own language.
function Game.summonFacts()
  local summoner = canonical(C_SummonInfo.GetSummonConfirmSummoner())
  if summoner == nil then
    return nil
  end
  return { summoner = summoner, areaName = text(C_SummonInfo.GetSummonConfirmAreaName()) }
end

function Game.cancelSummon()
  C_SummonInfo.CancelSummon()
end

-- Whether the game still has a summon waiting for my answer.
local function summonPending()
  local left = C_SummonInfo.GetSummonConfirmTimeLeft()
  return C_SummonInfo.GetSummonConfirmSummoner() ~= nil and (number(left) == nil or left > 0)
end

-- Money and trade -----------------------------------------------------------------------

function Game.money()
  return number(GetMoney())
end

-- Asks a group member for a trade. The window opens later (TRADE_SHOW), when
-- they are in range and accept; false when they are not in my group.
function Game:openTrade(name)
  local unit = self:unitFor(name)
  if unit == nil or unit == "player" then
    return false
  end
  InitiateTrade(unit)
  return true
end

-- Whether a trade window with this player is open now (TRADE_SHOW names the
-- partner, TRADE_CLOSED ends it). The arrival window's Put button waits for it.
function Game:tradeOpenWith(name)
  local wanted = canonical(name)
  return self.tradeOpen == true and self.tradePartner ~= nil and wanted ~= nil
    and Names.same(self.tradePartner, wanted)
end

-- Tries to put copper in the open trade window, and returns false either way:
-- Forever's API has no getter to read the amount back, so success can't be
-- known and the UI always shows "Put X in the trade" (R55). SetTradeMoney is
-- restricted in Forever (HasRestrictions), so this is called only from the
-- player's own click (the arrival window's Put button), never from a game
-- event (R64). Whether the game lets it through is what the in-game checklist
-- (I1, I2) looks at; a refusal is swallowed, and with no window open nothing
-- is tried.
function Game:trySetTradeMoney(copper)
  if self.tradeOpen then
    pcall(C_TradeInfo.SetTradeMoney, copper)
  end
  return false
end

-- Other -----------------------------------------------------------------------------------

function Game:isGuildmate(name)
  local wanted = canonical(name)
  return wanted ~= nil and self.guild[wanted] == true
end

function Game:readGuild()
  local guild = {}
  if IsInGuild() then
    for i = 1, GetNumGuildMembers() do
      local name = canonical((GetGuildRosterInfo(i)))
      if name ~= nil then
        guild[name] = true
      end
    end
  end
  self.guild = guild
end

-- The portal spells of Config.PORTALS I know: {{spellId, key}}.
function Game.knownPortals()
  local out = {}
  for _, portal in ipairs(Config.PORTALS) do
    if C_SpellBook.IsSpellKnown(portal.spellId) == true then
      out[#out + 1] = { spellId = portal.spellId, key = portal.key }
    end
  end
  return out
end

function Game.soulShards()
  return number(C_Item.GetItemCount(Config.SOUL_SHARD_ITEM))
end

-- Joins the chat channel; true once the game gives it a channel id. With every
-- channel slot taken the join does nothing: nil, "full".
function Game.joinChannel(_, name)
  if channelId(name) ~= nil then
    return true
  end
  pcall(JoinChannelByName, name)
  if channelId(name) ~= nil then
    return true
  end
  return nil, "full"
end

-- Game events -------------------------------------------------------------------------------

function Game:fire(event, ...)
  if self.emit ~= nil then
    self.emit(event, ...)
  end
end

-- Runs fn(self, ...); an error goes to the log sink instead of the screen.
function Game:safely(what, fn, ...)
  local ok, err = pcall(fn, self, ...)
  if not ok and self.log ~= nil then
    pcall(self.log, "WoW " .. tostring(what) .. ": " .. tostring(err))
  end
end

local function spot()
  local wx, wy = UnitPosition("player")
  return { mapID = C_Map.GetBestMapForUnit("player"), wx = number(wx), wy = number(wy) }
end

local function sameSpot(a, b)
  if a.mapID ~= b.mapID then
    return false
  end
  if a.wx == nil or b.wx == nil then
    return a.wx == b.wx
  end
  local dx, dy = a.wx - b.wx, a.wy - b.wy
  return dx * dx + dy * dy <= MOVE_YARDS * MOVE_YARDS
end

-- MOVED when `always`, or when I am somewhere else than at the last MOVED.
function Game:moved(always)
  local here = spot()
  if not always and self.lastSpot ~= nil and sameSpot(self.lastSpot, here) then
    return
  end
  self.lastSpot = here
  self:fire("MOVED")
end

function Game:summonGone()
  if self.summonUp then
    self.summonUp = false
    self:fire("SUMMON_GONE")
  end
end

function Game:poll()
  if self.summonUp and not summonPending() then
    self:summonGone()
  end
  self:moved(false)
end

-- A trade is reported once the game called it complete and my money changed,
-- within TRADE_SETTLE_SECONDS of the window closing (the money can arrive just
-- after). A cancelled trade, or one of items only, is never reported.
function Game:settleTrade()
  local trade = self.trade
  if trade == nil then
    return
  end
  if trade.closedAt ~= nil and GetTime() - trade.closedAt > TRADE_SETTLE_SECONDS then
    self.trade = nil
    return
  end
  if not trade.complete then
    return
  end
  local delta = (number(GetMoney()) or trade.money) - trade.money
  if delta == 0 then
    return
  end
  self.trade = nil
  if trade.partner ~= nil then
    self:fire("TRADE_DONE", trade.partner, delta < 0 and -delta or 0, delta > 0 and delta or 0)
  end
end

local EVENTS = {}

EVENTS.CONFIRM_SUMMON = function(g)
  g.summonUp = true
  g:fire("SUMMON_OFFERED")
end

EVENTS.CANCEL_SUMMON = function(g)
  g:summonGone()
end

EVENTS.ZONE_CHANGED = function(g)
  g:moved(true)
end
EVENTS.ZONE_CHANGED_NEW_AREA = EVENTS.ZONE_CHANGED
EVENTS.PLAYER_ENTERING_WORLD = EVENTS.ZONE_CHANGED

EVENTS.GROUP_ROSTER_UPDATE = function(g)
  g:fire("GROUP_CHANGED")
end

EVENTS.PLAYER_DEAD = function(g)
  g:fire("PLAYER_DIED")
end

EVENTS.HARDCORE_DEATHS = function(g, memberName)
  local name = canonical(memberName)
  if name ~= nil then
    g:fire("HC_DEATH", name)
  end
end

EVENTS.PLAYER_REGEN_DISABLED = function(g)
  g:fire("COMBAT_CHANGED", fullName("player"), true)
end

EVENTS.PLAYER_REGEN_ENABLED = function(g)
  g:fire("COMBAT_CHANGED", fullName("player"), false)
end

-- UNIT_FLAGS fires for many flags and units; only a group member's combat
-- state changing is passed on. The last state is kept by name across roster
-- changes, so leaving combat right after one is still told. My own raid unit
-- is told apart by name (UnitIsUnit can return a secret in Forever) and left
-- to PLAYER_REGEN_*.
EVENTS.UNIT_FLAGS = function(g, unit)
  if not isGroupUnit(unit) then
    return
  end
  local name = fullName(unit)
  if name == nil or Names.same(name, fullName("player")) then
    return
  end
  local fighting = UnitAffectingCombat(unit) == true
  if (g.combat[name] or false) ~= fighting then
    g.combat[name] = fighting
    g:fire("COMBAT_CHANGED", name, fighting)
  end
end

-- In a trade the partner is the unit "NPC". Without it no partner is named,
-- and the trade is not reported: a guess could credit the wrong player. A
-- trade whose starting money the game doesn't give is not followed (R55).
EVENTS.TRADE_SHOW = function(g)
  g.tradeOpen = true
  local money = number(GetMoney())
  g.tradePartner = fullName("NPC")
  g.trade = money ~= nil and { partner = g.tradePartner, money = money } or nil
end

EVENTS.UI_INFO_MESSAGE = function(g, _, message)
  if g.trade ~= nil and message == ERR_TRADE_COMPLETE then
    g.trade.complete = true
    g:settleTrade()
  end
end

EVENTS.TRADE_CLOSED = function(g)
  g.tradeOpen = false
  g.tradePartner = nil
  local trade = g.trade
  if trade ~= nil and trade.closedAt == nil then
    trade.closedAt = GetTime()
    g:settleTrade()
  end
end

EVENTS.PLAYER_MONEY = function(g)
  g:settleTrade()
end

EVENTS.GUILD_ROSTER_UPDATE = function(g)
  g:readGuild()
end

EVENTS.PLAYER_GUILD_UPDATE = function(g)
  if IsInGuild() then
    C_GuildInfo.GuildRoster()
  end
  g:readGuild()
end

-- Starts translating game events: emit(event, ...) gets the events listed at
-- the top of this file; errors go to log(text). Call once.
-- The poll is armed first and the first reads run through safely, so a read
-- that fails at login can't stop the poll (R55).
function Game:listen(emit, log)
  self.emit, self.log = emit, log
  local function tick()
    C_Timer.After(POLL_SECONDS, tick)
    self:safely("poll", self.poll)
  end
  C_Timer.After(POLL_SECONDS, tick)
  local frame = CreateFrame("Frame")
  for event in pairs(EVENTS) do
    frame:RegisterEvent(event)
  end
  frame:SetScript("OnEvent", function(_, event, ...)
    self:safely(event, EVENTS[event], ...)
  end)
  self:safely("guild roster", function(g)
    if IsInGuild() then
      C_GuildInfo.GuildRoster()
    end
    g:readGuild()
  end)
  self:safely("position", function(g)
    g.lastSpot = spot()
  end)
end

ns.WoWGame = M

-- The transport backend ----------------------------------------------------------------------

local Backend = {}

-- The backend Comms/Transport sends through (the contract Sim/Bus.lua also
-- implements): send(prefix, text, dist, target) -> SendAddonMessageResult, and
-- inLockdown(). CHANNEL messages go to channelName, by its current id (the
-- number changes as the player joins and leaves channels). listen(fn, log)
-- hands every addon message with our prefix to fn(prefix, text, dist, sender),
-- the sender's name made canonical.
function Backend.new(channelName)
  local backend = {}

  function backend.send(prefix, message, dist, target)
    if dist == "CHANNEL" then
      local id = channelId(channelName)
      if id == nil then
        return SEND_INVALID_CHANNEL
      end
      target = tostring(id)
    end
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, prefix, message, dist, target)
    if not ok or result == false then
      return SEND_GENERAL_ERROR
    end
    return number(result) or SEND_OK
  end

  function backend.inLockdown()
    return C_ChatInfo.InChatMessagingLockdown() == true
  end

  function backend.listen(fn, log)
    local frame = CreateFrame("Frame")
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:SetScript("OnEvent", function(_, _, prefix, message, dist, sender)
      local ok, err = pcall(function()
        if prefix ~= Config.PREFIX then -- inside the pcall: a secret prefix can't be compared (R55)
          return
        end
        local name = canonical(sender)
        if name ~= nil then
          fn(prefix, message, dist, name)
        end
      end)
      if not ok and log ~= nil then
        pcall(log, "WoW CHAT_MSG_ADDON: " .. tostring(err))
      end
    end)
  end

  return backend
end

ns.WoWBackend = Backend

-- Clocks ---------------------------------------------------------------------------------------

-- Time for data (ratings, rides, deaths, stand ids): whole server seconds,
-- the same on every client (R4, R16).
ns.WoWClock = {
  now = function()
    return GetServerTime()
  end,
  after = function(_, seconds, fn)
    C_Timer.After(seconds, fn)
  end,
}

-- Time for the Transport's pump, throttle and reassembly: GetTime, which has
-- the sub-second steps GetServerTime lacks (R16).
ns.WoWPreciseClock = {
  now = function()
    return GetTime()
  end,
  after = function(_, seconds, fn)
    C_Timer.After(seconds, fn)
  end,
}
