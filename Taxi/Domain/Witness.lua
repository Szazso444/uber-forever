local _, ns = ...

-- Witness: ties a traveler's death to the summon that brought them, and takes
-- it back when the traveler turns out to be alive.
--
-- On Hardcore a death soon after a summon is the heaviest thing that can count
-- against a warlock, so only corroborated evidence is heavy (R48):
--   * a death this client saw itself (server death data, or its own death),
--     on a ride whose arrival it heard from the traveler;
--   * the traveler's own report, on a ride whose start it heard from them, when
--     this client also has the warlock's ride log naming that traveler (or saw
--     the death itself). A silent throwaway identity can announce a ride and
--     report a death, but cannot make the warlock log a ride it never gave.
-- A report from the traveler that nothing else backs is a light death with
-- source "self": direct (no relayer), worth no more than a one-sided rating,
-- and counted in deathsReported so travelers still see the warning. It becomes
-- heavy when the warlock's ride log (corroborate) or this client's own sighting
-- turns up. A report from anyone else is a relayed (light) one: it is worth
-- little, and its relayer is struck if the "dead" traveler is seen alive.
-- A traveler who reports their own death and is then seen alive is a liar.
--
-- A Hardcore character dies once, so a traveler has at most one heavy death on
-- file and at most one unproven self report; further first-hand claims from the
-- same name are refused, which stops one silent identity from minting a death
-- per invented ride.
--
-- Rides are only ever learned from the traveler (the sender must be the
-- traveler), so nobody can start a ride for someone else, and a traveler has at
-- most MAX_OPEN_RIDES open at a time. The witness keeps rides in memory for
-- RIDE_MEMORY seconds. The deaths themselves are stored through Ratings, which
-- keeps where each came from (self, observed or relayed), so a reload loses
-- nothing the witness needs. Small indexes (rides by traveler, deaths by
-- victim) mean no call has to walk every ride or every stored death.
local Names, Ratings, Config = ns.Names, ns.Ratings, ns.Config

local M = {}

local Witness = {}
Witness.__index = Witness

-- Open rides one traveler can have at once; further ride starts are ignored
-- until one expires.
local MAX_OPEN_RIDES = 3

-- A report sent inside the death window can arrive a little later than the
-- window by the time it has been queued, split and put together again.
local TRANSPORT_SLACK = 30

-- True only for a real, finite number (not nil, not NaN, not +-infinity).
local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function nonEmptyString(x)
  return type(x) == "string" and x ~= ""
end

-- A player name tidied the way every key in the db is, or nil when x is not a
-- usable name.
local function nameOf(x)
  local n = Names.normalize(x)
  if n == nil or n == "" then
    return nil
  end
  return n
end

-- A ride id made by Ride.makeId reads driver@traveler@seconds. An id in that
-- form can only belong to the warlock and traveler it names, so a report that
-- pairs it with anyone else is refused (otherwise a relayed copy naming
-- another victim could be merged into the real death and hide it). An id in
-- any other form is no ride's, and is refused too (M7): it fails closed.
local function pairMatches(rideId, warlock, victim)
  if Names.same(warlock, victim) then
    return false
  end
  local driver, traveler = rideId:match("^([^@]+)@([^@]+)@%d+$")
  if driver == nil then
    return false
  end
  return Names.same(driver, warlock) and Names.same(traveler, victim)
end

-- Indexes -------------------------------------------------------------------------
--   ridesOf[victim]  = { [rideId] = ride }            the open rides of a traveler
--   deathsOf[victim] = { [key] = {target, id} }       every death on file naming a victim
--   heavyOf[victim]  = {target, id, ts}               the victim's one heavy death
--   claimOf[victim]  = {target, id, ts}               the victim's one unproven self report
-- They are only a way to find things quickly: what they point at is checked
-- against the db and the rides before it is used.

local function deathKey(target, id)
  return target .. "\0" .. id
end

