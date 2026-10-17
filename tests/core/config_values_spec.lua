-- Pins every Global Constraints number so a stray edit to Config is caught.
describe("Config values", function()
  local C = Taxi.load().Config

  it("has the expected top-level values", function()
    local expected = {
      NAME = "Taxi", PREFIX = "TaxiFvr", CHANNEL = "TaxiForever", SLASH = "/taxi",
      PROTOCOL = 1, HEARTBEAT = 60, STAND_TTL = 180, STAND_MOVE_YARDS = 50,
      GUARD_YARDS = 40, DEATH_WINDOW = 120, ALIVE_GRACE = 60,
      DEFAULT_SEATS = 3, DEFAULT_CLICKER_PCT = 25, GUARD_LOW_TRUST = 3.0,
      QUERY_COOLDOWN = 600, QUERY_MAX_REPLIES = 20, QUERY_JITTER = 5,
      QUERY_MAX_RECORDS = 50, RETRY_TIMEOUT = 10, CHUNK_PAYLOAD = 230,
      DEDUPE_SECONDS = 600, REASSEMBLY_SECONDS = 30, RIDE_MEMORY = 1800,
      RITUAL_SPELL = 698, SOUL_SHARD_ITEM = 6265, MAX_TIP = 100000000,
    }
    for key, value in pairs(expected) do
      assert.are.equal(value, C[key], key)
    end
  end)

  it("has the rating maths", function()
    assert.are.same({
      PRIOR_MEAN = 3.5, PRIOR_WEIGHT = 5, W_TWO_SIDED = 1.0, W_ONE_SIDED = 0.3,
      W_DEATH = 5.0, W_RELAYED = 0.2, W_RELAYED_CORROBORATED = 0.5,
      CORROBORATE_MIN = 3, NEW_BELOW = 5, CAP_PER_KIND = 500, STRIKES_MAX = 3,
      RELAY_CAP_PER_RELAYER = 0.5, RELAY_CAP_TOTAL = 2.0, FUTURE_SLACK = 300,
    }, C.RATING)
  end)

  it("has the six city portals, each with its destination's map", function()
    assert.are.same({
      { spellId = 10059, key = "stormwind", mapID = 1453 },
      { spellId = 11416, key = "ironforge", mapID = 1455 },
      { spellId = 11419, key = "darnassus", mapID = 1457 },
      { spellId = 11417, key = "orgrimmar", mapID = 1454 },
      { spellId = 11418, key = "undercity", mapID = 1458 },
      { spellId = 11420, key = "thunderbluff", mapID = 1456 },
    }, C.PORTALS)
  end)

  it("keeps the chunk payload plus prefix inside the 255-byte addon message limit", function()
    assert.is_true(#C.PREFIX + C.CHUNK_PAYLOAD <= 255)
  end)
end)
