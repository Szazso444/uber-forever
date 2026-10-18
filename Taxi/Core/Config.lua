local _, ns = ...

-- The addon's names and most of its tunable numbers in one place. Pure data: no
-- WoW API. A few constants that belong to one file's own mechanism stay there:
-- Core/Init.lua (channel join timing), App/Engine.lua (pump and sweep
-- intervals), App/Driver.lua (invite and raid timeouts, seat limits),
-- App/Traveler.lua (landing window, jump and crew distances), Comms/Transport.lua
-- (chunk limits, throttle wait), Game/WoW.lua (poll and trade timings) and
-- UI/Dialogs.lua (toast time).
local M = {
  -- Names
  NAME = "Taxi",
  PREFIX = "TaxiFvr", -- addon message prefix, max 16 characters
  CHANNEL = "TaxiForever",
  SLASH = "/taxi",

  -- Wire
  PROTOCOL = 1,
  CHUNK_PAYLOAD = 230, -- payload bytes per addon message (hard cap is 255)
  RETRY_TIMEOUT = 10, -- seconds before a request is retried
  DEDUPE_SECONDS = 600,
  REASSEMBLY_SECONDS = 30,

  -- Stands
  HEARTBEAT = 60, -- seconds between stand heartbeats
  STAND_TTL = 180, -- seconds a stand stays on the board without a heartbeat
  STAND_MOVE_YARDS = 50, -- a stand closes when its owner moves farther than this
  DEFAULT_SEATS = 3,
  DEFAULT_CLICKER_PCT = 25, -- percent of the fare per clicker (50/25/25 split)
  TIP_PRESETS = { 5000, 10000 }, -- copper: 50s and 1g
  MAX_TIP = 100000000, -- copper (10,000g): a TIP or TIP_ACK above this is ignored

  -- Summon guard
  GUARD_YARDS = 40,
  GUARD_LOW_TRUST = 3.0, -- warn when the warlock's score is below this

  -- Deaths
  DEATH_WINDOW = 120, -- seconds after arrival in which a death counts against the warlock
  ALIVE_GRACE = 60, -- a victim seen alive this long after a reported death is lying

  -- Rating sync
  QUERY_COOLDOWN = 600, -- seconds between queries to the same warlock
  QUERY_MAX_REPLIES = 20,
  QUERY_JITTER = 5, -- replies are delayed by 0..QUERY_JITTER seconds
  QUERY_MAX_RECORDS = 50, -- records per reply
  RIDE_MEMORY = 1800, -- seconds Witness remembers a ride before dropping it

  -- Rating maths
  RATING = {
    PRIOR_MEAN = 3.5,
    PRIOR_WEIGHT = 5,
    W_TWO_SIDED = 1.0,
    W_ONE_SIDED = 0.3,
    W_DEATH = 5.0,
    W_RELAYED = 0.2,
    W_RELAYED_CORROBORATED = 0.5,
    CORROBORATE_MIN = 3, -- relayers needed for the corroborated weight
    NEW_BELOW = 5, -- a warlock with fewer ratings is shown as "New"
    CAP_PER_KIND = 500,
    STRIKES_MAX = 3,
    -- Relayed (second-hand) ratings can never weigh more than this together.
    -- Per relayer: the most one relayer can add for one warlock and kind.
    -- In total: the most all relayers can add for one warlock and kind.
    RELAY_CAP_PER_RELAYER = 0.5,
    RELAY_CAP_TOTAL = 2.0,
    -- A rating, death, ride log or receipt dated more than this many seconds
    -- after the receiver's clock is refused as "future".
    FUTURE_SLACK = 300,
  },

  -- Warlock spells and items (Classic IDs, assumed for Forever: not yet checked
  -- in game, see docs/testing/in-game-checklist.md J1 and J3)
  RITUAL_SPELL = 698, -- Ritual of Summoning
  SOUL_SHARD_ITEM = 6265,
  -- Mage portals. mapID is the destination city's uiMapID: a portal traveler
  -- has arrived when their own map is this one. The ids and spell ids are
  -- Classic's, assumed for Forever and not yet checked in game (checklist J1, J2).
  PORTALS = {
    { spellId = 10059, key = "stormwind", mapID = 1453 },
    { spellId = 11416, key = "ironforge", mapID = 1455 },
    { spellId = 11419, key = "darnassus", mapID = 1457 },
    { spellId = 11417, key = "orgrimmar", mapID = 1454 },
    { spellId = 11418, key = "undercity", mapID = 1458 },
    { spellId = 11420, key = "thunderbluff", mapID = 1456 },
  },
}

ns.Config = M
