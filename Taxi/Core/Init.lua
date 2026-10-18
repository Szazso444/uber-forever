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
-- Seconds between that join and Engine:start, which checks it: the channel id
-- may take a moment to show up.
local START_DELAY = 2

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

  C_ChatInfo.RegisterAddonMessagePrefix(Config.PREFIX)
  state.loaded = true
end

-- PLAYER_LOGIN ----------------------------------------------------------------------

local function login()
  if not state.loaded then
    loaded()
  end
  local game = ns.WoWGame.new()
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

  -- Statuses are said in chat and kept: ns.status lets a window opened later
  -- show one said at login (a dead Hardcore character, a newer TaxiDB).
  engine:on("STATUS", function(key, line)
    state.status = line
    ns.status = { key = key, text = line }
    say(line)
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

-- The first PLAYER_ENTERING_WORLD: join the channel, then start the Engine.
local function enteredWorld()
  local engine = state.engine
  if state.starting or engine == nil then
    return
  end
  state.starting = true
  C_Timer.After(JOIN_DELAY, function()
    pcall(engine.game.joinChannel, engine.game, Config.CHANNEL)
    C_Timer.After(START_DELAY, function()
      local ok, err = pcall(engine.start, engine)
      if ok then
        state.started = true
      else
        log("start: " .. tostring(err))
        say(L.START_FAILED)
      end
    end)
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

local frame = CreateFrame("Frame")
frame:RegisterEvent("ADDON_LOADED")
frame:RegisterEvent("PLAYER_LOGIN")
frame:RegisterEvent("PLAYER_ENTERING_WORLD")
frame:RegisterEvent("PLAYER_LOGOUT")
frame:SetScript("OnEvent", function(_, event, arg)
  if event == "ADDON_LOADED" and arg == addonName then
    frame:UnregisterEvent("ADDON_LOADED")
    loaded()
  elseif event == "PLAYER_LOGIN" then
    local ok, err = pcall(login)
    if not ok then
      log("login: " .. tostring(err))
      say(L.START_FAILED)
    end
  elseif event == "PLAYER_ENTERING_WORLD" then
    enteredWorld()
  elseif event == "PLAYER_LOGOUT" then
    logout()
  end
end)
