-- Game/WoW.lua and Core/Init.lua run against a fake of the WoW API: just the
-- calls they make, shaped as Forever 1.60.1's generated API docs describe them.
-- The fake can't prove the real API behaves that way (Task 19 checks that in
-- game); it pins the adapter's own logic: names, event translation, result
-- codes, the bootstrap rulings (R15, R17, R17a) and the contract FakeGame sets.

-- A fake WoW world for one client. Tests set its fields and fire events.
local function fakeWoW()
  local w = {
    now = 100, -- GetTime()
    serverStart = 1700000000, -- GetServerTime() is serverStart + now
    realm = "Forever",
    frames = {},
    timers = {},
    units = {
      player = { name = "Ana Smith", faction = "Alliance", level = 30, class = "WARLOCK", className = "Warlock" },
    },
    raid = false,
    secrets = {},
    channels = {}, -- name -> id
    channelsFull = false,
    joinCalls = {},
    sent = {},
    sendResult = 0,
    lockdown = false,
    summon = nil, -- { summoner, area, left }
    cancelled = 0,
    money = 0,
    initiated = {},
    tradeRaises = false,
    tradeMoneySet = nil,
    guild = nil, -- roster names, or nil when not in a guild
    rosterRequests = 0,
    spells = {},
    items = {},
    hardcore = true,
    mapInfo = { [1455] = { name = "Ironforge" }, [1446] = { name = "Tanaris" } },
    mapLevels = { [1446] = { 40, 50 }, [1455] = { 0, 0 } },
    zone = "Ironforge",
    subzone = "The Commons",
    inInstance = false,
    invites = {},
    converted = 0,
    leftParty = 0,
    prefixes = {},
    prints = {},
    metadata = { Version = "0.1.0" },
  }

  function w.fire(event, ...)
    for _, frame in ipairs(w.frames) do
      if frame.events[event] and frame.onEvent then
        frame.onEvent(frame, event, ...)
      end
    end
  end

  -- Moves time forward, running the C_Timer callbacks that fall due.
  function w.advance(seconds)
    local target = w.now + seconds
    while true do
      table.sort(w.timers, function(a, b) return a.at < b.at end)
      local timer = w.timers[1]
      if timer == nil or timer.at > target then
        break
      end
      table.remove(w.timers, 1)
      w.now = math.max(w.now, timer.at)
      timer.fn()
    end
    w.now = target
  end

  local function unit(token)
    return type(token) == "string" and w.units[token] or nil
  end

  local function count(prefix)
    local n = 0
    while w.units[prefix .. (n + 1)] do
      n = n + 1
    end
    return n
  end

  local env = setmetatable({}, { __index = _G })
  env.print = function(text) w.prints[#w.prints + 1] = text end
  env.date = function() return "12:00:00" end
  env.SlashCmdList = {}
  env.ERR_TRADE_COMPLETE = "Trade complete."
  env.CreateFrame = function()
    local frame = { events = {} }
    function frame:RegisterEvent(event) self.events[event] = true end
    function frame:UnregisterEvent(event) self.events[event] = nil end
    function frame:SetScript(_, fn) self.onEvent = fn end
    w.frames[#w.frames + 1] = frame
    return frame
  end
  env.C_Timer = { After = function(seconds, fn) w.timers[#w.timers + 1] = { at = w.now + seconds, fn = fn } end }
  env.GetTime = function() return w.now end
  env.GetServerTime = function() return math.floor(w.serverStart + w.now) end
  env.GetNormalizedRealmName = function() return w.realm end
  env.issecretvalue = function(v) return w.secrets[v] == true end

  env.UnitExists = function(token) return unit(token) ~= nil end
  env.UnitName = function(token)
    local u = unit(token)
    if u then return u.name, u.realm end
  end
  env.UnitFactionGroup = function(token) return unit(token).faction end
  env.UnitLevel = function(token) return unit(token).level end
  env.UnitClass = function(token) local u = unit(token); return u.className, u.class end
  env.UnitIsDeadOrGhost = function(token) return unit(token).dead == true end
  env.UnitIsFeignDeath = function(token) return unit(token).feign == true end
  env.UnitAffectingCombat = function(token) return unit(token).combat == true end
  env.UnitPosition = function(token)
    local u = unit(token)
    if u and u.wx then return u.wx, u.wy, 0, 0 end
  end
  env.IsInRaid = function() return w.raid end
  env.GetNumSubgroupMembers = function() return count("party") end
  env.GetNumGroupMembers = function()
    if w.raid then return count("raid") end
    local n = count("party")
    return n > 0 and n + 1 or 0
  end

  env.C_Map = {
    GetBestMapForUnit = function(token) local u = unit(token); return u and u.mapID end,
    GetPlayerMapPosition = function(_, token) local u = unit(token); return u and u.x and { x = u.x, y = u.y } end,
    GetMapInfo = function(id) return w.mapInfo[id] end,
    GetMapLevels = function(id) local l = w.mapLevels[id]; if l then return l[1], l[2], 0, 0 end end,
  }
  env.GetZoneText = function() return w.zone end
  env.GetSubZoneText = function() return w.subzone end
  env.IsInInstance = function() return w.inInstance, w.inInstance and "party" or "none" end

  env.C_PartyInfo = {
    InviteUnit = function(name) w.invites[#w.invites + 1] = name end,
    ConvertToRaid = function() w.converted = w.converted + 1 end,
    LeaveParty = function() w.leftParty = w.leftParty + 1 end,
  }
  env.C_SummonInfo = {
    GetSummonConfirmSummoner = function() return w.summon and w.summon.summoner end,
    GetSummonConfirmAreaName = function() return w.summon and w.summon.area or "" end,
    GetSummonConfirmTimeLeft = function() return w.summon and w.summon.left or 0 end,
    CancelSummon = function() w.cancelled = w.cancelled + 1; w.summon = nil end,
  }
  env.GetMoney = function() return w.money end
  env.InitiateTrade = function(token) w.initiated[#w.initiated + 1] = token end
  env.C_TradeInfo = {
    SetTradeMoney = function(copper)
      if w.tradeRaises then error("blocked") end
      w.tradeMoneySet = copper
    end,
  }
  env.IsInGuild = function() return w.guild ~= nil end
  env.C_GuildInfo = { GuildRoster = function() w.rosterRequests = w.rosterRequests + 1 end }
  env.GetNumGuildMembers = function() return w.guild and #w.guild or 0 end
  env.GetGuildRosterInfo = function(i) return w.guild[i] end
  env.C_SpellBook = { IsSpellKnown = function(id) return w.spells[id] == true end }
  env.C_Item = { GetItemCount = function(id) return w.items[id] or 0 end }
  env.JoinChannelByName = function(name)
    w.joinCalls[#w.joinCalls + 1] = name
    if not w.channelsFull then w.channels[name] = 5 end
  end
  env.GetChannelName = function(name) return w.channels[name] or 0, name end
  env.C_GameRules = { IsHardcoreActive = function() return w.hardcore end }
  env.C_ChatInfo = {
    SendAddonMessage = function(prefix, text, dist, target)
      if w.sendRaises then error("bad chat type") end
      w.sent[#w.sent + 1] = { prefix = prefix, text = text, dist = dist, target = target }
      return w.sendResult
    end,
    InChatMessagingLockdown = function() return w.lockdown end,
    RegisterAddonMessagePrefix = function(prefix) w.prefixes[prefix] = true; return 0 end,
  }
  env.C_AddOns = { GetAddOnMetadata = function(_, key) return w.metadata[key] end }
  return w, env
end

-- Runs one addon file the way WoW does, with the fake API as its globals.
local function run(path, env, ns)
  local chunk = assert(loadfile(path))
  setfenv(chunk, env)
  chunk("Taxi", ns)
end

describe("WoW game adapter", function()
  local ns, w, env, game, events, logged

  before_each(function()
    ns = Taxi.load()
    w, env = fakeWoW()
    run("Taxi/Game/WoW.lua", env, ns)
    game = ns.WoWGame.new()
    events, logged = {}, {}
  end)

  local function listen()
    game:listen(function(event, ...) events[#events + 1] = { event, ... } end, function(text) logged[#logged + 1] = text end)
  end

  local function seen(name)
    local out = {}
    for _, ev in ipairs(events) do
      if ev[1] == name then out[#out + 1] = ev end
    end
    return out
  end

  it("implements every method of the adapter contract FakeGame implements", function()
    local fake = getmetatable(ns.FakeGame.new({}, {})).__index
    local missing = {}
    for name, fn in pairs(fake) do
      if type(fn) == "function" and type(game[name]) ~= "function" then
        missing[#missing + 1] = name
      end
    end
    table.sort(missing)
    assert.are.same({}, missing)
  end)

  describe("names", function()
    it("me is the player's full name", function()
      assert.are.equal("Ana Smith", game:me())
    end)

    it("adds a realm the game gives and drops my own", function()
      w.units.party1 = { name = "Bo Lee", realm = "Elsewhere" }
      w.units.party2 = { name = "Cy Dee", realm = "Forever" }
      assert.are.same({ "Ana Smith", "Bo Lee-Elsewhere", "Cy Dee" }, game:groupNames())
      assert.are.equal("party1", game:unitFor("Bo Lee-Elsewhere"))
      assert.are.equal("party2", game:unitFor("Cy Dee-Forever"))
    end)

    it("treats a secret name as unknown", function()
      w.units.party1 = { name = "Hid Den" }
      w.secrets["Hid Den"] = true
      assert.is_nil(game:unitFor("Hid Den"))
      assert.are.same({ "Ana Smith" }, game:groupNames())
    end)
  end)

  describe("identity", function()
    it("reads faction, level, class, Hardcore and death", function()
      assert.are.same({ "Alliance", 30, "WARLOCK", true, false },
        { game:faction(), game:level(), game:class(), game:isHardcore(), game:isDead() })
      w.units.player.dead = true
      assert.is_true(game:isDead())
      w.units.player.feign = true
      assert.is_false(game:isDead())
      w.hardcore = false
      assert.is_false(game:isHardcore())
    end)
  end)

  describe("location", function()
    it("puts the map, world and zone facts together", function()
      local p = w.units.player
      p.mapID, p.x, p.y, p.wx, p.wy = 1455, 0.25, 0.75, -4800.5, 120.25
      assert.are.same({ mapID = 1455, x = 0.25, y = 0.75, wx = -4800.5, wy = 120.25,
        zone = "Ironforge", subzone = "The Commons", inInstance = false }, game:location())
    end)

    it("gives nil, never 0 or an empty text, for what the game can't say (R21)", function()
      w.zone, w.subzone, w.inInstance = "", "", true
      assert.are.same({ inInstance = true }, game:location())
    end)

    it("names a map, and gives nil for a map it doesn't know", function()
      assert.are.equal("Tanaris", game:mapName(1446))
      assert.is_nil(game:mapName(9999))
      assert.is_nil(game:mapName(nil))
    end)

    it("gives a zone's level range, nil where the game has none", function()
      assert.are.same({ 40, 50 }, { game:zoneLevels(1446) })
      assert.are.same({}, { game:zoneLevels(1455) })
      assert.are.same({}, { game:zoneLevels(9999) })
    end)
  end)

  describe("group", function()
    it("finds party members by unit, me as player", function()
      w.units.party1 = { name = "Bo Lee", combat = true, dead = true, wx = 10, wy = 20, mapID = 1455 }
      assert.are.equal("player", game:unitFor("Ana Smith"))
      assert.are.equal("party1", game:unitFor(" Bo  Lee "))
      assert.is_nil(game:unitFor("Bo"))
      assert.is_nil(game:unitFor(nil))
      assert.are.same({ 10, 20, 1455 }, { game:unitPos("party1") })
      assert.is_true(game:unitInCombat("party1"))
      assert.is_true(game:unitDead("party1"))
      assert.are.equal(2, game:groupSize())
      assert.is_false(game:isRaid())
    end)

    it("scans raid units in a raid, where I am one of them", function()
      w.raid = true
      w.units.raid1 = { name = "Bo Lee" }
      w.units.raid2 = w.units.player
      w.units.raid3 = { name = "Cy Dee" }
      assert.are.equal("raid3", game:unitFor("Cy Dee"))
      assert.are.equal("player", game:unitFor("Ana Smith"))
      assert.are.same({ "Bo Lee", "Ana Smith", "Cy Dee" }, game:groupNames())
      assert.are.equal(3, game:groupSize())
      assert.is_true(game:isRaid())
    end)

    it("knows nothing of a unit that isn't there", function()
      assert.are.same({}, { game:unitPos("party3") })
      assert.are.same({}, { game:unitPos(nil) })
      assert.is_nil(game:unitInCombat("party3"))
      assert.is_nil(game:unitDead("party3"))
      assert.are.same({}, game:groupNames())
      assert.are.equal(0, game:groupSize())
    end)

    it("invites, converts and leaves through C_PartyInfo", function()
      game:invite("Bo Lee")
      game:convertToRaid()
      game:leaveGroup()
      assert.are.same({ "Bo Lee" }, w.invites)
      assert.are.same({ 1, 1 }, { w.converted, w.leftParty })
    end)
  end)

  describe("summons", function()
    it("gives the summoner and area, nil without a summon", function()
      assert.is_nil(game:summonFacts())
      w.summon = { summoner = "Dar Kbolt-Forever", area = "Ironforge", left = 120 }
      assert.are.same({ summoner = "Dar Kbolt", areaName = "Ironforge" }, game:summonFacts())
      w.summon.area = ""
      assert.are.same({ summoner = "Dar Kbolt" }, game:summonFacts())
    end)

    it("cancels a summon", function()
      w.summon = { summoner = "Dar Kbolt", area = "Ironforge", left = 120 }
      game:cancelSummon()
      assert.are.equal(1, w.cancelled)
    end)
  end)

  describe("money and trade", function()
    before_each(function() w.units.party1 = { name = "Dar Kbolt" } end)

    it("opens a trade with a group member only", function()
      assert.is_true(game:openTrade("Dar Kbolt"))
      assert.is_false(game:openTrade("Nobody Here"))
      assert.are.same({ "party1" }, w.initiated)
    end)

    it("puts money in a trade only while the window is open", function()
      listen()
      assert.is_false(game:trySetTradeMoney(5000))
      w.fire("TRADE_SHOW")
      assert.is_true(game:trySetTradeMoney(5000))
      assert.are.equal(5000, w.tradeMoneySet)
      w.tradeRaises = true
      assert.is_false(game:trySetTradeMoney(6000))
      w.fire("TRADE_CLOSED")
      w.tradeRaises = false
      assert.is_false(game:trySetTradeMoney(7000))
    end)

    it("reads money", function()
      w.money = 12345
      assert.are.equal(12345, game:money())
    end)
  end)

  describe("other", function()
    it("knows guildmates from the guild roster", function()
      w.guild = { "Bo Lee-Forever", "Cy Dee-Elsewhere" }
      listen()
      assert.are.equal(1, w.rosterRequests)
      w.fire("GUILD_ROSTER_UPDATE", false)
      assert.is_true(game:isGuildmate("Bo Lee"))
      assert.is_true(game:isGuildmate("Cy Dee-Elsewhere"))
      assert.is_false(game:isGuildmate("Cy Dee"))
      assert.is_false(game:isGuildmate(nil))
    end)

    it("lists the portal spells I know, with their keys", function()
      w.spells[11416] = true
      w.spells[10059] = true
      assert.are.same({ { spellId = 10059, key = "stormwind" }, { spellId = 11416, key = "ironforge" } }, game:knownPortals())
    end)

    it("counts soul shards", function()
      w.items[6265] = 4
      assert.are.equal(4, game:soulShards())
    end)

    it("joins the channel, and says full when the game gives no channel id", function()
      assert.is_true(game:joinChannel("TaxiForever"))
      assert.is_true(game:joinChannel("TaxiForever"))
      assert.are.same({ "TaxiForever" }, w.joinCalls) -- already in it: no second join
      w.channelsFull = true
      assert.are.same({ nil, "full" }, { game:joinChannel("Other") })
    end)
  end)

  describe("game events", function()
    before_each(function() listen() end)

    it("turns a summon popup into SUMMON_OFFERED and its end into one SUMMON_GONE", function()
      w.summon = { summoner = "Dar Kbolt", area = "Ironforge", left = 120 }
      w.fire("CONFIRM_SUMMON", 0, false)
      w.fire("CANCEL_SUMMON")
      w.fire("CANCEL_SUMMON")
      assert.are.same({ { "SUMMON_OFFERED" }, { "SUMMON_GONE" } }, events)
    end)

    it("sees a summon accepted on the popup go, on the next poll", function()
      w.summon = { summoner = "Dar Kbolt", area = "Ironforge", left = 120 }
      w.fire("CONFIRM_SUMMON", 0, false)
      w.advance(1)
      assert.are.equal(0, #seen("SUMMON_GONE"))
      w.summon = nil -- accepted: the game has no pending summon any more
      w.advance(1)
      w.advance(5)
      assert.are.equal(1, #seen("SUMMON_GONE"))
    end)

    it("reports zone changes, and moves the poll sees, as MOVED", function()
      local p = w.units.player
      p.mapID, p.wx, p.wy = 1455, 0, 0
      w.fire("ZONE_CHANGED_NEW_AREA")
      assert.are.equal(1, #seen("MOVED"))
      w.advance(3) -- standing still
      assert.are.equal(1, #seen("MOVED"))
      p.wx = 30
      w.advance(1)
      assert.are.equal(2, #seen("MOVED"))
      p.mapID = 1446
      w.advance(1)
      assert.are.equal(3, #seen("MOVED"))
      w.fire("PLAYER_ENTERING_WORLD", false, true)
      w.fire("ZONE_CHANGED")
      assert.are.equal(5, #seen("MOVED"))
    end)

    it("passes on group changes, my death and the server's death notices", function()
      w.fire("GROUP_ROSTER_UPDATE")
      w.fire("PLAYER_DEAD")
      w.fire("HARDCORE_DEATHS", "Vic Tim-Forever")
      assert.are.same({ { "GROUP_CHANGED" }, { "PLAYER_DIED" }, { "HC_DEATH", "Vic Tim" } }, events)
    end)

    it("never reports a group member's death from their health (R36)", function()
      w.units.party1 = { name = "Bo Lee", dead = true }
      w.fire("UNIT_HEALTH", "party1")
      w.fire("UNIT_FLAGS", "party1")
      assert.are.equal(0, #seen("MEMBER_DIED"))
    end)

    it("reports combat changes for me and my group, once per change", function()
      w.units.party1 = { name = "Bo Lee" }
      w.fire("PLAYER_REGEN_DISABLED")
      w.fire("PLAYER_REGEN_ENABLED")
      w.fire("UNIT_FLAGS", "party1") -- not fighting, as before
      w.units.party1.combat = true
      w.fire("UNIT_FLAGS", "party1")
      w.fire("UNIT_FLAGS", "party1")
      w.fire("UNIT_FLAGS", "target")
      w.fire("UNIT_FLAGS", "player")
      assert.are.same({
        { "COMBAT_CHANGED", "Ana Smith", true },
        { "COMBAT_CHANGED", "Ana Smith", false },
        { "COMBAT_CHANGED", "Bo Lee", true },
      }, events)
    end)

    it("leaves my own raid unit to PLAYER_REGEN, without comparing units", function()
      w.raid = true
      w.units.raid1 = w.units.player
      w.units.player.combat = true
      env.UnitIsUnit = function() error("UnitIsUnit can return a secret in Forever") end
      w.fire("UNIT_FLAGS", "raid1")
      assert.are.same({}, events)
      assert.are.same({}, logged)
    end)

    it("still reports a member leaving combat after the roster changed", function()
      w.units.party1 = { name = "Bo Lee", combat = true }
      w.fire("UNIT_FLAGS", "party1")
      w.fire("GROUP_ROSTER_UPDATE")
      w.units.party1.combat = false
      w.fire("UNIT_FLAGS", "party1")
      assert.are.same({ { "COMBAT_CHANGED", "Bo Lee", true }, { "GROUP_CHANGED" }, { "COMBAT_CHANGED", "Bo Lee", false } }, events)
    end)

    it("names no partner for a trade whose partner the game doesn't give", function()
      w.units.party1 = { name = "Dar Kbolt" }
      game:openTrade("Dar Kbolt")
      w.fire("TRADE_SHOW") -- no "NPC" unit
      w.money = 500
      w.fire("UI_INFO_MESSAGE", 1, "Trade complete.")
      w.fire("TRADE_CLOSED")
      assert.are.same({}, events)
    end)

    it("reports a completed trade's money as TRADE_DONE(partner, gave, got)", function()
      w.units.NPC = { name = "Dar Kbolt" }
      w.money = 10000
      w.fire("TRADE_SHOW")
      w.fire("UI_INFO_MESSAGE", 1, "Trade complete.")
      w.fire("TRADE_CLOSED")
      w.money = 5000 -- the money arrives a moment later
      w.fire("PLAYER_MONEY")
      w.fire("TRADE_CLOSED")
      w.fire("PLAYER_MONEY")
      assert.are.same({ { "TRADE_DONE", "Dar Kbolt", 5000, 0 } }, events)

      events = {}
      w.fire("TRADE_SHOW")
      w.money = 8000
      w.fire("UI_INFO_MESSAGE", 1, "Trade complete.")
      w.fire("TRADE_CLOSED")
      assert.are.same({ { "TRADE_DONE", "Dar Kbolt", 0, 3000 } }, events)
    end)

    it("ignores a cancelled trade, and money that comes long after one", function()
      w.units.NPC = { name = "Dar Kbolt" }
      w.money = 10000
      w.fire("TRADE_SHOW")
      w.fire("TRADE_CLOSED")
      w.money = 10050 -- loot, not the trade
      w.fire("PLAYER_MONEY")
      w.fire("TRADE_SHOW")
      w.fire("UI_INFO_MESSAGE", 1, "Trade complete.")
      w.fire("TRADE_CLOSED")
      w.now = w.now + 10
      w.money = 20000
      w.fire("PLAYER_MONEY")
      assert.are.same({}, events)
    end)

    it("logs a failing translation instead of raising it", function()
      game.emit = function() error("listener broke") end
      assert.has_no.errors(function() w.fire("PLAYER_DEAD") end)
      assert.are.equal(1, #logged)
      assert.truthy(logged[1]:find("listener broke", 1, true))
    end)
  end)
end)

describe("WoW backend", function()
  local ns, w, env, backend

  before_each(function()
    ns = Taxi.load()
    w, env = fakeWoW()
    run("Taxi/Game/WoW.lua", env, ns)
    backend = ns.WoWBackend.new("TaxiForever")
  end)

  it("sends CHANNEL messages to the channel's id, others to their target", function()
    w.channels.TaxiForever = 6
    assert.are.equal(0, backend.send("TaxiFvr", "a", "CHANNEL"))
    assert.are.equal(0, backend.send("TaxiFvr", "b", "WHISPER", "Bo Lee"))
    assert.are.same({
      { prefix = "TaxiFvr", text = "a", dist = "CHANNEL", target = "6" },
      { prefix = "TaxiFvr", text = "b", dist = "WHISPER", target = "Bo Lee" },
    }, w.sent)
  end)

  it("refuses a CHANNEL message while not in the channel", function()
    assert.are.equal(7, backend.send("TaxiFvr", "a", "CHANNEL"))
    assert.are.same({}, w.sent)
  end)

  it("gives Transport the game's SendAddonMessageResult codes", function()
    for _, code in ipairs({ 3, 8, 11, 12 }) do
      w.sendResult = code
      assert.are.equal(code, backend.send("TaxiFvr", "a", "PARTY"))
    end
    w.sendResult = nil
    assert.are.equal(0, backend.send("TaxiFvr", "a", "PARTY"))
    w.sendResult = false
    assert.are.equal(9, backend.send("TaxiFvr", "a", "PARTY"))
    w.sendRaises = true
    assert.are.equal(9, backend.send("TaxiFvr", "a", "PARTY"))
  end)

  it("is in lockdown when chat messaging is", function()
    assert.is_false(backend.inLockdown())
    w.lockdown = true
    assert.is_true(backend.inLockdown())
  end)

  it("hands on our addon messages with the sender's full name", function()
    local got = {}
    backend.listen(function(...) got[#got + 1] = { ... } end)
    w.fire("CHAT_MSG_ADDON", "TaxiFvr", "x", "CHANNEL", "Bo Lee-Forever", "", 0, 6, "TaxiForever", 0)
    w.fire("CHAT_MSG_ADDON", "TaxiFvr", "y", "WHISPER", "Cy Dee-Elsewhere", "Ana Smith", 0, 0, "", 0)
    w.fire("CHAT_MSG_ADDON", "OtherAddon", "z", "PARTY", "Bo Lee-Forever", "", 0, 0, "", 0)
    assert.are.same({ { "TaxiFvr", "x", "CHANNEL", "Bo Lee" }, { "TaxiFvr", "y", "WHISPER", "Cy Dee-Elsewhere" } }, got)
  end)
end)

describe("WoW clocks", function()
  it("tell data time by the server and transport time by GetTime (R4, R16)", function()
    local ns = Taxi.load()
    local w, env = fakeWoW()
    run("Taxi/Game/WoW.lua", env, ns)
    w.now = 100.6
    assert.are.equal(1700000100, ns.WoWClock:now())
    assert.are.equal(100.6, ns.WoWPreciseClock:now())
    local ran = 0
    ns.WoWClock:after(2, function() ran = ran + 1 end)
    ns.WoWPreciseClock:after(0.2, function() ran = ran + 10 end)
    w.advance(2)
    assert.are.equal(11, ran)
  end)
end)

describe("Init", function()
  local ns, w, env

  -- Loads WoW.lua and Init.lua and runs the login: ADDON_LOADED, PLAYER_LOGIN
  -- and the first PLAYER_ENTERING_WORLD.
  local function boot(saved)
    ns = Taxi.load()
    w, env = fakeWoW()
    env.TaxiDB = saved
    run("Taxi/Game/WoW.lua", env, ns)
    run("Taxi/Core/Init.lua", env, ns)
    w.fire("ADDON_LOADED", "Taxi", false)
    w.fire("PLAYER_LOGIN")
    w.fire("PLAYER_ENTERING_WORLD", true, false)
  end

  local function statuses()
    local out = {}
    for _, text in ipairs(w.prints) do
      out[#out + 1] = text
    end
    return out
  end

  it("sets up the saved data, the prefix and the slash command on load", function()
    boot(nil)
    assert.are.equal(ns.Store.VERSION, env.TaxiDB.version)
    assert.are.same({ stand = { seats = 3, clickerPct = 25, note = "" } }, env.TaxiCharDB)
    assert.is_true(w.prefixes.TaxiFvr)
    assert.are.equal("/taxi", env.SLASH_TAXI1)
    assert.is_function(env.SlashCmdList.TAXI)
  end)

  it("keeps a character's own stand settings", function()
    ns = Taxi.load()
    w, env = fakeWoW()
    env.TaxiCharDB = { stand = { seats = 5, clickerPct = 20, note = "hi" } }
    run("Taxi/Game/WoW.lua", env, ns)
    run("Taxi/Core/Init.lua", env, ns)
    w.fire("ADDON_LOADED", "Taxi", false)
    assert.are.same({ stand = { seats = 5, clickerPct = 20, note = "hi" } }, env.TaxiCharDB)
  end)

  it("builds the engine on login and starts it once the game's channels are in", function()
    boot(nil)
    local engine = ns.engine
    assert.are.equal("Ana Smith", engine.me)
    assert.are.equal(env.TaxiDB, engine.db)
    assert.are.equal(env.TaxiCharDB, engine.charDb)
    assert.are.same({}, w.joinCalls)
    w.advance(10)
    assert.are.same({ "TaxiForever" }, w.joinCalls)
    assert.is_false(engine.disabled)
    -- the transport pumps: a queued CHANNEL message goes out to the channel
    engine:send("QUERY", { target = "Dar Kbolt" }, "CHANNEL")
    w.advance(1)
    assert.are.equal(1, #w.sent)
    assert.are.equal("5", w.sent[1].target)
  end)

  it("disables the engine when no channel can be joined", function()
    ns = Taxi.load()
    w, env = fakeWoW()
    w.channelsFull = true
    run("Taxi/Game/WoW.lua", env, ns)
    run("Taxi/Core/Init.lua", env, ns)
    w.fire("ADDON_LOADED", "Taxi", false)
    w.fire("PLAYER_LOGIN")
    w.fire("PLAYER_ENTERING_WORLD", true, false)
    w.advance(10)
    assert.is_true(ns.engine.disabled)
    assert.are.same({ "Taxi: " .. ns.L.STATUS_CHANNEL_FULL }, statuses())
  end)

  it("feeds our addon messages and the game's events to the engine", function()
    boot(nil)
    w.advance(10)
    local text = "ab:1/1:" .. ns.Protocol.encode("STAND_END", "ab", { standId = "Bo Lee@1" })
    local heard = {}
    ns.engine.handle = function(_, msg, sender) heard[#heard + 1] = { msg.type, sender } end
    w.fire("CHAT_MSG_ADDON", "TaxiFvr", text, "CHANNEL", "Bo Lee-Forever", "", 0, 5, "TaxiForever", 0)
    assert.are.same({ { "STAND_END", "Bo Lee" } }, heard)
    local games = {}
    ns.engine.onGame = function(_, event, ...) games[#games + 1] = { event, ... } end
    w.fire("HARDCORE_DEATHS", "Vic Tim")
    assert.are.same({ { "HC_DEATH", "Vic Tim" } }, games)
  end)

  it("gives the engine a session-only db when TaxiDB is newer, and never writes TaxiDB (R17, R17a)", function()
    local saved = { version = 99, ratings = { X = 1 }, keep = "me" }
    boot(saved)
    assert.are.equal(saved, env.TaxiDB)
    assert.is_nil(saved._newer)
    assert.are_not.equal(saved, ns.engine.db)
    assert.are.equal(ns.Store.VERSION, ns.engine.db.version)
    assert.are.same({ "Taxi: " .. ns.L.STATUS_UPDATE }, statuses())
    w.fire("PLAYER_LOGOUT")
    assert.are.same({ version = 99, ratings = { X = 1 }, keep = "me" }, saved)
  end)

  it("prunes the saved data on logout", function()
    boot(nil)
    local list = {}
    for i = 1, ns.Config.RATING.CAP_PER_KIND + 3 do
      list[i] = { rater = "R" .. i, stars = 5, ts = i }
    end
    env.TaxiDB.ratings["Dar Kbolt"] = { trust = list }
    w.fire("PLAYER_LOGOUT")
    assert.are.equal(ns.Config.RATING.CAP_PER_KIND, #env.TaxiDB.ratings["Dar Kbolt"].trust)
  end)

  it("says a dead Hardcore character has died, on login and on death", function()
    ns = Taxi.load()
    w, env = fakeWoW()
    w.units.player.dead = true
    run("Taxi/Game/WoW.lua", env, ns)
    run("Taxi/Core/Init.lua", env, ns)
    w.fire("ADDON_LOADED", "Taxi", false)
    w.fire("PLAYER_LOGIN")
    assert.are.same({ "Taxi: Your Hardcore character has died." }, statuses())
    assert.are.same({ key = "STATUS_HC_DEAD", text = "Your Hardcore character has died." }, ns.status) -- for a window opened later
    assert.are.same({ nil, "dead" }, { ns.engine:openStand{ kind = "lock" } })

    boot(nil)
    w.units.player.dead = true
    w.fire("PLAYER_DEAD")
    assert.are.same({ "Taxi: Your Hardcore character has died." }, statuses())
  end)

  it("keeps the last 50 errors and shows them only on /taxi debug (R15)", function()
    boot(nil)
    for i = 1, 53 do
      ns.engine.log("boom " .. i)
    end
    assert.are.same({}, w.prints)
    env.SlashCmdList.TAXI("debug")
    local text = table.concat(w.prints, "\n")
    assert.truthy(text:find("0.1.0", 1, true))
    assert.truthy(text:find("53", 1, true))
    assert.falsy(text:find("boom 3\n", 1, true))
    assert.truthy(text:find("boom 4", 1, true))
    assert.truthy(text:find("boom 53", 1, true))
  end)

  it("escapes | in logged text it prints", function()
    boot(nil)
    ns.engine.log("bad |cff00ff00 name")
    env.SlashCmdList.TAXI("debug")
    assert.truthy(table.concat(w.prints, "\n"):find("bad ||cff00ff00 name", 1, true))
  end)

  it("toggles the main window on /taxi, and explains itself without one", function()
    boot(nil)
    env.SlashCmdList.TAXI("")
    assert.are.same({ "Taxi: " .. ns.L.SLASH_USAGE }, w.prints)
    local toggled = 0
    ns.UI = { Main = { Toggle = function() toggled = toggled + 1 end } }
    env.SlashCmdList.TAXI("  ")
    assert.are.equal(1, toggled)
    w.prints = {}
    env.SlashCmdList.TAXI("nonsense")
    assert.are.same({ "Taxi: " .. ns.L.SLASH_USAGE }, w.prints)
  end)
end)