-- What a death on file is for the one-per-victim rules: "heavy", "claim" (the
-- victim's own report that nothing backs: light, source "self", no relayer) or
-- nil (a relayed death, which is not limited).
local function kindOf(death)
  if death.heavy == true then
    return "heavy"
  end
  if death.source == "self" and death.via == nil then
    return "claim"
  end
  return nil
end

-- Note a death on file. A heavy one also becomes the victim's heavy death, when
-- they have none, and an unproven self report their claim; with several the
-- earliest is the one.
local function track(w, victim, target, id, kind, ts)
  local byKey = w.deathsOf[victim]
  if byKey == nil then
    byKey = {}
    w.deathsOf[victim] = byKey
  end
  byKey[deathKey(target, id)] = { target = target, id = id }
  local index = (kind == "heavy" and w.heavyOf) or (kind == "claim" and w.claimOf) or nil
  if index ~= nil then
    local h = index[victim]
    local when = finite(ts) and ts or math.huge
    if h == nil or when < h.ts or (when == h.ts and deathKey(target, id) < deathKey(h.target, h.id)) then
      index[victim] = { target = target, id = id, ts = when }
    end
  end
  if kind == "heavy" then
    -- A claim made heavy by proof is no claim any more.
    local c = w.claimOf[victim]
    if c ~= nil and c.target == target and c.id == id then
      w.claimOf[victim] = nil
    end
  end
end

-- Forget a death that is no longer on file.
local function untrack(w, victim, target, id)
  local byKey = w.deathsOf[victim]
  if byKey ~= nil then
    byKey[deathKey(target, id)] = nil
    if next(byKey) == nil then
      w.deathsOf[victim] = nil
    end
  end
  for _, index in ipairs({ w.heavyOf, w.claimOf }) do
    local h = index[victim]
    if h ~= nil and h.target == target and h.id == id then
      index[victim] = nil
    end
  end
end

-- Index every death already in the db.
local function indexDb(w)
  for target, byId in pairs(w.db.deaths) do
    if type(target) == "string" and type(byId) == "table" then
      for id, death in pairs(byId) do
        if type(id) == "string" and type(death) == "table" then
          local victim = nameOf(death.victim)
          if victim ~= nil then
            track(w, victim, target, id, kindOf(death), death.ts)
          end
        end
      end
    end
  end
end

-- The death on file for a warlock and ride id, or nil.
local function storedDeath(w, target, id)
  local byId = w.db.deaths[target]
  local death = type(byId) == "table" and byId[id] or nil
  if type(death) == "table" then
    return death
  end
  return nil
end

-- The victim's heavy death on file, as {target, id}, or nil. An entry that is
-- no longer a heavy death of theirs in the db is forgotten.
local function heavyDeathOf(w, victim)
  local h = w.heavyOf[victim]
  if h ~= nil then
    local death = storedDeath(w, h.target, h.id)
    if death == nil or death.heavy ~= true or not Names.same(death.victim, victim) then
      w.heavyOf[victim] = nil
      return nil
    end
  end
  return h
end

-- True when a heavy death of victim on this warlock's ride may be added: the
-- victim has no heavy death on file, or it is this very ride's death.
local function heavyAllowed(w, victim, warlock, rideId)
  local h = heavyDeathOf(w, victim)
  return h == nil or (Names.same(h.target, warlock) and h.id == rideId)
end

-- The victim's unproven self report on file, as {target, id}, or nil. An entry
-- that is no longer such a report of theirs in the db is forgotten.
local function claimDeathOf(w, victim)
  local c = w.claimOf[victim]
  if c ~= nil then
    local death = storedDeath(w, c.target, c.id)
    if death == nil or kindOf(death) ~= "claim" or not Names.same(death.victim, victim) then
      w.claimOf[victim] = nil
      return nil
    end
  end
  return c
end

-- True when an unproven self report of victim on this warlock's ride may be
-- added: no heavy death on another ride, and no other unproven report.
local function claimAllowed(w, victim, warlock, rideId)
  if not heavyAllowed(w, victim, warlock, rideId) then
    return false
  end
  local c = claimDeathOf(w, victim)
  return c == nil or (Names.same(c.target, warlock) and c.id == rideId)
end

-- True when the warlock's own ride log for rideId names victim as the traveler.
local function logNames(w, warlock, rideId, victim)
  local logs = type(w.db.rideLogs) == "table" and w.db.rideLogs[warlock] or nil
  local log = type(logs) == "table" and logs[rideId] or nil
  return type(log) == "table" and Names.same(log.traveler, victim)
end

-- True when a victim's report of a death on this ride has something behind it:
-- the warlock's ride log names the victim, or this client holds the death as a
-- heavy one already (it saw it happen).
local function backed(w, warlock, rideId, victim)
  if logNames(w, warlock, rideId, victim) then
    return true
  end
  local death = storedDeath(w, warlock, rideId)
  return death ~= nil and death.heavy == true and Names.same(death.victim, victim)
end

-- Store a death through Ratings and keep the indexes in step. Returns whether
-- it was stored.
local function store(w, death, now)
  if not Ratings.addDeath(w.db, death, now) then
    return false
  end
  -- What is on file now: a heavy death is not lowered by a light report of it.
  local stored = storedDeath(w, death.target, death.id) or death
  track(w, death.victim, death.target, death.id, kindOf(stored), stored.ts)
  return true
end

-- A known ride must be the one a report describes, and a death at time `at`
-- must fall within the death window of its arrival (with transport slack) when
-- the arrival is known. A ride that is not known fits anything.
local function rideFits(ride, victim, warlock, at)
  if ride == nil then
    return true
  end
  if not (Names.same(ride.victim, victim) and Names.same(ride.warlock, warlock)) then
    return false
  end
  if ride.arrivedTs ~= nil then
    local after = at - ride.arrivedTs
    return after >= 0 and after <= Config.DEATH_WINDOW + TRANSPORT_SLACK
  end
  return true
end

-- db: the TaxiDB table, where deaths, liars and strikes are kept.
function M.new(db)
  local w = setmetatable({ db = db, rides = {}, ridesOf = {}, deathsOf = {}, heavyOf = {}, claimOf = {} }, Witness)
  indexDb(w)
  return w
end

-- Rides --------------------------------------------------------------------------

-- The traveler announced a ride (RIDE_START). Only the traveler's own message
-- counts, so sender must be the victim. Returns whether the ride is now known.
-- Hearing a known ride's start again changes nothing. A traveler with
-- MAX_OPEN_RIDES rides open gets no more until one expires.
function Witness:rideStarted(rideId, victim, warlock, ts, sender)
  local who, driver = nameOf(victim), nameOf(warlock)
  if not nonEmptyString(rideId) or who == nil or driver == nil or not finite(ts) then
    return false
  end
  if not Names.same(sender, who) or not pairMatches(rideId, driver, who) then
    return false
  end
  local ride = self.rides[rideId]
  if ride ~= nil then
    return Names.same(ride.victim, who) and Names.same(ride.warlock, driver)
  end
  local open = self.ridesOf[who]
  if open == nil then
    open = {}
  end
  local count = 0
  for _ in pairs(open) do
    count = count + 1
  end
  if count >= MAX_OPEN_RIDES then
    return false
  end
  ride = { victim = who, warlock = driver, startTs = ts }
  self.rides[rideId] = ride
  open[rideId] = ride
  self.ridesOf[who] = open
  return true
end

-- The traveler announced their arrival (ARRIVED); the death window runs from
-- here. Only the traveler's own message counts, and only for a ride whose start
-- was heard. The first arrival stands: a later one cannot stretch the window.
function Witness:arrived(rideId, victim, ts, sender)
  if not finite(ts) or not Names.same(sender, victim) then
    return false
  end
  local ride = nonEmptyString(rideId) and self.rides[rideId] or nil
  if ride == nil or not Names.same(ride.victim, victim) then
    return false
  end
  if ride.arrivedTs == nil then
    ride.arrivedTs = ts
  end
  return true
end

-- Forget rides that began more than RIDE_MEMORY seconds before now. Stored
-- deaths are not touched. Returns how many rides were dropped.
function Witness:expire(now)
  if not finite(now) then
    return 0
  end
  local dropped = 0
  for id, ride in pairs(self.rides) do
    if now - ride.startTs > Config.RIDE_MEMORY then
      self.rides[id] = nil
      local open = self.ridesOf[ride.victim]
      if open ~= nil then
        open[id] = nil
        if next(open) == nil then
          self.ridesOf[ride.victim] = nil
        end
      end
      dropped = dropped + 1
    end
  end
  return dropped
end

-- Deaths -------------------------------------------------------------------------

-- A death this client saw for itself (HARDCORE_DEATHS, UnitIsDeadOrGhost, or its
-- own PLAYER_DEAD) at time ts. It counts when victim is on a ride that arrived
-- at most DEATH_WINDOW seconds earlier (and not later than the death); with
-- rides overlapping it is the latest arrival's. Returns the heavy death that was
-- recorded, {target, victim, id, ts, heavy, source = "observed"}, or nil when
-- there is none, when the victim already has a heavy death on another ride (a
-- character dies once), when this ride's death was already seen, or when it
-- could not be stored.
function Witness:observedDeath(victim, ts)
  local who = nameOf(victim)
  if who == nil or not finite(ts) then
    return nil
  end
  local bestId, best
  for id, ride in pairs(self.ridesOf[who] or {}) do
    if ride.arrivedTs ~= nil then
      local after = ts - ride.arrivedTs
      if after >= 0 and after <= Config.DEATH_WINDOW then
        if best == nil or ride.arrivedTs > best.arrivedTs or (ride.arrivedTs == best.arrivedTs and id < bestId) then
          bestId, best = id, ride
        end
      end
    end
  end
  if best == nil or not heavyAllowed(self, who, best.warlock, bestId) then
    return nil
  end
  local known = storedDeath(self, best.warlock, bestId)
  if known ~= nil and known.heavy == true and known.source == "observed" then
    return nil
  end
  local death = { target = best.warlock, victim = who, id = bestId, ts = ts, heavy = true, source = "observed" }
  if not store(self, death, ts) then
    return nil
  end
  return death
end

-- A DEATH message m = {rideId, victim, warlock, secs, source} from sender,
-- received at ts. secs, the seconds from arrival to death, must be within
-- DEATH_WINDOW. When the ride's arrival was heard, ts itself must fall within
-- DEATH_WINDOW (plus a little for transport) after it, whatever secs says.
-- m.source is the sender's say-so and is not used.
--   * From the victim, on a ride whose start the victim announced and that
--     names the same warlock, and which has something behind it (R48): this
--     client has the warlock's ride log naming the victim, or saw the death
--     itself. That is a heavy death, source "self". A victim has one heavy death
--     at most; a claim on another ride is refused.
--   * From the victim, with nothing behind it: a light death, source "self",
--     no relayer. A victim has one such claim at most, and none while he has a
--     heavy death on another ride.
--   * From anyone else: a light death, source "relayed", via = {[sender] = true}.
-- Returns the death, or nil when the message is malformed, outside the window,
-- contradicts a known ride, is the victim's own claim about a ride that was
-- never announced or a second claim, or could not be stored.
function Witness:deathReported(m, sender, ts)
  if type(m) ~= "table" then
    return nil
  end
  local victim, warlock, from = nameOf(m.victim), nameOf(m.warlock), nameOf(sender)
  local rideId, secs = m.rideId, m.secs
  if not nonEmptyString(rideId) or victim == nil or warlock == nil or from == nil then
    return nil
  end
  if not finite(secs) or secs < 0 or secs > Config.DEATH_WINDOW or not finite(ts) then
    return nil
  end
  if not pairMatches(rideId, warlock, victim) then
    return nil
  end
  local ride = self.rides[rideId]
  if not rideFits(ride, victim, warlock, ts) then
    return nil
  end

  local death = { target = warlock, victim = victim, id = rideId, ts = ts }
  if Names.same(from, victim) then
    if ride == nil then
      return nil
    end
    if backed(self, warlock, rideId, victim) then
      if not heavyAllowed(self, victim, warlock, rideId) then
        return nil
      end
      death.heavy = true
    else
      if not claimAllowed(self, victim, warlock, rideId) then
        return nil
      end
      death.heavy = false
    end
    death.source = "self"
  else
    death.heavy, death.source, death.via = false, "relayed", { [from] = true }
  end
  if not store(self, death, ts) then
    return nil
  end
  return death
end

-- The warlock's ride log for rideId has arrived (RIDE_LOG, or a ride log in a
-- query reply): if this client holds the named victim's unproven self report of
-- a death on that ride, the log backs it and the death becomes heavy (R48).
-- The victim's one heavy death still applies. Returns the death as it is now
-- stored, or nil when there was nothing to make heavy.
function Witness:corroborate(warlock, rideId, now)
  local target = nameOf(warlock)
  if target == nil or not nonEmptyString(rideId) or not finite(now) then
    return nil
  end
  local death = storedDeath(self, target, rideId)
  if death == nil or kindOf(death) ~= "claim" then
    return nil
  end
  local victim = nameOf(death.victim)
  if victim == nil or not logNames(self, target, rideId, victim) or not heavyAllowed(self, victim, target, rideId) then
    return nil
  end
  local proven = { target = target, victim = victim, id = rideId, ts = death.ts, heavy = true, source = "self" }
  if not store(self, proven, now) then
    return nil
  end
  return proven
