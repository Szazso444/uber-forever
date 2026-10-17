local _, ns = ...

-- Every tunable number and name in one place. Pure data: no WoW API.
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

  -- Summon guard
  GUARD_YARDS = 40,
  GUARD_LOW_TRUST = 3.0, -- warn when the warlock's score is below this

  -- Deaths
  DEATH_WINDOW = 120, -- seconds after a ride starts in which a death counts
  ALIVE_GRACE = 60,

  -- Rating sync
  QUERY_COOLDOWN = 600, -- seconds between queries to the same warlock
  QUERY_MAX_REPLIES = 20,
  QUERY_JITTER = 5, -- replies are delayed by 0..QUERY_JITTER seconds
  QUERY_MAX_RECORDS = 50, -- records per reply
  RIDE_MEMORY = 1800, -- seconds a finished ride is remembered

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
  },

  -- Warlock spells and items (Classic IDs; verified in-game in Task 19)
  RITUAL_SPELL = 698, -- Ritual of Summoning
  SOUL_SHARD_ITEM = 6265,
  PORTALS = {
    { spellId = 10059, key = "stormwind" },
    { spellId = 11416, key = "ironforge" },
    { spellId = 11419, key = "darnassus" },
    { spellId = 11417, key = "orgrimmar" },
    { spellId = 11418, key = "undercity" },
    { spellId = 11420, key = "thunderbluff" },
  },
}

ns.Config = M
