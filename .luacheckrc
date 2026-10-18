-- Lua 5.1, the dialect WoW embeds.
std = "lua51"
max_line_length = false

-- Purity rule: Domain/, Comms/, App/, Sim/ and Core/ (except Core/Init.lua)
-- get NO extra globals, so any WoW API call there is a luacheck error.
-- Only the folders below may touch the game.

-- WoW API names the game-facing layers may read: exactly what Game/WoW.lua and
-- Core/Init.lua use. The C_* namespaces list their functions, so a call to
-- anything else is a luacheck error. Every C_* function and event used is in
-- Forever 1.60.1's generated API docs; the plain globals marked "legacy" are
-- not in those docs and are checked in game (Task 19).
local wow_api = {
  -- frames, timers, time
  "CreateFrame", -- legacy
  C_Timer = { fields = { "After" } },
  "GetTime",
  "GetServerTime",
  "date", -- legacy (WoW's os.date)
  "issecretvalue",
  -- names and units
  "GetNormalizedRealmName",
  "UNKNOWNOBJECT", -- legacy (a GlobalStrings text: the name placeholder)
  "UnitExists",
  "UnitName",
  "UnitFactionGroup",
  "UnitLevel",
  "UnitClass",
  "UnitIsDeadOrGhost",
  "UnitIsFeignDeath",
  "UnitAffectingCombat",
  "UnitPosition",
  -- location
  C_Map = { fields = { "GetBestMapForUnit", "GetPlayerMapPosition", "GetMapInfo", "GetMapLevels" } },
  "GetZoneText",
  "GetSubZoneText",
  "IsInInstance",
  -- group
  "IsInRaid", -- legacy
  "GetNumGroupMembers", -- legacy
  "GetNumSubgroupMembers", -- legacy
  C_PartyInfo = { fields = { "InviteUnit", "ConvertToRaid", "LeaveParty" } },
  -- summons
  C_SummonInfo = {
    fields = { "GetSummonConfirmSummoner", "GetSummonConfirmAreaName", "GetSummonConfirmTimeLeft", "CancelSummon" },
  },
  -- money and trade
  "GetMoney",
  "InitiateTrade",
  C_TradeInfo = { fields = { "SetTradeMoney" } },
  "ERR_TRADE_COMPLETE", -- legacy (a GlobalStrings text)
  -- guild, spells, items
  "IsInGuild",
  C_GuildInfo = { fields = { "GuildRoster" } },
  "GetNumGuildMembers", -- legacy
  "GetGuildRosterInfo", -- legacy
  C_SpellBook = { fields = { "IsSpellKnown" } },
  C_Item = { fields = { "GetItemCount" } },
  -- rules
  C_GameRules = { fields = { "IsHardcoreActive" } },
  -- chat channel and addon messages
  "JoinChannelByName", -- legacy
  "GetChannelName", -- legacy
  C_ChatInfo = { fields = { "SendAddonMessage", "InChatMessagingLockdown", "RegisterAddonMessagePrefix" } },
  -- addon metadata
  C_AddOns = { fields = { "GetAddOnMetadata" } },
}

local game_layer = {
  read_globals = wow_api,
  globals = { "TaxiDB", "TaxiCharDB", "SLASH_TAXI1", "SlashCmdList" },
}

files["Taxi/Game"] = game_layer
files["Taxi/Core/Init.lua"] = game_layer

-- The windows (Taxi/UI) talk to the Engine, not to the game, so they get only
-- the frame API and what the widgets read: no unit, group or spell calls, and
-- no globals of their own to write.
files["Taxi/UI"] = {
  read_globals = {
    "CreateFrame",
    "UIParent", -- frames from FrameXML
    "Minimap",
    "GameTooltip",
    "InCombatLockdown", -- the secure button's attributes change only out of combat
    "UnitAffectingCombat",
    "GetCursorPosition", -- dragging the minimap button
    "date", -- legacy (WoW's os.date): the History tab's times
    "UISpecialFrames", -- legacy: the names of the frames Esc closes (checked in game, Task 19)
  },
}

-- Specs and the helper: busted's globals, plus the Taxi loader the helper defines.
files["tests"] = {
  std = "+busted",
  globals = { "Taxi" },
}