end

-- A death heard in someone's reply to a query, not in a DEATH message: rec =
-- {target, victim, id, ts} (ts is when the death happened), relayed by
-- `relayer`, received at `now`. It is always a light death, source "relayed",
-- via = {[relayer] = true}; the same checks of the ride id and of a known ride
-- apply as for a DEATH message. Going through the witness is what lets
-- aliveEvidence strike the relayer if the victim turns up alive. Returns the
-- death, or nil when it is malformed, contradicts a known ride, is dated ahead
-- of now, or could not be stored.
function Witness:relayedDeath(rec, relayer, now)
  if type(rec) ~= "table" then
    return nil
  end
  local warlock, victim, from = nameOf(rec.target), nameOf(rec.victim), nameOf(relayer)
  local rideId, ts = rec.id, rec.ts
  if not nonEmptyString(rideId) or warlock == nil or victim == nil or from == nil then
    return nil
  end
  if not finite(ts) or not finite(now) or not pairMatches(rideId, warlock, victim) then
    return nil
  end
  if not rideFits(self.rides[rideId], victim, warlock, ts) then
    return nil
  end
  local death = {
    target = warlock,
    victim = victim,
    id = rideId,
    ts = ts,
    heavy = false,
    source = "relayed",
    via = { [from] = true },
  }
  if not store(self, death, now) then
    return nil
  end
  return death
