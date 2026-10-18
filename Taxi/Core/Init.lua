local addonName, ns = ...

-- The addon's start: SavedVariables on ADDON_LOADED, the real Engine on
-- PLAYER_LOGIN (Game/WoW.lua adapter, backend and clocks), its start once the
-- game's own chat channels are in, pruning on PLAYER_LOGOUT, and /taxi.
-- Loaded last (R1). Sets ns.engine and ns.db for the UI.
local Config, L, Store, Util = ns.Config, ns.L, ns.Store, ns.Util

local MAX_ERRORS = 50 -- errors kept for /taxi debug (R15)
-- Seconds after the first PLAYER_ENTERING_WORLD before the channel is joined,
-- so the game's own channels (General, Trade) keep their usual numbers.
local JOIN_DELAY = 5
-- The server answers a join a moment later: the channel's id is looked for
-- every JOIN_POLL seconds, for up to JOIN_TIMEOUT seconds (R54).
local JOIN_POLL = 0.5
local JOIN_TIMEOUT = 10
local PREFIX_OK = 0 -- Enum.RegisterAddonMessagePrefixResult.Success

local state = {
  errors = {}, -- the last MAX_ERRORS error lines
  errorCount = 0,
  status = nil, -- the last STATUS text
}

local function say(line)
  print(L.CHAT_PREFIX .. line)
end

