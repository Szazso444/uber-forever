local _, ns = ...

-- Moves Protocol messages over addon messages: the WoW API allows 255 bytes per
-- message, throttles senders, and goes dark in instances. A Transport sits on a
-- backend with the contract Game/WoW.lua (the game) and Sim/Bus.lua (the
-- simulation) both implement:
--   backend.send(prefix, text, dist, target) -> result code
--   backend.inLockdown() -> bool
--
-- A message is cut into chunks, each written on the wire as
--   msgId:i/n:payload
-- (payload at most Config.CHUNK_PAYLOAD bytes) and queued. The owner calls
-- pump() every 0.2 s to send what the backend will take. Received chunks are put
-- back together, each (sender, msgId) is delivered once, and the whole text goes
-- through Protocol.decode.
--
-- Chunks come from untrusted players: receive never raises on bad input, and
-- the sender it reports is the one the game gave, never anything from the text.
-- No WoW API here, and no math.random.
local M = {}

local Protocol, Config = ns.Protocol, ns.Config

-- Enum.SendAddonMessageResult values that change what pump does. Any other
-- non-success result is a chunk the backend refuses for good, and is dropped.
local ADDON_THROTTLE, CHANNEL_THROTTLE, LOCKDOWN = 3, 8, 11

local MAX_CHUNKS = 16 -- a message of more chunks is neither sent nor accepted
local MAX_NUMBER_DIGITS = 3 -- digits of i and n in a header; keeps tonumber exact
local THROTTLE_WAIT = 1 -- seconds the queue waits after a throttled send
local SWEEP_INTERVAL = 1 -- seconds between clean-ups of stale reassembly and dedupe entries
-- Time comes from repeated float additions (0.2 five times is not exactly 1),
-- so a wait that is over by this little counts as over.
local EPSILON = 1e-6

local Transport = {}
Transport.__index = Transport

-- opts: backend, clock (colon methods now/after), prefix,
-- onMessage(msg, sender, dist), onVersion(sender, version) (optional).
function M.new(opts)
  return setmetatable({
    backend = opts.backend,
    clock = opts.clock,
    prefix = opts.prefix,
    onMessage = opts.onMessage,
    onVersion = opts.onVersion,
    counter = 0,
    queue = {}, -- chunks waiting to go out: queue[first] .. queue[last]
    first = 1,
    last = 0,
    waitUntil = 0, -- no sending before this time (after a throttled send)
    partial = {}, -- "sender:msgId" -> { total, count, parts, startedAt }
    seen = {}, -- "sender:msgId" -> time until which repeats are ignored
    nextSweep = 0,
  }, Transport)
end

-- Sending ---------------------------------------------------------------------

