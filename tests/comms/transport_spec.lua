describe("Transport", function()
  local ns, clock, bus, a, b, got
  before_each(function()
    ns = Taxi.load(); clock = ns.Clock.new(1000); bus = ns.Bus.new{clock=clock}; got = {}
    local function mk(name) local t; local be = bus:attach(name, "Alliance", function(...) t:receive(...) end)
      t = ns.Transport.new{backend=be, clock=clock, prefix="TaxiFvr", onMessage=function(m, s, d) got[#got+1] = {m=m, s=s, d=d, to=name} end, onVersion=function() end}
      return t end
    a, b = mk("Ana Smith"), mk("Bo Lee")
  end)
  local function run(s) for _ = 1, s * 5 do a:pump(); b:pump(); clock:advance(0.2) end end
  it("stamps sender", function() a:send("QUERY", {target="X Y"}, "CHANNEL"); run(1); assert.are.equal("Ana Smith", got[1].s) end)
  it("chunks long messages and reassembles", function()
    a:send("STAND", {standId="s", note=string.rep("n", 700)}, "CHANNEL"); run(2)
    assert.are.equal(700, #got[1].m.note)
    for _, w in ipairs(bus:sent()) do assert.is_true(#w.text <= 255) end
  end)
  it("throttles but delivers everything", function()
    for i = 1, 30 do a:send("QUERY", {target="T"..i}, "CHANNEL") end; run(40); assert.are.equal(30, #got)
  end)
  it("holds during lockdown", function()
    bus:setLockdown("Ana Smith", true); a:send("QUERY", {target="T"}, "CHANNEL"); run(3); assert.are.equal(0, #got)
    bus:setLockdown("Ana Smith", false); run(2); assert.are.equal(1, #got)
  end)
  it("ignores incomplete and duplicate chunks", function()               -- Review Focus 5
    b:receive("TaxiFvr", "abc:1/2:part", "WHISPER", "Ana Smith"); clock:advance(31); a:pump(); b:pump()
    b:receive("TaxiFvr", "abc:2/2:rest", "WHISPER", "Ana Smith"); assert.are.equal(0, #got)
    b:receive("TaxiFvr", "zz:9/2:x", "WHISPER", "Ana Smith"); b:receive("TaxiFvr", "garbage", "WHISPER", "Ana Smith"); assert.are.equal(0, #got)
  end)

  -- Beyond the brief ----------------------------------------------------------

  describe("sending", function()
    it("queues on send and transmits on pump", function()
      a:send("STAND", {standId = "s", note = string.rep("n", 700)}, "CHANNEL")
      assert.are.equal(4, a:queued())
      assert.are.equal(0, #bus:sent())
      a:pump()
      assert.are.equal(0, a:queued())
      assert.are.equal(4, #bus:sent())
    end)

    it("builds msgId from the floored time and a counter", function()
      local c = ns.Clock.new(1000.7)
      local t = ns.Transport.new{backend = {send = function() return 0 end, inLockdown = function() return false end},
        clock = c, prefix = "TaxiFvr", onMessage = function() end}
      assert.are.equal(string.format("%x%04x", 1000, 1), t:send("QUERY", {target = "T"}, "CHANNEL"))
      assert.are.equal(string.format("%x%04x", 1000, 2), t:send("QUERY", {target = "T"}, "CHANNEL"))
      c:advance(100000)
      assert.are.equal(string.format("%x%04x", 101000 % 65536, 3), t:send("QUERY", {target = "T"}, "CHANNEL"))
    end)

    it("writes chunks as msgId:i/n:payload with the configured prefix and payload size", function()
      local id = a:send("STAND", {standId = "s", note = string.rep("n", 700)}, "WHISPER", "Bo Lee")
      a:pump()
      local sent = bus:sent()
      local text = ns.Protocol.encode("STAND", id, {standId = "s", note = string.rep("n", 700)})
      assert.are.equal(math.ceil(#text / ns.Config.CHUNK_PAYLOAD), #sent)
      local parts = {}
      for i, w in ipairs(sent) do
        assert.are.equal("Ana Smith", w.sender)
        assert.are.equal("TaxiFvr", w.prefix)
        assert.are.equal("WHISPER", w.dist)
        assert.are.equal("Bo Lee", w.target)
        local header = id .. ":" .. i .. "/" .. #sent .. ":"
        assert.are.equal(header, w.text:sub(1, #header))
        assert.is_true(#w.text - #header <= ns.Config.CHUNK_PAYLOAD)
        parts[i] = w.text:sub(#header + 1)
      end
      assert.are.equal(text, table.concat(parts))
    end)

    it("sends whispers to the target only, and passes the distribution on", function()
      a:send("QUERY", {target = "T"}, "WHISPER", "Bo Lee")
      run(1)
      assert.are.equal(1, #got)
      assert.are.equal("Bo Lee", got[1].to)
      assert.are.equal("WHISPER", got[1].d)
    end)

    it("delivers in send order through the throttle", function()
      for i = 1, 25 do a:send("QUERY", {target = "T" .. i}, "CHANNEL") end
      run(40)
      assert.are.equal(25, #got)
      for i = 1, 25 do assert.are.equal("T" .. i, got[i].m.target) end
    end)

    -- STAND with a note of `len` bytes; the first id a fresh Transport hands out is 7 bytes long.
    local function stand(len) return {standId = "s", note = string.rep("n", len)} end
    local function noteForChunks(chunks)
      return chunks * ns.Config.CHUNK_PAYLOAD - #ns.Protocol.encode("STAND", "3e80001", stand(0))
    end

    it("refuses a payload that needs more than 16 chunks and queues nothing", function()
      local id = a:send("STAND", stand(noteForChunks(16)), "CHANNEL")
      assert.is_string(id)
      assert.are.equal(16, a:queued())
      local none, why = a:send("STAND", stand(noteForChunks(16) + 1), "CHANNEL")
      assert.is_nil(none)
      assert.are.equal("too_large", why)
      assert.are.equal(16, a:queued())
    end)

    it("fits() says whether a message fits in 16 chunks even with the longest msgId", function()
      local room = 16 * ns.Config.CHUNK_PAYLOAD - #ns.Protocol.encode("STAND", "ffffffff", stand(0))
      assert.is_true(ns.Transport.fits("STAND", stand(room)))
      assert.is_false(ns.Transport.fits("STAND", stand(room + 1)))
      -- At a time whose msgId is the longest, send() agrees with fits().
      local t = ns.Transport.new{backend = {send = function() return 0 end, inLockdown = function() return false end},
        clock = ns.Clock.new(65535), prefix = "TaxiFvr", onMessage = function() end}
      assert.is_string(t:send("STAND", stand(room), "CHANNEL"))
      assert.are.same({nil, "too_large"}, {t:send("STAND", stand(room + 1), "CHANNEL")})
    end)

    it("delivers a message of exactly 16 chunks", function()
      a:send("STAND", stand(noteForChunks(16)), "CHANNEL")
      run(12)
      assert.are.equal(1, #got)
      assert.are.equal(noteForChunks(16), #got[1].m.note)
    end)

    it("reports each message's chunks in queued()", function()
      a:send("QUERY", {target = "T"}, "CHANNEL")
      a:send("STAND", {standId = "s", note = string.rep("n", 700)}, "CHANNEL")
      assert.are.equal(5, a:queued())
    end)

    it("clear() drops every queued chunk, and later sends go out as usual", function()
      a:send("QUERY", {target = "T"}, "CHANNEL")
      a:send("STAND", {standId = "s", note = string.rep("n", 700)}, "CHANNEL")
      a:clear()
      assert.are.equal(0, a:queued())
      run(2)
      assert.are.equal(0, #bus:sent())
      assert.are.equal(0, #got)
      a:send("QUERY", {target = "After"}, "CHANNEL")
      run(1)
      assert.are.equal(1, #got)
      assert.are.equal("After", got[1].m.target)
    end)
  end)

  describe("pumping against a scripted backend", function()
    local function scripted(codes)
      local be = {calls = {}, locked = false}
      be.send = function(prefix, text, dist, target)
        be.calls[#be.calls + 1] = {prefix = prefix, text = text, dist = dist, target = target}
        return table.remove(codes, 1) or 0
      end
      be.inLockdown = function() return be.locked end
      return be
    end
    local function make(codes)
      local be = scripted(codes)
      local t = ns.Transport.new{backend = be, clock = clock, prefix = "TaxiFvr", onMessage = function() end}
      return t, be
    end
    local function ticks(t, n) for _ = 1, n do t:pump(); clock:advance(0.2) end end

    for _, code in ipairs({3, 8}) do
      it("requeues the chunk at the front and waits a second on result " .. code, function()
        local t, be = make({0, code})
        t:send("STAND", {standId = "s", note = string.rep("n", 400)}, "CHANNEL") -- 2 chunks
        t:pump()
        assert.are.equal(2, #be.calls)
        assert.are.equal(1, t:queued())
        ticks(t, 4) -- 0.8 s on, the wait is not over yet
        assert.are.equal(2, #be.calls)
        ticks(t, 2)
        assert.are.equal(3, #be.calls)
        assert.are.equal(0, t:queued())
        assert.are.equal(be.calls[2].text, be.calls[3].text)
        assert.are_not.equal(be.calls[1].text, be.calls[2].text)
      end)
    end

    it("waits a second, not a second and a tick, when float error leaves the clock a hair short", function()
      -- Ten steps of 0.2 from 0 add up to 1.9999999999999998, not 2.
      clock = ns.Clock.new(0)
      local t, be = make({3, 3, 0})
      t:send("QUERY", {target = "T"}, "CHANNEL")
      t:pump()
      for _ = 1, 10 do
        clock:advance(0.2)
        t:pump()
      end
      assert.are.equal(3, #be.calls)
    end)

    it("never sends a later chunk ahead of a throttled one", function()
      local t, be = make({3, 3, 0, 0})
      t:send("STAND", {standId = "s", note = string.rep("n", 400)}, "CHANNEL")
      ticks(t, 20)
      assert.are.equal(4, #be.calls)
      assert.are.equal(be.calls[1].text, be.calls[2].text)
      assert.are.equal(be.calls[1].text, be.calls[3].text)
      assert.are_not.equal(be.calls[3].text, be.calls[4].text)
    end)

    it("does not call the backend while inLockdown() is true", function()
      local t, be = make({})
      be.locked = true
      t:send("QUERY", {target = "T"}, "CHANNEL")
      ticks(t, 10)
      assert.are.equal(0, #be.calls)
      assert.are.equal(1, t:queued())
      be.locked = false
      ticks(t, 1)
      assert.are.equal(1, #be.calls)
      assert.are.equal(0, t:queued())
    end)

    it("holds on result 11 and retries on the next pump without waiting", function()
      local t, be = make({11})
      t:send("QUERY", {target = "T"}, "CHANNEL")
      ticks(t, 1)
      assert.are.equal(1, #be.calls)
      assert.are.equal(1, t:queued())
      ticks(t, 1)
      assert.are.equal(2, #be.calls)
      assert.are.equal(0, t:queued())
    end)

    it("drops a chunk the backend refuses for good and carries on", function()
      local t, be = make({9})
      t:send("QUERY", {target = "A"}, "CHANNEL")
      t:send("QUERY", {target = "B"}, "CHANNEL")
      ticks(t, 1)
      assert.are.equal(2, #be.calls)
      assert.are.equal(0, t:queued())
      assert.is_truthy(be.calls[2].text:find("B", 1, true))
    end)
  end)

  describe("receiving", function()
    local t, versions
    local function wire(id, i, n, payload) return id .. ":" .. i .. "/" .. n .. ":" .. payload end
    local function split(text, pieces)
      local out, size = {}, math.ceil(#text / pieces)
      for i = 1, pieces do out[i] = text:sub((i - 1) * size + 1, i * size) end
      return out
    end
    local function recv(text, sender, dist, prefix) t:receive(prefix or "TaxiFvr", text, dist or "CHANNEL", sender or "Ana Smith") end
    local QUERY = function(id) return ns.Protocol.encode("QUERY", id, {target = "X Y"}) end

    before_each(function()
      versions = {}
      t = ns.Transport.new{backend = {send = function() return 0 end, inLockdown = function() return false end},
        clock = clock, prefix = "TaxiFvr", onMessage = function(m, s, d) got[#got + 1] = {m = m, s = s, d = d} end,
        onVersion = function(s, v) versions[#versions + 1] = {s = s, v = v} end}
    end)

    it("delivers a complete single chunk with the stamped sender and distribution", function()
      recv(wire("m1", 1, 1, QUERY("m1")), "Cy Dane", "WHISPER")
      assert.are.equal(1, #got)
      assert.are.equal("QUERY", got[1].m.type)
      assert.are.equal("X Y", got[1].m.target)
      assert.are.equal("Cy Dane", got[1].s)
      assert.are.equal("WHISPER", got[1].d)
    end)

    it("ignores other prefixes", function()
      recv(wire("m1", 1, 1, QUERY("m1")), "Cy Dane", "CHANNEL", "OtherAddon")
      assert.are.equal(0, #got)
    end)

    it("reassembles chunks that arrive out of order", function()
      local parts = split(QUERY("m1"), 3)
      recv(wire("m1", 3, 3, parts[3]))
      recv(wire("m1", 1, 3, parts[1]))
      assert.are.equal(0, #got)
      recv(wire("m1", 2, 3, parts[2]))
      assert.are.equal(1, #got)
    end)

    it("accepts a repeated chunk without counting it twice", function()
      local parts = split(QUERY("m1"), 3)
      recv(wire("m1", 1, 3, parts[1]))
      recv(wire("m1", 1, 3, parts[1]))
      recv(wire("m1", 2, 3, parts[2]))
      assert.are.equal(0, #got)
      recv(wire("m1", 3, 3, parts[3]))
      assert.are.equal(1, #got)
    end)

    it("keeps same-numbered messages from different senders apart", function()
      local parts = split(QUERY("m1"), 2)
      recv(wire("m1", 1, 2, parts[1]), "Ana Smith")
      recv(wire("m1", 2, 2, parts[2]), "Bo Lee")
      assert.are.equal(0, #got)
      recv(wire("m1", 2, 2, parts[2]), "Ana Smith")
      assert.are.equal(1, #got)
      assert.are.equal("Ana Smith", got[1].s)
    end)

    it("delivers a message once per sender and msgId", function()
      recv(wire("m1", 1, 1, QUERY("m1")), "Ana Smith")
      recv(wire("m1", 1, 1, QUERY("m1")), "Ana Smith", "WHISPER")
      assert.are.equal(1, #got)
      recv(wire("m1", 1, 1, QUERY("m1")), "Bo Lee")
      assert.are.equal(2, #got)
    end)

    it("deduplicates a reassembled message too", function()
      local parts = split(QUERY("m1"), 2)
      for _ = 1, 2 do
        recv(wire("m1", 1, 2, parts[1]))
        recv(wire("m1", 2, 2, parts[2]))
      end
      assert.are.equal(1, #got)
    end)

    it("forgets a msgId after DEDUPE_SECONDS", function()
      recv(wire("m1", 1, 1, QUERY("m1")))
      clock:advance(ns.Config.DEDUPE_SECONDS - 1)
      t:pump()
      recv(wire("m1", 1, 1, QUERY("m1")))
      assert.are.equal(1, #got)
      clock:advance(2)
      t:pump()
      recv(wire("m1", 1, 1, QUERY("m1")))
      assert.are.equal(2, #got)
    end)

    it("completes a message whose chunks arrive within REASSEMBLY_SECONDS", function()
      local parts = split(QUERY("m1"), 2)
      recv(wire("m1", 1, 2, parts[1]))
      clock:advance(ns.Config.REASSEMBLY_SECONDS - 1)
      recv(wire("m1", 2, 2, parts[2]))
      assert.are.equal(1, #got)
    end)

    it("drops a partial message after REASSEMBLY_SECONDS even when nothing pumped", function()
      local parts = split(QUERY("m1"), 2)
      recv(wire("m1", 1, 2, parts[1]))
      clock:advance(ns.Config.REASSEMBLY_SECONDS + 1)
      recv(wire("m1", 2, 2, parts[2]))
      assert.are.equal(0, #got)
      -- the late chunk starts a fresh assembly, which the real first chunk can still finish
      recv(wire("m1", 1, 2, parts[1]))
      assert.are.equal(1, #got)
    end)

    it("times a partial message from its first chunk, not its latest", function()
      local parts = split(QUERY("m1"), 3)
      recv(wire("m1", 1, 3, parts[1]))
      clock:advance(20)
      recv(wire("m1", 2, 3, parts[2]))
      clock:advance(15)
      recv(wire("m1", 3, 3, parts[3]))
      assert.are.equal(0, #got)
    end)

    it("ignores a chunk whose total disagrees with the first chunk's", function()
      local parts = split(QUERY("m1"), 2)
      recv(wire("m1", 1, 2, parts[1]))
      recv(wire("m1", 2, 3, parts[2]))
      assert.are.equal(0, #got)
      recv(wire("m1", 2, 2, parts[2]))
      assert.are.equal(1, #got)
    end)

    describe("chunk headers (R14)", function()
      local function rejected(i, n, pieces)
        -- Would deliver if the header were believed: every piece is sent, numbered 1..pieces.
        local parts = split(QUERY("h"), pieces or 1)
        for k = 1, #parts do recv(wire("h", i or k, n or #parts, parts[k])) end
        return #got == 0
      end
      it("takes 16 chunks and refuses 17", function()
        assert.is_false(rejected(nil, nil, 16))
      end)
      it("refuses n above 16", function()
        assert.is_true(rejected(nil, 17, 17))
      end)
      it("refuses i below 1", function() assert.is_true(rejected(0, 1)) end)
      it("refuses i above n", function() assert.is_true(rejected(2, 1)) end)
      it("refuses n below 1", function() assert.is_true(rejected(1, 0)) end)
      it("refuses non-integer and non-numeric i or n", function()
        for _, bad in ipairs({"1.5", "-1", "1e0", "0x1", "a", "", " 1", "1 "}) do
          assert.is_true(rejected(bad, 1), "i=" .. bad)
          assert.is_true(rejected(1, bad), "n=" .. bad)
        end
      end)
      it("refuses an absurdly long number", function() assert.is_true(rejected("00000000000001", 1)) end)
      it("refuses text that is not a chunk at all", function()
        for _, bad in ipairs({"", "garbage", ":1/1:x", "m:1/1", "m:/1:x", "m:1/:x", "m::x", "m:1:1:x"}) do
          recv(bad)
        end
        assert.are.equal(0, #got)
      end)
      it("does not raise on non-string text or sender", function()
        for _, bad in ipairs({1, true, {}}) do
          assert.has_no.errors(function() t:receive("TaxiFvr", bad, "CHANNEL", "Ana Smith") end)
          assert.has_no.errors(function() t:receive("TaxiFvr", wire("m", 1, 1, QUERY("m")), "CHANNEL", bad) end)
        end
        assert.has_no.errors(function() t:receive("TaxiFvr", nil, nil, nil) end)
        assert.are.equal(0, #got)
      end)
    end)

    describe("decoded messages", function()
      it("drops malformed messages without a callback", function()
        recv(wire("m1", 1, 1, "1^QUERY^m1"))
        recv(wire("m2", 1, 1, "not a message at all"))
        recv(wire("m3", 1, 1, ""))
        assert.are.equal(0, #got)
        assert.are.equal(0, #versions)
      end)

      it("drops unknown types silently", function()
        recv(wire("m1", 1, 1, "1^NOPE^m1^x"))
        assert.are.equal(0, #got)
        assert.are.equal(0, #versions)
      end)

      it("reports a newer protocol version with the sender", function()
        recv(wire("m1", 1, 1, "2^FUTURE^m1^anything"), "Cy Dane")
        assert.are.equal(0, #got)
        assert.are.equal(1, #versions)
        assert.are.equal("Cy Dane", versions[1].s)
        assert.are.equal(ns.Protocol.VERSION + 1, versions[1].v)
      end)

      it("does not report an older version as newer", function()
        recv(wire("m1", 1, 1, "0^QUERY^m1^x"))
        assert.are.equal(0, #versions)
      end)

      it("does not call onVersion for the current version", function()
        recv(wire("m1", 1, 1, QUERY("m1")))
        assert.are.equal(0, #versions)
      end)

      it("copes with a missing onVersion", function()
        local plain = ns.Transport.new{backend = {send = function() return 0 end, inLockdown = function() return false end},
          clock = clock, prefix = "TaxiFvr", onMessage = function() end}
        assert.has_no.errors(function() plain:receive("TaxiFvr", wire("m1", 1, 1, "2^FUTURE^m1^x"), "CHANNEL", "Cy Dane") end)
      end)

      it("stays deduplicated when the handler raises", function()
        local boom = ns.Transport.new{backend = {send = function() return 0 end, inLockdown = function() return false end},
          clock = clock, prefix = "TaxiFvr", onMessage = function() error("handler bug") end}
        assert.has_error(function() boom:receive("TaxiFvr", wire("m1", 1, 1, QUERY("m1")), "CHANNEL", "Ana Smith") end)
        assert.has_no.errors(function() boom:receive("TaxiFvr", wire("m1", 1, 1, QUERY("m1")), "CHANNEL", "Ana Smith") end)
      end)
    end)
  end)
end)
