local _, ns = ...

-- Reputation: the Engine's side of ratings, deaths and liars. It keeps what it
-- hears (RATING, RIDE_START, ARRIVED, RIDE_LOG, DEATH), answers QUERY with what
-- it holds, uses QUERY_R replies to refill its own copy, and watches deaths.
-- The rules about what counts live in Domain/Ratings and Domain/Witness; this
-- file only feeds them, always with the sender the server stamped.
--
-- Deaths matter only on Hardcore, where a death is final: on any other ruleset
-- no death is recorded and nobody is taken for a liar for being alive (R35).
-- Every message except DEATH proves its sender alive (R37), and a dead
-- Hardcore character sends its own DEATH report and then nothing at all.
--
-- Pure Lua: no WoW API (this file is also loaded in-game for /taxi sim).
local Engine, Config, Names, Ratings, Transport = ns.Engine, ns.Config, ns.Names, ns.Ratings, ns.Transport

-- True when the ride id is one Ride.makeId made for this warlock and traveler
-- (warlock@traveler@seconds), and they are two different players.
local function rideOf(rideId, warlock, traveler)
  if type(rideId) ~= "string" then
    return false
  end
  local driver, rider = rideId:match("^([^@]+)@([^@]+)@%d+$")
  return driver ~= nil
    and Names.same(driver, warlock)
    and Names.same(rider, traveler)
    and not Names.same(warlock, traveler)
end

local function hardcore(e)
  return e.game:isHardcore() == true
end

-- The query bookkeeping, made on first use:
--   asked[target]    = { at, replies, from = {[replier] = true} }  my open query
--   answered[key]    = time I last replied to that asker about that target
local function book(e)
  local b = e.queryBook
  if b == nil then
    b = { asked = {}, answered = {} }
    e.queryBook = b
  end
  return b
end

-- Alive evidence (R37) ------------------------------------------------------------

local function alive(e, _, sender)
  if hardcore(e) and e.witness:aliveEvidence(sender, e.clock:now()) > 0 then
    e.dirty = true
  end
end

-- Registered before this file's other handlers and the services', so it runs
-- ahead of them for every type.
for msgType in pairs(ns.Protocol.SCHEMAS) do
  if msgType ~= "DEATH" then
    Engine.handlers[msgType] = alive
  end
end

-- Ratings and rides --------------------------------------------------------------------

-- A rating from its rater: RATING has no rater field, the sender is the rater.
Engine.handlers.RATING = function(e, msg, sender)
  local rec = {
    kind = msg.kind, rater = sender, target = msg.target, stars = msg.stars, id = msg.id, ts = msg.ts,
    owed = msg.owed, received = msg.received, pct = msg.pct,
  }
  if Ratings.addDirect(e.db, rec, sender, e.clock:now()) then
    e.dirty = true
  end
end

-- The traveler's own announcement that a ride began.
Engine.handlers.RIDE_START = function(e, msg, sender)
  e.witness:rideStarted(msg.rideId, sender, msg.warlock, e.clock:now(), sender)
end

-- The traveler's own announcement of arrival: it opens the death window, and a
-- ride id made for this warlock and this sender is filed as a receipt (R3, R28).
Engine.handlers.ARRIVED = function(e, msg, sender)
  local now = e.clock:now()
  e.witness:arrived(msg.rideId, sender, now, sender)
  if rideOf(msg.rideId, msg.warlock, sender) and Ratings.addReceipt(e.db, msg.warlock, msg.rideId, now, now) then
    e.dirty = true
  end
end

-- Files a ride log the warlock itself vouched for. The log backs the traveler's
-- report of a death on that ride: a report that came first as an unproven one
-- becomes heavy now (R48). Returns whether the log was stored.
local function fileRideLog(e, warlock, rideId, ts, traveler, now)
  if not Ratings.addRideLog(e.db, warlock, rideId, ts, traveler, now) then
    return false
  end
  e.dirty = true
  e.witness:corroborate(warlock, rideId, now)
  return true
end

-- The warlock's own log of a ride it gave.
Engine.handlers.RIDE_LOG = function(e, msg, sender)
  local now = e.clock:now()
  if rideOf(msg.rideId, sender, msg.traveler) then
    fileRideLog(e, sender, msg.rideId, now, msg.traveler, now)
  end
end

-- Summary of a warlock's rating of one kind ("trust" or "share").
function Engine:summary(target, kind)
  return Ratings.summary(self.db, target, kind)
end

-- Deaths -------------------------------------------------------------------------------

Engine.handlers.DEATH = function(e, msg, sender)
  if hardcore(e) and e.witness:deathReported(msg, sender, e.clock:now()) then
    e.dirty = true
  end
end

-- The server's death notice for someone else (my own death is PLAYER_DIED).
Engine.gameHandlers.HC_DEATH = function(e, name)
  if not hardcore(e) or Names.same(name, e.me) then
    return
  end
  if e.witness:observedDeath(name, e.clock:now()) then
    e.dirty = true
  end
end

