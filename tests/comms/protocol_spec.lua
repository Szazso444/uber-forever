describe("Protocol", function()
  local ns = Taxi.load()
  local P = ns.Protocol

  local FULL_STAND = {
    standId = "s1", kind = "lock", faction = "Alliance", mapID = 1455, x = 0.5, y = 0.25,
    wx = 100, wy = -20, zone = "Ironforge", subzone = "The Commons", seatsFree = 3, clickers = 2,
    clickerPct = 25, portals = {}, note = "hi ^ there, 100%",
  }

  local FULL_RECORD = {
    kind = "share", rater = "Ana Smith", stars = 4, id = "r2", ts = 1700000001,
    owed = 10000, received = 10000, pct = 25, other = "Bo Lee",
  }

  -- One sample per schema type (QUERY_R and STAND also appear with empty
  -- lists, and REQUEST with every optional field missing). The coverage test
  -- below fails when a schema has no sample.
  local SAMPLES = {
    { "STAND", FULL_STAND },
    { "STAND", {
      standId = "s2", kind = "mage", faction = "Horde", mapID = 1454, x = 0.123456, y = 0.75,
      wx = -3.5, wy = 1e15, zone = "Orgrimmar", subzone = "", seatsFree = 0, clickers = 0,
      clickerPct = 25, portals = { "orgrimmar", "stormwind", "a,b;c" }, note = "",
    } },
    { "STAND_END", { standId = "s1" } },
    { "REQUEST", { standId = "s1", offer = 5000, level = 60, dest = "Orgrimmar" } },
    { "REQUEST", { standId = "s1" } },
    { "ACCEPT", { rideId = "Ana Smith#s1", standId = "s1" } },
    { "DECLINE", { standId = "s1", reason = "full" } },
    { "CLICK_APPLY", { standId = "s1", askedPct = 25 } },
    { "CLICK_OFFER", { standId = "s1", offeredPct = 30 } },
    { "CLICK_OK", { standId = "s1", agreedPct = 25 } },
    { "CLICK_NO", { standId = "s1" } },
    { "CLICK_LEAVE", { standId = "s1" } },
    { "RIDE_START", { rideId = "Ana Smith#s1", warlock = "Dar Kbolt" } },
    { "ARRIVED", { rideId = "Ana Smith#s1", warlock = "Dar Kbolt" } },
    { "RIDE_LOG", { rideId = "Ana Smith#s1", traveler = "Ana Smith" } },
    { "RATING", {
      kind = "trust", target = "Dar Kbolt", stars = 5, id = "r1", ts = 1700000000,
      owed = 5000, received = 5000, pct = 25,
    } },
    { "DEATH", { rideId = "Ana Smith#s1", victim = "Ana Smith", warlock = "Dar Kbolt", secs = 42, source = "self" } },
    { "TIP", { rideId = "Ana Smith#s1", amount = 10000 } },
    { "TIP_ACK", { rideId = "Ana Smith#s1", amount = 10000 } },
    { "PORTAL_UP", { dest = "Orgrimmar" } },
    { "QUERY", { target = "Dar Kbolt" } },
    { "QUERY_R", { target = "Dar Kbolt", records = { FULL_RECORD, { kind = "trust", rater = "Cy Forger", stars = 1, id = "r3", ts = 5 } } } },
    { "QUERY_R", { target = "Dar Kbolt", records = {} } },
  }

  -- What decode should give back for the fields passed to encode: an empty
  -- string or an empty list is an empty wire field, which decodes to nil.
  local function expectedFields(fields)
    local out = {}
    for name, value in pairs(fields) do
      if value == "" or (type(value) == "table" and #value == 0) then
        value = nil
      end
      out[name] = value
    end
    return out
  end

  local function hasKey(list, wanted)
    for _, entry in ipairs(list) do
      if entry == wanted then
        return true
      end
    end
    return false
  end

  describe("constants", function()
    it("VERSION comes from Config", function()
      assert.are.equal(1, P.VERSION)
      assert.are.equal(ns.Config.PROTOCOL, P.VERSION)
    end)

    it("RECORD lists the record fields in wire order", function()
      assert.are.same({ "kind", "rater", "stars", "id", "ts", "owed", "received", "pct", "other" }, P.RECORD)
    end)

    it("every schema is a list of {name, kind} with a known kind and a name that cannot clash with the header", function()
      local reserved = { v = true, type = true, msgId = true }
      for msgType, schema in pairs(P.SCHEMAS) do
        assert.is_truthy(#schema >= 1, msgType)
        local seen = {}
        for _, field in ipairs(schema) do
          assert.are.equal("string", type(field[1]), msgType)
          assert.is_truthy(hasKey({ "s", "n", "L", "R" }, field[2]), msgType .. "." .. tostring(field[1]))
          assert.is_nil(reserved[field[1]], msgType .. "." .. field[1])
          assert.is_nil(seen[field[1]], msgType .. "." .. field[1])
          seen[field[1]] = true
        end
      end
    end)

    it("has the field order the wire format fixes", function()
      local names = {}
      for _, field in ipairs(P.SCHEMAS.STAND) do
        names[#names + 1] = field[1] .. ":" .. field[2]
      end
      assert.are.equal(
        "standId:s kind:s faction:s mapID:n x:n y:n wx:n wy:n zone:s subzone:s seatsFree:n clickers:n clickerPct:n portals:L note:s",
        table.concat(names, " ")
      )
      assert.are.same({ { "target", "s" }, { "records", "R" } }, P.SCHEMAS.QUERY_R)
      assert.are.same({ { "rideId", "s" }, { "amount", "n" } }, P.SCHEMAS.TIP_ACK)
      assert.are.same({ { "standId", "s" } }, P.SCHEMAS.CLICK_LEAVE)
    end)
  end)

  describe("encode", function()
    it("writes version, type, msgId then the fields in schema order", function()
      assert.are.equal(
        "1^REQUEST^r1^s1^5000^60^Orgrimmar",
        P.encode("REQUEST", "r1", { standId = "s1", offer = 5000, level = 60, dest = "Orgrimmar" })
      )
    end)

    it("turns missing fields into empty ones, keeping the trailing separators", function()
      assert.are.equal("1^REQUEST^r1^s1^^^", P.encode("REQUEST", "r1", { standId = "s1" }))
      assert.are.equal("1^STAND_END^r1^", P.encode("STAND_END", "r1", {}))
      assert.are.equal("1^STAND_END^r1^", P.encode("STAND_END", "r1"))
    end)

    it("ignores fields the schema does not have", function()
      assert.are.equal("1^QUERY^q^Ana Smith", P.encode("QUERY", "q", { target = "Ana Smith", bogus = "x" }))
    end)

    it("escapes % ^ , ; | and newline", function()
      assert.are.equal("1^QUERY^q^%25%5E%2C%3B%7C%0A", P.encode("QUERY", "q", { target = "%^,;|\n" }))
    end)

    it("escapes the msgId too", function()
      assert.are.equal("1^QUERY^a%5Eb^t", P.encode("QUERY", "a^b", { target = "t" }))
    end)

    it("joins lists with commas, records with semicolons and record fields with commas", function()
      -- 13 empty fields (standId .. clickerPct), then portals, then an empty note.
      assert.are.equal(
        "1^STAND^a" .. string.rep("^", 13) .. "^a,b%2Cc^",
        P.encode("STAND", "a", { portals = { "a", "b,c" } })
      )
      assert.are.equal(
        "1^QUERY_R^q^t^trust,Ana,5,r1,100,,,,;ridelog,Dar,,r2,101,,,,Bo",
        P.encode("QUERY_R", "q", { target = "t", records = {
          { kind = "trust", rater = "Ana", stars = 5, id = "r1", ts = 100 },
          { kind = "ridelog", rater = "Dar", id = "r2", ts = 101, other = "Bo" },
        } })
      )
    end)

    it("never puts a raw separator-breaking character inside a field", function()
      local wire = P.encode("STAND", "a^b", {
        standId = "^", note = "|cffff0000red|r\nline", portals = { "^", "," }, zone = "%%",
      })
      assert.is_nil(wire:find("[|\n]"))
      -- 1 version + type + msgId + the 15 STAND fields
      local count = 0
      for _ in (wire .. "^"):gmatch("(.-)%^") do
        count = count + 1
      end
      assert.are.equal(18, count)
    end)

    it("raises on an unknown type", function()
      assert.has_error(function() P.encode("NOPE", "x", {}) end, "unknown type")
      assert.has_error(function() P.encode(nil, "x", {}) end, "unknown type")
      assert.has_error(function() P.encode("__index", "x", {}) end, "unknown type")
    end)

    it("raises on a field of the wrong type instead of sending garbage", function()
      assert.has_error(function() P.encode("QUERY", "q", { target = 5 }) end)
      assert.has_error(function() P.encode("QUERY", "q", { target = {} }) end)
      assert.has_error(function() P.encode("TIP", "r", { rideId = "r", amount = "5" }) end)
      assert.has_error(function() P.encode("TIP", "r", { rideId = "r", amount = true }) end)
      assert.has_error(function() P.encode("STAND", "a", { portals = "stormwind" }) end)
      assert.has_error(function() P.encode("STAND", "a", { portals = { 1 } }) end)
      assert.has_error(function() P.encode("QUERY_R", "q", { records = { "x" } }) end)
      assert.has_error(function() P.encode("QUERY_R", "q", { records = { { stars = "5" } } }) end)
      assert.has_error(function() P.encode("QUERY_R", "q", { records = { { kind = 1 } } }) end)
    end)

    it("raises when fields is not a table", function()
      assert.has_error(function() P.encode("QUERY", "q", "Ana Smith") end)
      assert.has_error(function() P.encode("QUERY", "q", 5) end)
    end)

    it("raises on a number that cannot cross the wire", function()
      assert.has_error(function() P.encode("TIP", "r", { amount = math.huge }) end)
      assert.has_error(function() P.encode("TIP", "r", { amount = -math.huge }) end)
      assert.has_error(function() P.encode("TIP", "r", { amount = 0 / 0 }) end)
    end)

    it("raises on a missing or unusable msgId", function()
      assert.has_error(function() P.encode("QUERY", nil, { target = "t" }) end)
      assert.has_error(function() P.encode("QUERY", "", { target = "t" }) end)
      assert.has_error(function() P.encode("QUERY", {}, { target = "t" }) end)
    end)

    it("takes a numeric msgId", function()
      assert.are.equal("1^QUERY^1700000000^t", P.encode("QUERY", 1700000000, { target = "t" }))
    end)
  end)

  describe("round trip", function()
    it("round-trips every type", function()
      local m = P.decode(P.encode("STAND", "a1", FULL_STAND))
      assert.are.equal("STAND", m.type); assert.are.equal("a1", m.msgId); assert.are.equal(1455, m.mapID)
      assert.are.equal("hi ^ there, 100%", m.note)
      assert.are.equal(1, m.v)

      for index, sample in ipairs(SAMPLES) do
        local msgType, fields = sample[1], sample[2]
        local label = msgType .. " #" .. index
        local decoded, err = P.decode(P.encode(msgType, "id-" .. index, fields))
        assert.is_nil(err, label)
        assert.is_table(decoded, label)
        assert.are.equal(P.VERSION, decoded.v, label)
        assert.are.equal(msgType, decoded.type, label)
        assert.are.equal("id-" .. index, decoded.msgId, label)
        local expected = expectedFields(fields)
        for _, field in ipairs(P.SCHEMAS[msgType]) do
          assert.are.same(expected[field[1]], decoded[field[1]], label .. "." .. field[1])
        end
      end
    end)

    it("has a sample for every schema type", function()
      local covered = {}
      for _, sample in ipairs(SAMPLES) do
        covered[sample[1]] = true
      end
      for msgType in pairs(P.SCHEMAS) do
        assert.is_true(covered[msgType] == true, "no round-trip sample for " .. msgType)
      end
      for msgType in pairs(covered) do
        assert.is_table(P.SCHEMAS[msgType], msgType)
      end
    end)

    it("knows exactly the 20 message types of the plan", function()
      local names = {}
      for msgType in pairs(P.SCHEMAS) do
        names[#names + 1] = msgType
      end
      table.sort(names)
      assert.are.same({
        "ACCEPT", "ARRIVED", "CLICK_APPLY", "CLICK_LEAVE", "CLICK_NO", "CLICK_OFFER", "CLICK_OK",
        "DEATH", "DECLINE", "PORTAL_UP", "QUERY", "QUERY_R", "RATING", "REQUEST", "RIDE_LOG",
        "RIDE_START", "STAND", "STAND_END", "TIP", "TIP_ACK",
      }, names)
    end)

    it("keeps empty fields nil, including an empty string", function()
      local m = P.decode(P.encode("STAND", "a", { standId = "s", zone = "", note = nil }))
      assert.are.equal("s", m.standId)
      assert.is_nil(m.zone); assert.is_nil(m.note); assert.is_nil(m.mapID); assert.is_nil(m.portals)
    end)

    it("round-trips numbers exactly", function()
      local numbers = { 0, 1, -1, 1455, 5000, 10000, 1700000000, 0.5, 0.25, 0.75, 0.123456, -20, -0.5, 1e15, 1.5e-5, 123456789012 }
      for _, n in ipairs(numbers) do
        local m = P.decode(P.encode("TIP", "t", { rideId = "r", amount = n }))
        assert.are.equal(n, m.amount, tostring(n))
      end
    end)

    it("round-trips map coordinates", function()
      local m = P.decode(P.encode("STAND", "a", { x = 0.5, y = 0.25, wx = 1234.5678, wy = -4321.25 }))
      assert.are.equal(0.5, m.x); assert.are.equal(0.25, m.y)
      assert.are.equal(1234.5678, m.wx); assert.are.equal(-4321.25, m.wy)
      assert.are.equal(0.123456, P.decode(P.encode("STAND", "a", { x = 0.123456 })).x)
    end)

    it("round-trips every escaped character in strings, list items, record fields and the msgId", function()
      local nasty = "a%b^c,d;e|f\ng %41 %5E %%"
      local m = P.decode(P.encode("STAND", nasty, { note = nasty, portals = { nasty, "x" } }))
      assert.are.equal(nasty, m.msgId); assert.are.equal(nasty, m.note)
      assert.are.same({ nasty, "x" }, m.portals)
      local r = P.decode(P.encode("QUERY_R", "q", { target = nasty, records = { { kind = "trust", rater = nasty, other = nasty } } }))
      assert.are.equal(nasty, r.target); assert.are.equal(nasty, r.records[1].rater); assert.are.equal(nasty, r.records[1].other)
    end)

    it("round-trips unusual bytes in a note", function()
      local note = "caf\195\169 \226\130\172 \1\2\127\255 tab\tend"
      assert.are.equal(note, P.decode(P.encode("STAND", "a", { note = note })).note)
    end)

    it("keeps list order and a one-item list", function()
      assert.are.same({ "stormwind" }, P.decode(P.encode("STAND", "a", { portals = { "stormwind" } })).portals)
      assert.are.same({ "c", "a", "b" }, P.decode(P.encode("STAND", "a", { portals = { "c", "a", "b" } })).portals)
    end)
  end)

  describe("record lists", function()
    it("round-trips trust and ride log records", function()
      local m = P.decode(P.encode("QUERY_R", "q", { target = "Dar Kbolt", records = {
        { kind = "trust", rater = "Ana Smith", stars = 5, id = "r1", ts = 100 }, { kind = "ridelog", rater = "Dar Kbolt", id = "r2", ts = 101, other = "Bo Lee" } } }))
      assert.are.equal(2, #m.records); assert.are.equal("Bo Lee", m.records[2].other); assert.are.equal(5, m.records[1].stars)
    end)

    it("keeps every record field and drops the empty ones", function()
      local m = P.decode(P.encode("QUERY_R", "q", { target = "t", records = { FULL_RECORD, { kind = "trust", rater = "Ana Smith", stars = 5 } } }))
      assert.are.same(FULL_RECORD, m.records[1])
      assert.are.same({ kind = "trust", rater = "Ana Smith", stars = 5 }, m.records[2])
    end)

    it("decodes an empty record list to nil", function()
      local m = P.decode(P.encode("QUERY_R", "q", { target = "t", records = {} }))
      assert.are.equal("t", m.target); assert.is_nil(m.records)
    end)

    it("rejects a record with the wrong number of fields", function()
      local few, err = P.decode("1^QUERY_R^q^t^trust,Ana,5,r1,100")
      assert.is_nil(few); assert.are.equal("malformed", err)
      local many, err2 = P.decode("1^QUERY_R^q^t^trust,Ana,5,r1,100,,,,,extra")
      assert.is_nil(many); assert.are.equal("malformed", err2)
    end)

    it("rejects a record with a bad number", function()
      local m, err = P.decode("1^QUERY_R^q^t^trust,Ana,five,r1,100,,,,")
      assert.is_nil(m); assert.are.equal("malformed", err)
      m, err = P.decode("1^QUERY_R^q^t^trust,Ana,5,r1,100,,,inf,")
      assert.is_nil(m); assert.are.equal("malformed", err)
    end)

    it("one bad record spoils the whole reply", function()
      local m, err = P.decode("1^QUERY_R^q^t^trust,Ana,5,r1,100,,,,;trust,Ana,x,r1,100,,,,")
      assert.is_nil(m); assert.are.equal("malformed", err)
    end)

    it("skips empty record slots", function()
      local m = P.decode("1^QUERY_R^q^t^;trust,Ana,5,r1,100,,,,;")
      assert.are.equal(1, #m.records)
      assert.are.equal("Ana", m.records[1].rater)
    end)

    it("drops a record with every field empty", function()
      local m = P.decode("1^QUERY_R^q^t^,,,,,,,,")
      assert.are.equal("t", m.target); assert.is_nil(m.records)
      m = P.decode("1^QUERY_R^q^t^,,,,,,,,;trust,Ana,5,r1,100,,,,;,,,,,,,,")
      assert.are.equal(1, #m.records); assert.are.equal("Ana", m.records[1].rater)
    end)

    it("skips empty list items", function()
      assert.are.same({ "a", "b" }, P.decode("1^STAND^a" .. string.rep("^", 14) .. ",a,,b,^").portals)
      assert.is_nil(P.decode("1^STAND^a" .. string.rep("^", 14) .. ",,^").portals)
    end)
  end)

  describe("decode", function()
    it("rejects bad input without raising", function()             -- Review Focus 5
      for _, s in ipairs({"", "x", "1^", "1^NOPE^id", "1^STAND^id^s1^lock^A^notanumber", "^^^^", string.rep("%", 300)}) do
        local m, err = P.decode(s); assert.is_nil(m); assert.is_truthy(err)
      end
      local m, err, v = P.decode("2^STAND^id"); assert.is_nil(m); assert.are.equal("version", err); assert.are.equal(2, v)
    end)

    it("gives the specific error for each kind of failure", function()
      assert.are.same({ nil, "malformed" }, { P.decode("") })
      assert.are.same({ nil, "malformed" }, { P.decode("x") })
      assert.are.same({ nil, "malformed" }, { P.decode("1") })
      assert.are.same({ nil, "malformed" }, { P.decode("^^^^") })
      assert.are.same({ nil, "malformed" }, { P.decode("1^STAND_END") })
      assert.are.same({ nil, "unknown_type" }, { P.decode("1^") })
      assert.are.same({ nil, "unknown_type" }, { P.decode("1^NOPE^id") })
      assert.are.same({ nil, "unknown_type" }, { P.decode("1^NOPE") })
      assert.are.same({ nil, "unknown_type" }, { P.decode("1^stand_end^id^s") })
      assert.are.same({ nil, "unknown_type" }, { P.decode("1^__index^id^s") })
      assert.are.same({ nil, "version", 2 }, { P.decode("2^STAND^id") })
    end)

    it("reports the remote version whatever follows it", function()
      assert.are.same({ nil, "version", 2 }, { P.decode("2") })
      assert.are.same({ nil, "version", 2 }, { P.decode("2^") })
      assert.are.same({ nil, "version", 0 }, { P.decode("0^STAND_END^id^s") })
      assert.are.same({ nil, "version", 7 }, { P.decode("7^\255\254^\0^%zz") })
      assert.are.same({ nil, "version", 100 }, { P.decode("100^STAND_END^id^s") })
    end)

    it("rejects a version that is not a plain number", function()
      for _, s in ipairs({ "x^STAND_END^id^s", "-1^STAND_END^id^s", "1.5^STAND_END^id^s", "0x1^STAND_END^id^s", " 1^STAND_END^id^s", "1e0^STAND_END^id^s", "^STAND_END^id^s", string.rep("9", 400) .. "^STAND_END^id^s" }) do
        local m, err = P.decode(s)
        assert.is_nil(m, s); assert.are.equal("malformed", err, s)
      end
    end)

    it("accepts the minimal valid message", function()
      local m = P.decode("1^STAND_END^id^s1")
      assert.are.same({ v = 1, type = "STAND_END", msgId = "id", standId = "s1" }, m)
    end)

    it("rejects non-string input", function()
      for _, value in ipairs({ 1, true, {}, print }) do
        local m, err = P.decode(value)
        assert.is_nil(m); assert.are.equal("malformed", err)
      end
      local m, err = P.decode(nil)
      assert.is_nil(m); assert.are.equal("malformed", err)
      assert.is_nil((P.decode()))
    end)

    it("rejects a missing or empty msgId", function()
      for _, s in ipairs({ "1^STAND_END", "1^STAND_END^", "1^STAND_END^^s1" }) do
        local m, err = P.decode(s)
        assert.is_nil(m, s); assert.are.equal("malformed", err, s)
      end
    end)

    it("rejects the wrong number of fields", function()
      for _, s in ipairs({ "1^STAND_END^id", "1^STAND_END^id^s1^extra", "1^STAND_END^id^s1^", "1^QUERY_R^q^t", "1^TIP^id^r" }) do
        local m, err = P.decode(s)
        assert.is_nil(m, s); assert.are.equal("malformed", err, s)
      end
    end)

    it("rejects a bad escape", function()
      for _, s in ipairs({ "1^QUERY^q^%", "1^QUERY^q^a%", "1^QUERY^q^a%2", "1^QUERY^q^%zz", "1^QUERY^q^%5e", "1^QUERY^q^%41", "1^QUERY^q^%00", "1^QUERY^q^%%25", "1^QUERY^q%^t", "1^QUERY^%^t" }) do
        local m, err = P.decode(s)
        assert.is_nil(m, s); assert.are.equal("malformed", err, s)
      end
    end)

    it("rejects a bad escape in a list item and in a record field", function()
      local m, err = P.decode("1^STAND^a" .. string.rep("^", 14) .. "a,%zz^")
      assert.is_nil(m); assert.are.equal("malformed", err)
      m, err = P.decode("1^QUERY_R^q^t^trust,%zz,5,r1,100,,,,")
      assert.is_nil(m); assert.are.equal("malformed", err)
    end)

    it("rejects numbers that are not plain decimals", function()
      local bad = { "notanumber", "0x10", "0X1p4", "inf", "-inf", "nan", "-nan", "infinity", "1e999", "-1e999", " 5", "5 ", "5\t", "-", ".", "e5", "1e", "%2C", "%3B", "1f", "\217\161\217\162", "1_000", "--1" }
      for _, text in ipairs(bad) do
        local m, err = P.decode("1^TIP^id^r1^" .. text)
        assert.is_nil(m, text); assert.are.equal("malformed", err, text)
      end
    end)

    it("accepts every number tostring can produce", function()
      for _, text in ipairs({ "0", "-0", "5", "-5", "0.5", "-0.25", "1e+15", "1.5e-05", "-1.5e+100", "123456789012345" }) do
        local m = P.decode("1^TIP^id^r1^" .. text)
        assert.is_table(m, text)
        assert.are.equal(tonumber(text), m.amount, text)
      end
    end)

    it("never lets NaN or infinity into a decoded message", function()
      for _, text in ipairs({ "inf", "nan", "1e999", "-1e999", "1e309" }) do
        local m = P.decode("1^TIP^id^r1^" .. text)
        assert.is_nil(m, text)
      end
    end)

    it("rejects a huge run of percent signs and separators quickly", function()
      for _, s in ipairs({ string.rep("%", 5000), string.rep("^", 5000), "1^" .. string.rep("%", 5000), "1^STAND_END^id^" .. string.rep("%", 5000), string.rep("1^", 2000) }) do
        local m, err = P.decode(s)
        assert.is_nil(m); assert.is_truthy(err)
      end
    end)
  end)

  describe("decode fuzz", function()
    local function checkInvariants(m, err, version)
      if m then
        assert.is_nil(err)
        assert.are.equal(P.VERSION, m.v)
        assert.are.equal("string", type(m.msgId))
        assert.is_truthy(#m.msgId > 0)
        local schema = P.SCHEMAS[m.type]
        assert.is_table(schema)
        for _, field in ipairs(schema) do
          local value = m[field[1]]
          local kind = field[2]
          if value ~= nil then
            if kind == "s" then
              assert.are.equal("string", type(value)); assert.is_truthy(#value > 0)
            elseif kind == "n" then
              assert.are.equal("number", type(value))
              assert.is_true(value == value and value ~= math.huge and value ~= -math.huge)
            else
              assert.are.equal("table", type(value)); assert.is_truthy(#value > 0)
              for _, item in ipairs(value) do
                if kind == "L" then
                  assert.are.equal("string", type(item)); assert.is_truthy(#item > 0)
                else
                  assert.are.equal("table", type(item)); assert.is_truthy(next(item) ~= nil)
                  for key, part in pairs(item) do
                    assert.is_true(hasKey(P.RECORD, key), key)
                    assert.is_true(type(part) == "string" or (type(part) == "number" and part == part and part ~= math.huge and part ~= -math.huge))
                  end
                end
              end
            end
          end
        end
      else
        assert.is_truthy(err == "malformed" or err == "unknown_type" or err == "version")
        if err == "version" then
          assert.are.equal("number", type(version)); assert.is_truthy(version ~= P.VERSION)
        else
          assert.is_nil(version)
        end
      end
    end

    it("fuzz", function()
      math.randomseed(1)
      for _ = 1, 2000 do
        local t = {}; for i = 1, math.random(0, 60) do t[i] = string.char(math.random(0, 255)) end
        assert.has_no.errors(function() P.decode(table.concat(t)) end)
      end
    end)

    it("survives random text made of the characters the format cares about", function()
      math.randomseed(2)
      local alphabet = { "1", "2", "^", "^", "%", "5", "E", "2", "C", ",", ";", "|", "\n", "STAND", "QUERY_R", "TIP", "-", ".", "e", "x", "inf", "nan", "0" }
      for _ = 1, 3000 do
        local t = {}
        for i = 1, math.random(0, 40) do t[i] = alphabet[math.random(1, #alphabet)] end
        local text = table.concat(t)
        local ok, m, err, version = pcall(P.decode, text)
        assert.is_true(ok, text)
        checkInvariants(m, err, version)
      end
    end)

    it("survives valid messages that are cut short or have bytes changed", function()
      math.randomseed(3)
      local wires = {}
      for _, sample in ipairs(SAMPLES) do
        wires[#wires + 1] = P.encode(sample[1], "m1", sample[2])
      end
      for _ = 1, 4000 do
        local wire = wires[math.random(1, #wires)]
        local mode = math.random(1, 3)
        if mode == 1 then
          wire = wire:sub(1, math.random(0, #wire))
        elseif mode == 2 and #wire > 0 then
          local at = math.random(1, #wire)
          wire = wire:sub(1, at - 1) .. string.char(math.random(0, 255)) .. wire:sub(at + 1)
        else
          local at = math.random(0, #wire)
          wire = wire:sub(1, at) .. string.char(math.random(0, 255)) .. wire:sub(at + 1)
        end
        local ok, m, err, version = pcall(P.decode, wire)
        assert.is_true(ok, wire)
        checkInvariants(m, err, version)
      end
    end)

  end)
end)
