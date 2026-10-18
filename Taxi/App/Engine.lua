local _, ns = ...

-- The Engine: one player's Taxi client. It ties the network (a Transport) and
-- the game (an adapter: Sim/FakeGame.lua on a PC, Game/WoW.lua in game) to the
-- pure Domain modules, and tells the UI what happened through events.
--
--   local e = Engine.new{game, transport, clock, db, charDb, rng, log}
--   e:start()
--
-- Service files (App/Reputation, App/Driver, App/Traveler, App/Clicker) load
-- after this one and add to the Engine before any Engine.new:
--   * methods:        function Engine:openStand(o) ... end
--   * message types:  Engine.handlers.TYPE = function(e, msg, sender, dist) end
--   * game events:    Engine.gameHandlers.EVENT = function(e, ...) end
-- Assigning a handler ADDS it: several services can handle the same message
-- type or game event, and they run in the order they were assigned (load
-- order). Reading Engine.handlers.TYPE gives that list. Each handler runs in
-- its own pcall, so one failing handler cannot stop the others, the receive
-- path or the clock; its error goes to the log sink.
--
-- Messages come from untrusted players. A message reaches the handlers only
-- when it is not the player's own and carries every field REQUIRED lists for
-- its type, so a handler can use those fields without nil checks.
--
-- Pure Lua: no WoW API (this file is also loaded in-game for /taxi sim).
local Config, L, Names = ns.Config, ns.L, ns.Names
local Board, Stand, Witness, Callbacks = ns.Board, ns.Stand, ns.Witness, ns.Callbacks

local Engine = {}
Engine.__index = Engine

local PUMP_INTERVAL = 0.2 -- seconds between transport pumps
local TICK_INTERVAL = 30 -- seconds between board and witness expiry sweeps
Engine.TICK_INTERVAL = TICK_INTERVAL -- for the UI and the simulation, which time themselves by it

-- Handler registries ---------------------------------------------------------------