-- My own death. On Hardcore it is final: anything still queued is dropped, the
-- death goes out as DEATH{source="self"} when it followed one of my rides, and
-- Engine:send refuses everything else from now on (R37).
Engine.gameHandlers.PLAYER_DIED = function(e)
  if not hardcore(e) then
    return
  end
  local now = e.clock:now()
  local death = e.witness:observedDeath(e.me, now)
  e.transport:clear()
  if death then
    e.dirty = true
    local ride = e.witness.rides[death.id]
    local arrived = ride and ride.arrivedTs or now
    e:send("DEATH", {
      rideId = death.id, victim = e.me, warlock = death.target, secs = math.floor(now - arrived), source = "self",
    }, "CHANNEL")
  end
end

-- Queries --------------------------------------------------------------------------------

-- Asks the channel about a warlock, at most once per QUERY_COOLDOWN for that
-- warlock. Returns whether the query was sent. Replies are used for
-- QUERY_COOLDOWN after it.
function Engine:query(target)
  local name = Names.normalize(target)
  if name == nil or name == "" then
    return false
  end
  local now = self.clock:now()
  local asked = book(self).asked
  local last = asked[name]
  if last ~= nil and now - last.at < Config.QUERY_COOLDOWN then
    return false
  end
  if not self:send("QUERY", { target = name }, "CHANNEL") then
    return false
  end
  asked[name] = { at = now, replies = 0, from = {} }
  return true
end

-- Whispers what I hold about target to `to`: the newest records that fit in one
-- message (a record too big to fit is left out; the rest still go).
local function reply(e, target, records, to)
  local chosen = {}
  for _, rec in ipairs(records) do
    chosen[#chosen + 1] = rec
    if not Transport.fits("QUERY_R", { target = target, records = chosen }) then
      chosen[#chosen] = nil
    end
  end
  if #chosen > 0 then
    e:send("QUERY_R", { target = target, records = chosen }, "WHISPER", to)
  end
end

-- Someone asks about a warlock: reply by whisper after a random 0..QUERY_JITTER
-- seconds, with at most QUERY_MAX_RECORDS records, if there is anything to
-- tell. An asker gets one reply per warlock per QUERY_COOLDOWN, which is as
-- often as an honest client asks.
Engine.handlers.QUERY = function(e, msg, sender)
  local now = e.clock:now()
  local target, asker = Names.normalize(msg.target), Names.normalize(sender)
  if target == nil or target == "" then
    return
  end
  local answered = book(e).answered
  local key = asker .. "\n" .. target -- a tidied name never holds a newline
  local last = answered[key]
  if last ~= nil and now - last < Config.QUERY_COOLDOWN then
    return
  end
  local records = Ratings.replyRecords(e.db, target, e.me, Config.QUERY_MAX_RECORDS)
  if #records == 0 then
    return
  end
  answered[key] = now
  e.clock:after(e.rng() * Config.QUERY_JITTER, function()
    e:safely("QUERY reply", reply, e, target, records, sender)
  end)
end

-- One record of a reply about target from sender. Returns whether it was stored.
local function useRecord(e, target, r, sender, now)
  if type(r) ~= "table" then
    return false
  end
  if r.kind == "trust" or r.kind == "share" then
    local rec = {
      kind = r.kind, rater = r.rater, target = target, stars = r.stars, id = r.id, ts = r.ts,
      owed = r.owed, received = r.received, pct = r.pct,
    }
    if Names.same(r.rater, sender) then
      return Ratings.addDirect(e.db, rec, sender, now) == true
    end
    return Ratings.addRelayed(e.db, rec, sender, now) == true
  elseif r.kind == "ridelog" then
    -- Only the warlock's own logs, in its own reply about itself.
    if Names.same(r.rater, sender) and Names.same(sender, target) and rideOf(r.id, sender, r.other) then
      return fileRideLog(e, sender, r.id, r.ts, r.other, now)
    end
  elseif r.kind == "death" then
    -- Always second hand, and through the witness so that the relayer can be
    -- struck if the victim turns up alive (R38).
    if hardcore(e) and Names.same(r.rater, r.other) then
      return e.witness:relayedDeath({ target = target, victim = r.other, id = r.id, ts = r.ts }, sender, now) ~= nil
    end
  end
  return false
end

-- A reply to my query: used only while that query is open, at most
-- QUERY_MAX_REPLIES replies per query and one per replier, and at most
-- QUERY_MAX_RECORDS records of each (R14).
Engine.handlers.QUERY_R = function(e, msg, sender)
  local now = e.clock:now()
  local target, from = Names.normalize(msg.target), Names.normalize(sender)
  local asked = target and book(e).asked[target]
  if asked == nil or now - asked.at >= Config.QUERY_COOLDOWN then
    return
  end
  if asked.from[from] or asked.replies >= Config.QUERY_MAX_REPLIES then
    return
  end
  asked.from[from] = true
  asked.replies = asked.replies + 1
  for i = 1, math.min(#msg.records, Config.QUERY_MAX_RECORDS) do
    if useRecord(e, target, msg.records[i], sender, now) then
      e.dirty = true
    end
  end
end

-- Closed queries and old reply marks are forgotten on the Engine's sweep.
local coreTick = Engine.tick
function Engine:tick(now)
  now = now or self.clock:now()
  coreTick(self, now)
  local b = book(self)
  for target, q in pairs(b.asked) do
    if now - q.at >= Config.QUERY_COOLDOWN then
      b.asked[target] = nil
    end
  end
  for key, at in pairs(b.answered) do
    if now - at >= Config.QUERY_COOLDOWN then
      b.answered[key] = nil
    end
  end
end