end

-- Alive ----------------------------------------------------------------------------

-- name was seen alive (they sent something) at time ts. Every stored death of
-- theirs older than ALIVE_GRACE seconds is then proved false:
--   * the player's own report (stored source "self", heavy or an unproven light
--     one, R48): they lied, so they are marked a liar and the death is removed;
--   * a relayed report (light): each relayer gets a strike and the death is
--     removed;
--   * a death this client saw for itself (source "observed") is never removed,
--     and neither is a heavy death of unknown source, nor a light one that
--     names no relayer: in doubt the death stays.
-- The source is the one stored with the death, so this works the same after a
-- reload. Returns how many deaths were removed.
function Witness:aliveEvidence(name, ts)
  local who = nameOf(name)
  if who == nil or not finite(ts) then
    return 0
  end
  local db = self.db
  local byKey = self.deathsOf[who]
  if byKey == nil then
    return 0
  end

  -- Collect first and change afterwards, so nothing is edited mid-traversal.
  local stale, gone = {}, {}
  for key, entry in pairs(byKey) do
    local death = storedDeath(self, entry.target, entry.id)
    if death == nil or not Names.same(death.victim, who) then
      gone[#gone + 1] = entry
    elseif finite(death.ts) and ts - death.ts > Config.ALIVE_GRACE then
      stale[#stale + 1] = { target = entry.target, id = entry.id, death = death, key = key }
    end
  end
  for _, entry in ipairs(gone) do
    untrack(self, who, entry.target, entry.id)
  end
  table.sort(stale, function(a, b)
    return a.key < b.key
  end)

  local removed = 0
  for _, s in ipairs(stale) do
    local death = s.death
    local refuted = false
    if death.heavy == true or kindOf(death) == "claim" then
      if death.source == "self" then
        Ratings.markLiar(db, who, ts)
        refuted = true
      end
    elseif type(death.via) == "table" then
      for relayer in pairs(death.via) do
        Ratings.strike(db, relayer)
      end
      refuted = true
    end
    if refuted and Ratings.removeDeath(db, s.target, s.id) then
      untrack(self, who, s.target, s.id)
      removed = removed + 1
    end
  end
  return removed
end

ns.Witness = M