-- A table where assigning a function to a key appends it to that key's list,
-- and reading a key gives the list (nil when nothing is registered).
local function registry()
  local lists = {}
  return setmetatable({}, {
    __index = lists,
    __newindex = function(_, key, fn)
      if type(fn) ~= "function" then
        error("a handler must be a function", 2)
      end
      local list = lists[key]
      if list == nil then
        list = {}
        lists[key] = list
      end
      list[#list + 1] = fn
    end,
  })
end

Engine.handlers = registry()
Engine.gameHandlers = registry()

-- Fields a message must carry before any handler sees it (R13). Every field a
-- type's schema has is listed unless it is optional:
--   STAND x, y (display only), subzone (can be blank), portals, note;
--   REQUEST dest (mage rides only); DECLINE reason; RATING owed, received and
--   pct (share ratings only); DEATH source (never trusted); PORTAL_UP dest.
-- L and R fields always decode to a table, so they never need listing.
Engine.REQUIRED = {
  STAND = { "standId", "kind", "faction", "mapID", "wx", "wy", "zone", "seatsFree", "clickers", "clickerPct" },
  STAND_END = { "standId" },
  REQUEST = { "standId", "offer", "level" },
  ACCEPT = { "rideId", "standId" },
  DECLINE = { "standId" },
  CLICK_APPLY = { "standId", "askedPct" },
  CLICK_OFFER = { "standId", "offeredPct" },
  CLICK_OK = { "standId", "agreedPct" },
  CLICK_NO = { "standId" },
  CLICK_LEAVE = { "standId" },
  RIDE_START = { "rideId", "warlock" },
  ARRIVED = { "rideId", "warlock" },
  RIDE_LOG = { "rideId", "traveler" },
  RATING = { "kind", "target", "stars", "id", "ts" },
  DEATH = { "rideId", "victim", "warlock", "secs" },
  TIP = { "rideId", "amount" },
  TIP_ACK = { "rideId", "amount" },
  PORTAL_UP = {},
  QUERY = { "target" },
  QUERY_R = { "target", "records" },
}

local function discard() end

-- Creating and running ------------------------------------------------------------

-- o: game (adapter), transport (a Transport; the Engine takes over its
-- onMessage and onVersion), clock (colon methods now/after), db (TaxiDB),
-- charDb (TaxiCharDB), rng (a function returning a number in [0, 1); default
-- math.random), log (a function taking one error text; default discards).
function Engine.new(o)
  local e = setmetatable({
    game = o.game,
    transport = o.transport,
    clock = o.clock,
    db = o.db,
    charDb = o.charDb or {},
    rng = o.rng or math.random,
    log = o.log or discard,
    callbacks = Callbacks.new(),
    me = o.game:me(),
    board = Board.new(),
    rides = {}, -- request key (traveler .. "#" .. standId) -> ride
    witness = Witness.new(o.db),
    stand = nil, -- my open stand, if any
    ledgers = {},
    disabled = false, -- no channel: public actions refuse with "disabled"
    dirty = false, -- data a crash would lose was stored this session
  }, Engine)
  e.transport.onMessage = function(msg, sender, dist)
    e:handle(msg, sender, dist)
  end
  e.transport.onVersion = function(sender, version)
    e:safely("version", e.onVersion, e, sender, version)
  end
  return e
end

-- Runs fn(...) in a pcall; an error goes to the log sink with `what` and the
-- player's name. Returns whether fn ran without error.
function Engine:safely(what, fn, ...)
  local ok, err = pcall(fn, ...)
  if not ok then
    pcall(self.log, tostring(self.me) .. ": " .. what .. ": " .. tostring(err))
  end
  return ok
end

-- Runs fn every `seconds` until the engine stops.
local function every(e, seconds, fn)
  local function tick()
    if e.stopped then
      return
    end
    e:safely("timer", fn, e)
    e.clock:after(seconds, tick)
  end
  e.clock:after(seconds, tick)
end

-- STATUS(key, text) for the UI.
function Engine:status(key)
  self:emit("STATUS", key, L[key])
end

-- Instances lock addon messages down: say so once per visit, and close my
-- stand, whose spot is no longer reachable.
local function checkInstance(e)
  local loc = e.game:location()
  local inside = type(loc) == "table" and loc.inInstance == true
  if inside and not e.inInstance then
    e.inInstance = true
    e:status("STATUS_LOCKDOWN")
    if e.stand then
      e:closeStand()
    end
  elseif not inside then
    e.inInstance = false
  end
end

-- Joins the channel (on failure: disabled, with STATUS_CHANNEL_FULL), checks
-- for an instance, and starts the expiry sweep and the transport pump.
function Engine:start()
  if not self.game:joinChannel(Config.CHANNEL) then
    self.disabled = true
    self:status("STATUS_CHANNEL_FULL")
  end
  checkInstance(self)
  every(self, TICK_INTERVAL, self.tick)
  every(self, PUMP_INTERVAL, function(e)
    e.transport:pump()
  end)
end

-- Stops the timers and every message in or out (the player went offline).
function Engine:stop()
  self.stopped = true
end

-- The periodic sweep: stands not heard from for STAND_TTL leave the board,
-- and the witness forgets old rides.
function Engine:tick(now)
  now = now or self.clock:now()
  local before = 0
  for _ in pairs(self.board.stands) do
    before = before + 1
  end
  Board.expire(self.board, now)
  local after = 0
  for _ in pairs(self.board.stands) do
    after = after + 1
  end
  if after ~= before then
    self:emit("BOARD_CHANGED")
  end
  self.witness:expire(now)
end

-- A newer protocol version is in use: tell the player once per session.
function Engine:onVersion()
  if not self.updateShown then
    self.updateShown = true
    self:status("STATUS_UPDATE")
  end
end

-- Events for the UI -----------------------------------------------------------------

-- Listens to an engine event. A listener that raises is logged and does not
-- stop the other listeners or the engine code that emitted the event.
function Engine:on(event, fn)
  return self.callbacks:on(event, function(...)
    self:safely(event .. " listener", fn, ...)
  end)
end

function Engine:emit(event, ...)
  self.callbacks:emit(event, ...)
end

-- Network ---------------------------------------------------------------------------

-- Switches sending off (on = true) or on again: while /taxi sim shows another
-- player's engine, the real one must not put anything on the real channel. What
-- was queued but not yet sent is dropped. Receiving goes on. One exception
-- (R62): the player's own DEATH report is never held back, because a Hardcore
-- death is final and the report cannot be sent later. So a DEATH is sent while
-- muted, and a dead Hardcore character's queue (which holds nothing but that
-- DEATH, see Reputation's PLAYER_DIED) is not dropped.
function Engine:mute(on)
  self.muted = on == true
  if self.muted and not (self.game:isHardcore() and self.game:isDead()) then
    self.transport:clear()
  end
end

-- Queues a message. Returns its msgId, or nil and why not:
--   "dead"      a dead Hardcore character sends nothing but its DEATH report;
--   "disabled"  no channel, so no CHANNEL messages;
--   "stopped"   the engine was stopped;
--   "muted"     see Engine:mute (everything but a DEATH report);
--   "too_large" from the transport.
function Engine:send(msgType, fields, dist, target)
  if self.stopped then
    return nil, "stopped"
  end
  if self.muted and msgType ~= "DEATH" then
    return nil, "muted"
  end
  if msgType ~= "DEATH" and self.game:isHardcore() and self.game:isDead() then
    return nil, "dead"
  end
  if dist == "CHANNEL" and self.disabled then
    return nil, "disabled"
  end
  return self.transport:send(msgType, fields, dist, target)
end

-- A decoded message from the transport. The player's own messages, unknown
-- types and messages missing a required field are dropped; the rest go to
-- every handler of the type.
function Engine:handle(msg, sender, dist)
  if self.stopped or type(msg) ~= "table" or type(sender) ~= "string" then
    return
  end
  if Names.same(sender, self.me) then
    return
  end
  local required = Engine.REQUIRED[msg.type]
  if required == nil then
    return
  end
  for _, field in ipairs(required) do
    if msg[field] == nil then
      return
    end
  end
  for _, fn in ipairs(self.handlers[msg.type] or {}) do
    self:safely(msg.type .. " handler", fn, self, msg, sender, dist)
  end
end

-- A game event from the adapter, passed to every handler of the event.
function Engine:onGame(event, ...)
  if self.stopped then
    return
  end
  for _, fn in ipairs(self.gameHandlers[event] or {}) do
    self:safely(tostring(event) .. " game handler", fn, self, ...)
  end
end

-- Public actions --------------------------------------------------------------------

-- Wraps a public action so it refuses with nil, "disabled" while the Engine has
-- no channel, and with nil, "dead" once the player's Hardcore character has
-- died (a death there is final, R35/R37). Services define their actions with it:
--   Engine.requestRide = Engine.action(function(e, standId, offer, dest) ... end)
function Engine.action(fn)
  return function(e, ...)
    if e.disabled then
      return nil, "disabled"
    end
    if e.game:isHardcore() and e.game:isDead() then
      return nil, "dead"
    end
    return fn(e, ...)
  end
end

-- Group helpers shared by the services ----------------------------------------------

-- Where group messages (TIP, TIP_ACK, PORTAL_UP) go: in a raid "PARTY" would
-- only reach my own subgroup.
function Engine:groupDist()
  return self.game:isRaid() and "RAID" or "PARTY"
end

-- True when `name` is another member of my group (never myself).
function Engine:inGroup(name)
  return not Names.same(name, self.me) and Names.normalize(name) ~= nil and self.game:unitFor(name) ~= nil
end

-- Closes my stand: STAND_END goes out (once messages can) and STAND_CHANGED
-- tells the UI. A heartbeat still waiting in the transport is dropped: it
-- waits behind other traffic (R68), and would put the stand back on the boards
-- after its STAND_END. Returns whether there was a stand to close.
function Engine:closeStand()
  local stand = self.stand
  if stand == nil then
    return false
  end
  stand.closed = true
  self.stand = nil
  self.transport:drop("STAND")
  self:send("STAND_END", { standId = stand.standId }, "CHANNEL")
  self:emit("STAND_CHANGED", stand)
  return true
end

-- The board (R18, R41) --------------------------------------------------------------

-- Stand ids are owner@seconds, so an id names its owner: a STAND or STAND_END
-- counts only when its id starts with the sender's own (tidied) name and "@".
-- No one can then write to another player's stand id, and an entry on the
-- board can only ever be its owner's (R18 holds by construction; names never
-- contain "@").
local function ownsId(standId, sender)
  local name = Names.normalize(sender)
  if name == nil or name == "" or type(standId) ~= "string" then
    return false
  end
  local prefix = name .. "@"
  return standId:sub(1, #prefix) == prefix
end

-- A stand heartbeat. The owner is the sender the server stamped. The stand's
-- zone is this client's own name for its map, never the sender's text when
-- there is one (R65).
Engine.handlers.STAND = function(e, msg, sender)
  if not ownsId(msg.standId, sender) then
    return
  end
  local now = e.clock:now()
  local localZone = e.game:mapName(msg.mapID)
  Board.upsert(e.board, Stand.fromFields(msg, sender, now, localZone), now)
  e:emit("BOARD_CHANGED")
end

-- Only a stand's owner can end it.
Engine.handlers.STAND_END = function(e, msg, sender)
  if ownsId(msg.standId, sender) and Board.get(e.board, msg.standId) ~= nil then
    Board.remove(e.board, msg.standId)
    e:emit("BOARD_CHANGED")
  end
end

Engine.gameHandlers.MOVED = function(e)
  checkInstance(e)
end

ns.Engine = Engine
