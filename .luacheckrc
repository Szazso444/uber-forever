-- Lua 5.1, the dialect WoW embeds.
std = "lua51"
max_line_length = false

-- Purity rule: Domain/, Comms/, App/, Sim/ and Core/ (except Core/Init.lua)
-- get NO extra globals, so any WoW API call there is a luacheck error.
-- Only the folders below may touch the game.

-- WoW API names the game-facing layers may read. Task 16 fills this in.
local wow_api = {}

local game_layer = {
  read_globals = wow_api,
  globals = { "TaxiDB", "TaxiCharDB", "SLASH_TAXI1", "SlashCmdList" },
}

files["Taxi/Game"] = game_layer
files["Taxi/UI"] = game_layer
files["Taxi/Core/Init.lua"] = game_layer

-- Specs and the helper: busted's globals, plus the Taxi loader the helper defines.
files["tests"] = {
  std = "+busted",
  globals = { "Taxi" },
}