-- The Engine's log sink (R15): errors are kept in memory and shown on
-- /taxi debug, never printed as they happen.
local function log(line)
  state.errorCount = state.errorCount + 1
  local errors = state.errors
  errors[#errors + 1] = date("%H:%M:%S") .. " " .. tostring(line)
  if #errors > MAX_ERRORS then
    table.remove(errors, 1)
  end
end

-- ADDON_LOADED ---------------------------------------------------------------------

local function loaded()
  local db = Store.init(TaxiDB)
  TaxiDB = db
  -- R17a: the flag is cleared at once, so it is never saved into TaxiDB.
  local newer = TaxiDB._newer
  TaxiDB._newer = nil
  state.newer = newer == true
  -- R17: data from a newer Taxi is never written; this session gets a
  -- throwaway db instead.
  state.db = state.newer and Store.init(nil) or db
  ns.db = state.db

  if type(TaxiCharDB) ~= "table" then
    TaxiCharDB = {}
  end
  if type(TaxiCharDB.stand) ~= "table" then
    TaxiCharDB.stand = { seats = Config.DEFAULT_SEATS, clickerPct = Config.DEFAULT_CLICKER_PCT, note = "" }
  end

  local result = C_ChatInfo.RegisterAddonMessagePrefix(Config.PREFIX)
  if result ~= PREFIX_OK then
    log("RegisterAddonMessagePrefix " .. Config.PREFIX .. ": " .. tostring(result))
  end
  state.loaded = true
end

-- PLAYER_LOGIN ----------------------------------------------------------------------

local function login()
  if not state.loaded then
    loaded()
  end
  local game = ns.WoWGame.new()
  if game:me() == nil then
    error("the game gives no name for the player") -- the Engine can't tell its own messages apart
  end
  local backend = ns.WoWBackend.new(Config.CHANNEL)
  -- Built without callbacks: Engine.new connects them (R40).
  local transport = ns.Transport.new{ backend = backend, clock = ns.WoWPreciseClock, prefix = Config.PREFIX }
  local engine = ns.Engine.new{
    game = game,
    transport = transport,
    clock = ns.WoWClock,
    db = state.db,
    charDb = TaxiCharDB,
    log = log,
  }
  state.engine = engine
  ns.engine = engine

  -- The window and the minimap button (UI/MainWindow.lua). A failure there is
  -- logged and must not stop the Engine.
  local main = ns.UI and ns.UI.Main
  if main then
    local ok, err = pcall(main.Start, main)
    if not ok then
      log("UI start: " .. tostring(err))
    end
  end

  -- Statuses are kept (/taxi debug shows the last, ns.status is for a window
  -- built later) and shown in the window's footer while it is open. With it
  -- closed there is nowhere else to see one (a full channel list, a newer
  -- version, a raid that would not convert), so they are said in chat then.
  engine:on("STATUS", function(key, line)
    state.status = line
    ns.status = { key = key, text = line }
    if not (main and main:IsShown()) then
      say(line)
    end
  end)
  backend.listen(function(prefix, message, dist, sender)
    transport:receive(prefix, message, dist, sender)
  end, log)
  game:listen(function(event, ...)
    engine:onGame(event, ...)
    if event == "PLAYER_DIED" and game:isHardcore() then
      engine:status("STATUS_HC_DEAD")
    end
  end, log)

  if state.newer then
    engine:onVersion() -- STATUS_UPDATE, once this session
  end
  if game:isHardcore() and game:isDead() then
    engine:status("STATUS_HC_DEAD")
  end
end

local function inChannel()
  local id = GetChannelName(Config.CHANNEL)
  return type(id) == "number" and id > 0
end

local function start(engine)
  local ok, err = pcall(engine.start, engine)
  if ok then
    state.started = true
  else
    log("start: " .. tostring(err))
    say(L.START_FAILED)
  end
end

-- The first PLAYER_ENTERING_WORLD: join the channel, wait for its id, then
-- start the Engine. With no id after JOIN_TIMEOUT the Engine starts anyway,
-- finds no channel and says STATUS_CHANNEL_FULL (R54).
local function enteredWorld()
  local engine = state.engine
  if state.starting or engine == nil then
    return
  end
  state.starting = true
  C_Timer.After(JOIN_DELAY, function()
    local checked, already = pcall(inChannel)
    if not (checked and already) then
      local ok, why = pcall(JoinChannelByName, Config.CHANNEL)
      if not ok then
        log("JoinChannelByName: " .. tostring(why))
      end
    end
    local waited = 0
    local function check()
      local ok, ready = pcall(inChannel)
      if (ok and ready) or waited >= JOIN_TIMEOUT then
        start(engine)
        return
      end
      waited = waited + JOIN_POLL
      C_Timer.After(JOIN_POLL, check)
    end
    check()
  end)
end

-- PLAYER_LOGOUT: SavedVariables are written right after this.
local function logout()
  if state.loaded and not state.newer then
    Store.prune(TaxiDB)
  end
end

-- /taxi -------------------------------------------------------------------------------

local function engineState()
  local engine = state.engine
  if engine == nil then
    return L.DEBUG_NOT_BUILT
  elseif engine.disabled then
    return L.DEBUG_DISABLED
  elseif state.started then
    return L.DEBUG_RUNNING
  end
  return L.DEBUG_STARTING
end

local function debug()
  local version = C_AddOns.GetAddOnMetadata(addonName, "Version") or "?"
  say(L.fmt("DEBUG_VERSION", version, Config.PROTOCOL, Store.VERSION))
  local engine = state.engine
  local hardcore = engine ~= nil and engine.game:isHardcore() or false
  say(L.fmt("DEBUG_STATE", engineState(), tostring(hardcore), state.status or L.DEBUG_NONE))
  if state.newer then
    say(L.DEBUG_SESSION_ONLY)
  end
  say(L.fmt("DEBUG_ERRORS", state.errorCount, #state.errors))
  for _, line in ipairs(state.errors) do
    say((line:gsub("|", "||"))) -- "|" starts a chat escape sequence
  end
end

local commands = {
  [""] = function()
    local main = ns.UI and ns.UI.Main
    if main then
      main:Toggle()
    else
      say(L.SLASH_USAGE)
    end
  end,
  debug = debug,
}

SLASH_TAXI1 = Config.SLASH
SlashCmdList.TAXI = function(msg)
  local command = commands[(Util.trim(msg) or ""):lower()]
  if command then
    command()
  else
    say(L.SLASH_USAGE)
  end
end

-- Events ------------------------------------------------------------------------------

-- Runs fn; an error goes to the log sink (R55). Returns whether fn ran.
local function guarded(event, fn)
  local ok, err = pcall(fn)
  if not ok then
    log(event .. ": " .. tostring(err))
  end
  return ok
end

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, arg)
  if event == "ADDON_LOADED" then
    if arg == addonName then
      frame:UnregisterEvent("ADDON_LOADED")
      guarded(event, loaded)
    end
  elseif event == "PLAYER_LOGIN" then
    if not guarded(event, login) then
      say(L.START_FAILED)
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    guarded(event, enteredWorld)
  elseif event == "PLAYER_LOGOUT" then
    guarded(event, logout)
  end
end)
