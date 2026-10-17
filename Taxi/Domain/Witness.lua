local _, ns = ...

-- Witness: ties a traveler's death to the summon that brought them, and takes
-- it back when the traveler turns out to be alive.
--
-- On Hardcore a death soon after a summon is the heaviest thing that can count
-- against a warlock, so only first-hand evidence is heavy:
--   * a death this client saw itself (server death data, or its own death),
--     on a ride whose arrival it heard from the traveler;
--   * the traveler's own report, on a ride whose start it heard from them.
-- A report from anyone else is a relayed (light) one: it is worth little, and
-- its relayer is struck if the "dead" traveler is seen alive.
-- A traveler who reports their own death and is then seen alive is a liar.
--
-- Rides are only ever learned from the traveler (the sender must be the
-- traveler), so nobody can start a ride for someone else. The witness keeps
-- rides in memory for RIDE_MEMORY seconds; the deaths themselves are stored
-- through Ratings, which does not keep where a death came from, so the witness
-- remembers that too (ride.deathSource) for as long as it remembers the ride.
local Names, Ratings, Config = ns.Names, ns.Ratings, ns.Config

local M = {}

local Witness = {}
Witness.__index = Witness

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
-- any other form is not checked.
local function pairMatches(rideId, warlock, victim)
  if Names.same(warlock, victim) then
    return false
  end
  local driver, traveler = rideId:match("^([^@]+)@([^@]+)@%d+$")
  if driver == nil then
    return true
  end
  return Names.same(driver, warlock) and Names.same(traveler, victim)
end

-- db: the TaxiDB table, where deaths, liars and strikes are kept.
function M.new(db)
  return setmetatable({ db = db, rides = {} }, Witness)
end

-- Rides --------------------------------------------------------------------------

-- The traveler announced a ride (RIDE_START). Only the traveler's own message
-- counts, so sender must be the victim. Returns whether the ride is now known.
-- Hearing a known ride's start again changes nothing.
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
  self.rides[rideId] = { victim = who, warlock = driver, startTs = ts }
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
-- there is none, when this ride's death was already seen, or when it could not
-- be stored.
function Witness:observedDeath(victim, ts)
  local who = nameOf(victim)
  if who == nil or not finite(ts) then
    return nil
  end
  local bestId, best
  for id, ride in pairs(self.rides) do
    if Names.same(ride.victim, who) and ride.arrivedTs ~= nil then
      local after = ts - ride.arrivedTs
      if after >= 0 and after <= Config.DEATH_WINDOW then
        if best == nil or ride.arrivedTs > best.arrivedTs or (ride.arrivedTs == best.arrivedTs and id < bestId) then
          bestId, best = id, ride
        end
      end
    end
  end
  if best == nil or best.deathSource == "observed" then
    return nil
  end
  local death = { target = best.warlock, victim = best.victim, id = bestId, ts = ts, heavy = true, source = "observed" }
  if not Ratings.addDeath(self.db, death, ts) then
    return nil
  end
  -- Seeing it for ourselves outranks anyone's report: it is never taken back.
  best.deathSource = "observed"
  return death
end

-- A DEATH message m = {rideId, victim, warlock, secs, source} from sender,
-- received at ts. secs, the seconds from arrival to death, must be within
-- DEATH_WINDOW. m.source is the sender's say-so and is not used.
--   * From the victim, on a ride whose start the victim announced and that
--     names the same warlock: a heavy death, source "self".
--   * From anyone else: a light death, source "relayed", via = {[sender] = true}.
-- Returns the death, or nil when the message is malformed, outside the window,
-- contradicts a known ride, is the victim's own claim about a ride that was
-- never announced, or could not be stored.
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
  if ride ~= nil and not (Names.same(ride.victim, victim) and Names.same(ride.warlock, warlock)) then
    return nil
  end

  local death = { target = warlock, victim = victim, id = rideId, ts = ts }
  if Names.same(from, victim) then
    if ride == nil then
      return nil
    end
    death.heavy, death.source = true, "self"
  else
    death.heavy, death.source, death.via = false, "relayed", { [from] = true }
  end
  if not Ratings.addDeath(self.db, death, ts) then
    return nil
  end
  if death.heavy and ride.deathSource == nil then
    ride.deathSource = "self"
  end
  return death
end

-- Alive ----------------------------------------------------------------------------

-- Where a stored heavy death came from, "self" or "observed", or nil when the
-- witness no longer knows (its ride was forgotten).
local function sourceOf(rides, target, id, death)
  local ride = rides[id]
  if ride ~= nil and Names.same(ride.warlock, target) and Names.same(ride.victim, death.victim) then
    return ride.deathSource
  end
  return nil
end

-- name was seen alive (they sent something) at time ts. Every stored death of
-- theirs older than ALIVE_GRACE seconds is then proved false:
--   * the player's own report (heavy, "self"): they lied, so they are marked a
--     liar and the death is removed;
--   * a relayed report (light): each relayer gets a strike and the death is
--     removed;
--   * a death this client saw for itself ("observed") is never removed, and
--     neither is a heavy death whose source is no longer known, nor a light one
--     that names no relayer: in doubt the death stays.
-- Returns how many deaths were removed.
function Witness:aliveEvidence(name, ts)
  local who = nameOf(name)
  if who == nil or not finite(ts) then
    return 0
  end
  local db = self.db

  -- Collect first and change afterwards, so the db is not edited mid-traversal.
  local stale = {}
  for target, byId in pairs(db.deaths) do
    if type(target) == "string" and type(byId) == "table" then
      for id, death in pairs(byId) do
        if type(id) == "string" and type(death) == "table" and finite(death.ts)
          and ts - death.ts > Config.ALIVE_GRACE and Names.same(death.victim, who) then
          stale[#stale + 1] = { target = target, id = id, death = death }
        end
      end
    end
  end
  table.sort(stale, function(a, b)
    if a.target ~= b.target then
      return a.target < b.target
    end
    return a.id < b.id
  end)

  local removed = 0
  for _, s in ipairs(stale) do
    local death = s.death
    local refuted = false
    if death.heavy == true then
      if sourceOf(self.rides, s.target, s.id, death) == "self" then
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
      removed = removed + 1
    end
  end
  return removed
end

ns.Witness = M