-- Queues a message. Returns its msgId, or nil and "too_large" when it would need
-- more than MAX_CHUNKS chunks. Nothing goes out until pump().
function Transport:send(msgType, fields, dist, target)
  local counter = self.counter + 1
  local msgId = string.format("%x%04x", math.floor(self.clock:now()) % 65536, counter % 65536)
  local text = Protocol.encode(msgType, msgId, fields)

  local size = Config.CHUNK_PAYLOAD
  local total = math.ceil(#text / size)
  if total > MAX_CHUNKS then
    return nil, "too_large"
  end
  self.counter = counter
  for i = 1, total do
    local payload = text:sub((i - 1) * size + 1, i * size)
    self.last = self.last + 1
    self.queue[self.last] = {
      text = string.format("%s:%d/%d:%s", msgId, i, total, payload),
      dist = dist,
      target = target,
    }
  end
  return msgId
end

-- The longest msgId send() writes: four hex digits of time, four of counter.
local LONGEST_MSGID = "ffffffff"

-- Whether send() would take the message: true when it needs at most
-- MAX_CHUNKS chunks even with the longest msgId. For a caller that has to
-- choose what goes into a message (a reply with many records, say).
function M.fits(msgType, fields)
  local text = Protocol.encode(msgType, LONGEST_MSGID, fields)
  return math.ceil(#text / Config.CHUNK_PAYLOAD) <= MAX_CHUNKS
end

-- Chunks waiting to be sent.
function Transport:queued()
  return self.last - self.first + 1
end

-- Drops every chunk waiting to be sent, so nothing queued so far goes out.
-- Messages sent afterwards are queued and sent as usual.
function Transport:clear()
  self.queue = {}
  self.first, self.last = 1, 0
end

function Transport:sweep(now)
  if now < self.nextSweep then
    return
  end
  self.nextSweep = now + SWEEP_INTERVAL
  for key, assembly in pairs(self.partial) do
    if now - assembly.startedAt > Config.REASSEMBLY_SECONDS then
      self.partial[key] = nil
    end
  end
  for key, expires in pairs(self.seen) do
    if now >= expires then
      self.seen[key] = nil
    end
  end
end

-- Sends queued chunks, in order, until the queue is empty or the backend says
-- stop. Call it every 0.2 s.
--   throttled (3 or 8): the chunk stays at the front and the queue waits a second;
--   lockdown (11, or inLockdown()): the queue holds, and the next pump tries again.
function Transport:pump()
  local now = self.clock:now()
  self:sweep(now)
  if now < self.waitUntil - EPSILON or self.backend.inLockdown() then
    return
  end
  while self.first <= self.last do
    local chunk = self.queue[self.first]
    local code = self.backend.send(self.prefix, chunk.text, chunk.dist, chunk.target)
    if code == ADDON_THROTTLE or code == CHANNEL_THROTTLE then
      self.waitUntil = now + THROTTLE_WAIT
      return
    elseif code == LOCKDOWN then
      return
    end
    self.queue[self.first] = nil
    self.first = self.first + 1
  end
  self.first, self.last = 1, 0
end

-- Receiving -------------------------------------------------------------------

-- "msgId:i/n:payload" -> msgId, i, n, payload; nil unless i and n are plain
-- integers with 1 <= i <= n <= MAX_CHUNKS.
local function parseChunk(text)
  local msgId, i, n, payload = text:match("^([^:]+):(%d+)/(%d+):(.*)$")
  if not msgId or #i > MAX_NUMBER_DIGITS or #n > MAX_NUMBER_DIGITS then
    return nil
  end
  i, n = tonumber(i), tonumber(n)
  if i < 1 or i > n or n > MAX_CHUNKS then
    return nil
  end
  return msgId, i, n, payload
end

-- Files a chunk of a multi-chunk message. Returns the whole text once every
-- chunk is in, nil until then. A partial message lives REASSEMBLY_SECONDS from
-- its first chunk.
function Transport:addChunk(key, index, total, payload, now)
  local assembly = self.partial[key]
  if assembly and now - assembly.startedAt > Config.REASSEMBLY_SECONDS then
    assembly = nil
  end
  if not assembly then
    assembly = { total = total, count = 0, parts = {}, startedAt = now }
    self.partial[key] = assembly
  elseif assembly.total ~= total then
    return nil
  end
  if assembly.parts[index] == nil then
    assembly.parts[index] = payload
    assembly.count = assembly.count + 1
  end
  if assembly.count < total then
    return nil
  end
  self.partial[key] = nil
  return table.concat(assembly.parts, "", 1, total)
end

function Transport:dispatch(text, sender, dist)
  local msg, err, version = Protocol.decode(text)
  if msg then
    self.onMessage(msg, sender, dist)
  elseif err == "version" and version > Protocol.VERSION and self.onVersion then
    self.onVersion(sender, version)
  end
end

-- Takes one addon message from the game. `sender` is what the game says; it is
-- passed on as is. Anything that is not a well-formed chunk is dropped without a
-- sound, and so are repeats of a message already delivered.
function Transport:receive(prefix, text, dist, sender)
  if prefix ~= self.prefix or type(text) ~= "string" or type(sender) ~= "string" then
    return
  end
  local msgId, index, total, payload = parseChunk(text)
  if not msgId then
    return
  end

  local now = self.clock:now()
  local key = sender .. ":" .. msgId
  local ignoreUntil = self.seen[key]
  if ignoreUntil and now < ignoreUntil then
    return
  end

  local whole = payload
  if total > 1 then
    whole = self:addChunk(key, index, total, payload, now)
    if not whole then
      return
    end
  end
  -- Marked before the handlers run, so a handler that fails is not run again
  -- when the message comes round once more.
  self.seen[key] = now + Config.DEDUPE_SECONDS
  self:dispatch(whole, sender, dist)
end

ns.Transport = M
