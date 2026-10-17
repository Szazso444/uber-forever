local _, ns = ...

-- A simulated WoW server for addon messages. Each attached player gets a
-- backend with the same contract Game/WoW.lua implements over the real API:
--   backend.send(prefix, text, dist, target) -> result code
--   backend.inLockdown() -> bool
-- The bus does what the server does to a message:
--   * it stamps the sender itself. Nothing in the text can change who a message
--     is "from", which is what the reputation system depends on;
--   * it throttles each sender with a token bucket of 10 that refills 1 a second;
--   * it refuses a sender in lockdown and any text over 255 bytes;
--   * it routes CHANNEL to the other players of the sender's faction, WHISPER to
--     the target, PARTY and RAID to the sender's group, and delivers after a delay.
-- Pure Lua: no WoW API (this file is also loaded in-game for /taxi sim).
local M = {}

-- Enum.SendAddonMessageResult values the bus returns.
local OK, ADDON_THROTTLE, CHANNEL_THROTTLE, GENERAL_ERROR, LOCKDOWN = 0, 3, 8, 9, 11

local MAX_TEXT = 255
local MAX_PREFIX = 16
local BURST = 10 -- tokens a sender can hold
local REFILL_PER_SECOND = 1
-- Time comes from repeated float additions (0.2 five times is not exactly 1),
-- so a token that is short by this much counts as present.
local EPSILON = 1e-6

-- Drops come from a small deterministic generator (Park-Miller, a multiplicative
-- LCG) so that a seed replays the same simulation. Its products stay below 2^53,
-- which keeps the arithmetic exact in Lua's doubles.
local LCG_MODULUS = 2147483647
local LCG_MULTIPLIER = 16807

local Bus = {}
Bus.__index = Bus

-- opts: clock (required), latency (seconds a message takes, default 0.1),
-- seed (default 1).
function M.new(opts)
  if type(opts) ~= "table" or not opts.clock then
    error("Bus.new needs a clock", 2)
  end
  local state = math.floor(opts.seed or 1) % LCG_MODULUS
  if state == 0 then
    state = 1
  end
  local bus = setmetatable({
    clock = opts.clock,
    latency = opts.latency or 0.1,
    state = state,
    dropRate = 0,
    players = {}, -- name -> player
    order = {}, -- players in the order they attached
    log = {},
  }, Bus)
  -- The first draws of a small seed are tiny; use them up.
  bus:random()
  bus:random()
  return bus
end

-- A number in (0, 1).
function Bus:random()
  self.state = self.state * LCG_MULTIPLIER % LCG_MODULUS
  return self.state / LCG_MODULUS
end

function Bus:player(name)
  local player = self.players[name]
  if not player then
    error("unknown player " .. tostring(name), 3)
  end
  return player
end

-- Adds a player. receiveFn(prefix, text, dist, sender) is called when a message
-- reaches them. Returns the player's backend.
function Bus:attach(name, faction, receiveFn)
  if type(name) ~= "string" or name == "" then
    error("Bus:attach needs a player name", 2)
  end
  if self.players[name] then
    error("player already attached: " .. name, 2)
  end
  if type(receiveFn) ~= "function" then
    error("Bus:attach needs a receive function", 2)
  end
  local player = {
    name = name,
    faction = faction,
    receive = receiveFn,
    group = nil,
    locked = false,
    tokens = BURST,
    refilledAt = self.clock:now(),
  }
  self.players[name] = player
  self.order[#self.order + 1] = player
  return {
    send = function(prefix, text, dist, target)
      return self:transmit(player, prefix, text, dist, target)
    end,
    inLockdown = function()
      return player.locked
    end,
  }
end

-- Takes a player off the server (they log out). Messages still on their way to
-- them are lost, and their old backend's sends are refused from then on. The
-- name can be attached again, as a new player.
function Bus:detach(name)
  local player = self:player(name)
  player.detached = true
  self.players[name] = nil
  for i, p in ipairs(self.order) do
    if p == player then
      table.remove(self.order, i)
      break
    end
  end
end

-- groupId puts the player in a group (PARTY and RAID reach its other members);
-- nil takes them out of any group.
function Bus:setGroup(name, groupId)
  self:player(name).group = groupId
end

function Bus:setLockdown(name, locked)
  self:player(name).locked = locked and true or false
end

-- The share of deliveries (0 to 1) that are lost on the way. The sender is not
-- told: a lost message was still accepted.
function Bus:setDropRate(rate)
  self.dropRate = rate
end

-- Every accepted send, oldest first: {sender, prefix, dist, target, text}.
-- Refused sends (throttled, locked down, invalid) are not in it.
function Bus:sent()
  return self.log
end

local function takeToken(player, now)
  local elapsed = now - player.refilledAt
  player.tokens = math.min(BURST, player.tokens + elapsed * REFILL_PER_SECOND)
  player.refilledAt = now
  if player.tokens < 1 - EPSILON then
    return false
  end
  player.tokens = math.max(0, player.tokens - 1)
  return true
end

-- Who a message reaches, or nil when the destination is not valid.
function Bus:recipients(sender, dist, target)
  local list = {}
  if dist == "CHANNEL" then
    for _, player in ipairs(self.order) do
      if player ~= sender and player.faction == sender.faction then
        list[#list + 1] = player
      end
    end
  elseif dist == "WHISPER" then
    if type(target) ~= "string" then
      return nil
    end
    list[1] = self.players[target] -- no such player: accepted, reaches nobody
  elseif dist == "PARTY" or dist == "RAID" then
    if sender.group == nil then
      return nil
    end
    for _, player in ipairs(self.order) do
      if player ~= sender and player.group == sender.group then
        list[#list + 1] = player
      end
    end
  else
    return nil
  end
  return list
end

function Bus:transmit(sender, prefix, text, dist, target)
  if sender.detached then
    return GENERAL_ERROR
  end
  if sender.locked then
    return LOCKDOWN
  end
  if type(prefix) ~= "string" or prefix == "" or #prefix > MAX_PREFIX
      or type(text) ~= "string" or #text > MAX_TEXT then
    return GENERAL_ERROR
  end
  local recipients = self:recipients(sender, dist, target)
  if not recipients then
    return GENERAL_ERROR
  end
  if not takeToken(sender, self.clock:now()) then
    return dist == "CHANNEL" and CHANNEL_THROTTLE or ADDON_THROTTLE
  end

  self.log[#self.log + 1] = { sender = sender.name, prefix = prefix, dist = dist, target = target, text = text }
  for _, recipient in ipairs(recipients) do
    if not (self.dropRate > 0 and self:random() < self.dropRate) then
      self.clock:after(self.latency, function()
        if not recipient.detached then
          recipient.receive(prefix, text, dist, sender.name)
        end
      end)
    end
  end
  return OK
end

ns.Bus = M
