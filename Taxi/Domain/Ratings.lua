local _, ns = ...

-- Ratings: every warlock has a Trust rating (from travelers; safety) and a
-- Share rating (from clickers; payout fairness), one to five stars each.
--
-- Ratings spread from addon to addon with no server, so nobody can be taken at
-- their word and the rules do the checking:
--   * a direct rating counts only when its sender is its rater;
--   * a copy passed on by someone else (relayed) counts at low weight, and
--     more when three or more relayers back the same record;
--   * a relayer whose copy turns out to contradict the rater's own gets a
--     strike, and one with STRIKES_MAX strikes is ignored;
--   * a player caught lying is ignored altogether;
--   * a death after a summon weighs heavily.
-- A warlock shown with a score that is too high could get a Hardcore traveler
-- killed, so anything unclear is refused rather than counted.
--
-- A liar's or a struck relayer's influence is removed when a summary is made,
-- not by deleting records, so nothing has to be restored.
local M = {}

local KINDS = { trust = true, share = true }

-- The share amounts a clicker's rating can carry.
local AMOUNTS = { "owed", "received", "pct" }

-- True only for a real, finite number (not nil, not NaN, not +-infinity).
local function finite(x)
  return type(x) == "number" and x == x and x ~= math.huge and x ~= -math.huge
end

local function round1(x)
  return math.floor(x * 10 + 0.5) / 10
end

-- A name tidied the way every key in the db is, or nil when x is not a usable
-- name.
local function nameOf(x)
  local n = ns.Names.normalize(x)
  if n == nil or n == "" then
    return nil
  end
  return n
end

local function isStars(x)
  return finite(x) and x == math.floor(x) and x >= 1 and x <= 5
end

local function nonEmptyString(x)
  return type(x) == "string" and x ~= ""
end

local function isLiar(db, name)
  return db.liars[name] ~= nil
end

local function strikesOf(db, name)
  local n = db.strikes[name]
  return type(n) == "number" and n or 0
end

local function isStruck(db, name)
  return strikesOf(db, name) >= ns.Config.RATING.STRIKES_MAX
end

-- How many of the relayers in via are still believed. A via that is not a
-- table counts nobody.
local function liveRelayers(db, via)
  if type(via) ~= "table" then
    return 0
  end
  local n = 0
  for relayer in pairs(via) do
    if type(relayer) == "string" and not isLiar(db, relayer) and not isStruck(db, relayer) then
      n = n + 1
    end
  end
  return n
end

-- Give a strike to every relayer in via.
local function strikeAll(db, via)
  if type(via) == "table" then
    for relayer in pairs(via) do
      M.strike(db, relayer)
    end
  end
end

-- A warlock's stored list of one kind, read without creating anything.
local function stored(db, target, kind)
  local entry = db.ratings[target]
  local list = type(entry) == "table" and entry[kind]
  if type(list) == "table" then
    return list
  end
  return {}
end

-- A warlock's table of deaths, rideLogs or receipts, read without creating it.
local function sub(db, field, target)
  local t = db[field][target]
  if type(t) == "table" then
    return t
  end
  return {}
end

-- Records ----------------------------------------------------------------------

-- Who made a record and who it is about, as normalized names; nil when it is
-- not a trust or share record naming both.
local function identify(rec)
  if type(rec) ~= "table" or not KINDS[rec.kind] then
    return nil
  end
  local rater, target = nameOf(rec.rater), nameOf(rec.target)
  if rater == nil or target == nil then
    return nil
  end
  return rater, target
end

-- A fresh record from rec, holding only the fields that belong in one, with
-- everything checked. Returns nil and a reason when something is wrong.
local function build(rec, rater, target)
  if not isStars(rec.stars) then
    return nil, "bad_stars"
  end
  if not nonEmptyString(rec.id) or not finite(rec.ts) then
    return nil, "bad_record"
  end
  -- A warlock is never their own traveler or clicker.
  if rater == target then
    return nil, "bad_record"
  end
  local r = { kind = rec.kind, rater = rater, target = target, stars = rec.stars, id = rec.id, ts = rec.ts }
  if rec.kind == "share" then
    for _, field in ipairs(AMOUNTS) do
      local v = rec[field]
      if v ~= nil then
        if not finite(v) or v < 0 then
          return nil, "bad_record"
        end
        r[field] = v
      end
    end
  end
  return r
end

-- True for a stored record that came straight from its rater.
local function isDirect(e)
  return type(e) == "table" and e.via == nil
end

local function isRelayed(e)
  return type(e) == "table" and type(e.via) == "table"
end

-- True when stored record e is by the same rater as r and is r's ride, or r's
-- day: a rater has one rating per warlock, kind and day.
local function sameSlot(e, r, day)
  return type(e) == "table"
    and e.rater == r.rater
    and (e.id == r.id or (finite(e.ts) and ns.Util.day(e.ts) == day))
end

-- Check rec and keep it as a direct rating. Returns the record that was built
-- (even when a newer rating of the day was kept instead), or nil and a reason.
local function accept(db, rec, sender)
  if db._newer then
    return nil, "readonly"
  end
  local rater, target = identify(rec)
  if rater == nil then
    return nil, "bad_record"
  end
  if not ns.Names.same(sender, rater) then
    return nil, "not_rater"
  end
  local r, why = build(rec, rater, target)
  if not r then
    return nil, why
  end
  if isLiar(db, rater) then
    return nil, "liar"
  end

  local list = ns.Store.ratingList(db, target, r.kind)
  local day = ns.Util.day(r.ts)

  -- The rater's newest direct rating of that ride or day is the one kept.
  for _, e in ipairs(list) do
    if sameSlot(e, r, day) and isDirect(e) and finite(e.ts) and e.ts > r.ts then
      return r
    end
  end

  -- Everything else of the rater's in that slot goes. A relayed copy of this
  -- very rating that said something else was lying: its relayers are struck.
  for i = #list, 1, -1 do
    local e = list[i]
    if sameSlot(e, r, day) then
      if isRelayed(e) and e.id == r.id and e.stars ~= r.stars then
        strikeAll(db, e.via)
      end
      table.remove(list, i)
    end
  end
  list[#list + 1] = r
  return r
end

-- A rating sent by its rater. Returns true, or nil and a reason:
-- "not_rater", "bad_stars", "bad_record", "liar" or "readonly".
-- The same rater's rating of the same warlock and kind on the same day
-- replaces the older one. A relayed copy of this rating is upgraded to direct,
-- and its relayers are struck when it said different stars.
function M.addDirect(db, rec, sender)
  local r, why = accept(db, rec, sender)
  if not r then
    return nil, why
  end
  return true
end

-- A rating passed on by relayer. Returns true, or nil and a reason:
-- "liar" (the rater or the relayer is one), "struck" (the relayer has too many
-- strikes), "contradicts_direct" (and the relayer gets a strike), "has_direct"
-- (the rater's own rating is already here), "conflict" (another relayed
-- version is here and it stays: the new one is refused, with no strike), plus
-- "bad_stars", "bad_record" and "readonly".
-- A second relayer of the same record is added to its via.
function M.addRelayed(db, rec, relayer)
  if db._newer then
    return nil, "readonly"
  end
  local rater, target = identify(rec)
  local who = nameOf(relayer)
  if rater == nil or who == nil then
    return nil, "bad_record"
  end
  local r, why = build(rec, rater, target)
  if not r then
    return nil, why
  end
  -- A rater passing on their own rating is just sending it.
  if who == rater then
    return M.addDirect(db, rec, relayer)
  end
  if isLiar(db, rater) or isLiar(db, who) then
    return nil, "liar"
  end
  if isStruck(db, who) then
    return nil, "struck"
  end

  local list = ns.Store.ratingList(db, target, r.kind)
  local day = ns.Util.day(r.ts)
  local same, directThatDay, relayedThatDay
  for _, e in ipairs(list) do
    if type(e) == "table" and e.rater == rater then
      if e.id == r.id then
        same = e
      elseif finite(e.ts) and ns.Util.day(e.ts) == day then
        if isDirect(e) then
          directThatDay = true
        else
          relayedThatDay = true
        end
      end
    end
  end

  if same then
    if isDirect(same) then
      if same.stars == r.stars then
        return nil, "has_direct"
      end
      M.strike(db, who)
      return nil, "contradicts_direct"
    end
    if not isRelayed(same) or same.stars ~= r.stars then
      return nil, "conflict"
    end
    same.via[who] = true
    return true
  end
  if directThatDay then
    return nil, "has_direct"
  end
  if relayedThatDay then
    return nil, "conflict"
  end

  r.via = { [who] = true }
  list[#list + 1] = r
  return true
end

-- The rating the player gives: kept in `given` for good, then counted as a
-- direct rating from its rater. Returns what addDirect returns; a rating it
-- refuses is not added to `given`.
function M.give(db, rec)
  local r, why = accept(db, rec, type(rec) == "table" and rec.rater or nil)
  if not r then
    return nil, why
  end
  db.given[#db.given + 1] = ns.Util.copy(r)
  return true
end

-- Deaths, ride logs, receipts ---------------------------------------------------

-- The relayers of two reports of one death. A report with no relayer is first
-- hand, and it keeps the death first hand.
local function mergeVia(a, b)
  if a == nil or b == nil then
    return nil
  end
  if type(a) ~= "table" then
    return b
  end
  for relayer in pairs(b) do
    a[relayer] = true
  end
  return a
end

-- A death after a summon: d = {target, victim, id, ts, heavy, via}. It is kept
-- in db.deaths[target][id]. A heavy death (first hand) replaces a light one
-- (heard from others); a light one never replaces a heavy one. Returns true,
-- or nil and "bad_record" or "readonly".
function M.addDeath(db, d)
  if db._newer then
    return nil, "readonly"
  end
  if type(d) ~= "table" then
    return nil, "bad_record"
  end
  local target, victim = nameOf(d.target), nameOf(d.victim)
  if target == nil or victim == nil or not nonEmptyString(d.id) or not finite(d.ts) then
    return nil, "bad_record"
  end
  if d.via ~= nil and type(d.via) ~= "table" then
    return nil, "bad_record"
  end
  local via
  if d.via ~= nil then
    via = {}
    for relayer, on in pairs(d.via) do
      local n = on and nameOf(relayer)
      if n then
        via[n] = true
      end
    end
  end
  local new = { target = target, victim = victim, id = d.id, ts = d.ts, heavy = d.heavy == true, via = via }

  local deaths = db.deaths[target]
  if type(deaths) ~= "table" then
    deaths = {}
    db.deaths[target] = deaths
  end
  local old = deaths[d.id]
  if type(old) == "table" then
    if old.heavy and not new.heavy then
      return true
    elseif old.heavy == new.heavy then
      old.via = mergeVia(old.via, new.via)
      return true
    end
  end
  deaths[d.id] = new
  return true
end

-- Take a death back (its victim was seen alive after all). Returns whether
-- there was one.
function M.removeDeath(db, target, id)
  local name = nameOf(target)
  if db._newer or name == nil or not nonEmptyString(id) then
    return false
  end
  local deaths = db.deaths[name]
  if type(deaths) ~= "table" or deaths[id] == nil then
    return false
  end
  deaths[id] = nil
  if next(deaths) == nil then
    db.deaths[name] = nil
  end
  return true
end

-- A warlock's own record of a ride they gave: db.rideLogs[warlock][id].
-- Returns true, or nil and "bad_record" or "readonly".
function M.addRideLog(db, warlock, id, ts, traveler)
  if db._newer then
    return nil, "readonly"
  end
  local name, rider = nameOf(warlock), nameOf(traveler)
  if name == nil or rider == nil or not nonEmptyString(id) or not finite(ts) then
    return nil, "bad_record"
  end
  local logs = db.rideLogs[name]
  if type(logs) ~= "table" then
    logs = {}
    db.rideLogs[name] = logs
  end
  logs[id] = { ts = ts, traveler = rider }
  return true
end

-- A traveler's note that a ride arrived: db.receipts[warlock][id] = ts.
-- Returns true, or nil and "bad_record" or "readonly".
function M.addReceipt(db, warlock, id, ts)
  if db._newer then
    return nil, "readonly"
  end
  local name = nameOf(warlock)
  if name == nil or not nonEmptyString(id) or not finite(ts) then
    return nil, "bad_record"
  end
  local receipts = db.receipts[name]
  if type(receipts) ~= "table" then
    receipts = {}
    db.receipts[name] = receipts
  end
  receipts[id] = ts
  return true
end

-- Strikes and liars --------------------------------------------------------------

-- One more strike against a relayer. Returns their strike count.
function M.strike(db, name)
  local n = nameOf(name)
  if db._newer or n == nil then
    return nil
  end
  db.strikes[n] = strikesOf(db, n) + 1
  return db.strikes[n]
end

-- Ignore a player for good: they were caught lying at time ts.
function M.markLiar(db, name, ts)
  local n = nameOf(name)
  if db._newer or n == nil then
    return
  end
  db.liars[n] = finite(ts) and ts or 0
end

-- Summary -------------------------------------------------------------------------

-- What a stored rating weighs, or nil when it is not counted.
local function ratingWeight(db, target, kind, r)
  if type(r) ~= "table" or not isStars(r.stars) or isLiar(db, r.rater) then
    return nil
  end
  local C = ns.Config.RATING
  if r.via == nil then
    -- A clicker is by definition in the ride, so a direct share rating is
    -- as good as a two-sided trust rating.
    if kind == "share" or sub(db, "rideLogs", target)[r.id] ~= nil then
      return C.W_TWO_SIDED
    end
    return C.W_ONE_SIDED
  end
  local live = liveRelayers(db, r.via)
  if live == 0 then
    return nil
  elseif live >= C.CORROBORATE_MIN then
    return C.W_RELAYED_CORROBORATED
  end
  return C.W_RELAYED
end

-- What a stored death weighs (it always counts as 1 star), or nil when it is
-- not counted.
local function deathWeight(db, d)
  if type(d) ~= "table" or isLiar(db, d.victim) then
    return nil
  end
  if d.via ~= nil and liveRelayers(db, d.via) == 0 then
    return nil
  end
  local C = ns.Config.RATING
  return d.heavy == true and C.W_DEATH or C.W_RELAYED
end

-- The ids of a table in a fixed order, so sums come out the same every time.
local function sortedKeys(t)
  local keys = {}
  for k in pairs(t) do
    if type(k) == "string" then
      keys[#keys + 1] = k
    end
  end
  table.sort(keys)
  return keys
end

-- summary(db, target, kind) -> {stars, score, count, isNew, deathsReported}
--   stars           the weighted mean, one decimal, without the prior; nil
--                   when nothing counts
--   score           the weighted mean pulled toward the prior mean, for
--                   sorting and warnings
--   count           trust: distinct ride ids across ratings, deaths and
--                   receipts; share: the number of ratings
--   isNew           fewer than NEW_BELOW ratings (and deaths, for trust)
--   deathsReported  deaths counted against the warlock, heavy or light
-- Reading creates nothing.
function M.summary(db, target, kind)
  if not KINDS[kind] then
    error('Ratings.summary: kind must be "trust" or "share"', 2)
  end
  local C = ns.Config.RATING
  local name = not db._newer and nameOf(target) or nil
  local sumW, sumWS, used, deaths = 0, 0, 0, 0
  local ids, distinct = {}, 0
  local function seen(id)
    if not ids[id] then
      ids[id] = true
      distinct = distinct + 1
    end
  end

  if name then
    for _, r in ipairs(stored(db, name, kind)) do
      local w = ratingWeight(db, name, kind, r)
      if w then
        sumW, sumWS, used = sumW + w, sumWS + w * r.stars, used + 1
        seen(r.id)
      end
    end
    if kind == "trust" then
      local byId = sub(db, "deaths", name)
      for _, id in ipairs(sortedKeys(byId)) do
        local w = deathWeight(db, byId[id])
        if w then
          sumW, sumWS, deaths = sumW + w, sumWS + w, deaths + 1
          seen(id)
        end
      end
      for id in pairs(sub(db, "receipts", name)) do
        if type(id) == "string" then
          seen(id)
        end
      end
    end
  end

  local stars = nil
  if sumW > 0 then
    stars = round1(sumWS / sumW)
  end
  return {
    stars = stars,
    score = (C.PRIOR_WEIGHT * C.PRIOR_MEAN + sumWS) / (C.PRIOR_WEIGHT + sumW),
    count = kind == "trust" and distinct or used,
    isNew = used + deaths < C.NEW_BELOW,
    deathsReported = deaths,
  }
end

-- Replies ---------------------------------------------------------------------------

-- Newest first. Equal times are put in a fixed order, because the records come
-- out of tables whose order is not.
local function newestFirst(a, b)
  if a.ts ~= b.ts then
    return a.ts > b.ts
  end
  if a.kind ~= b.kind then
    return a.kind < b.kind
  end
  if a.id ~= b.id then
    return a.id < b.id
  end
  return a.rater < b.rater
end

-- The records to send back to someone asking about target (`me` is this
-- player), as Protocol.RECORD tables, newest first, at most max (default
-- QUERY_MAX_RECORDS):
--   * the direct trust and share ratings about the target, never relayed ones;
--   * the heavy deaths, as kind "death" (rater and other are the victim);
--   * when the target is me, my own ride logs, as kind "ridelog" (other is
--     the traveler).
-- Liars' records are not passed on. Reading creates nothing.
function M.replyRecords(db, target, me, max)
  local out = {}
  local name = not db._newer and nameOf(target) or nil
  if name == nil then
    return out
  end
  if not finite(max) then
    max = ns.Config.QUERY_MAX_RECORDS
  end

  for kind in pairs(KINDS) do
    for _, r in ipairs(stored(db, name, kind)) do
      if
        isDirect(r)
        and isStars(r.stars)
        and nonEmptyString(r.rater)
        and nonEmptyString(r.id)
        and finite(r.ts)
        and not isLiar(db, r.rater)
      then
        out[#out + 1] = {
          kind = kind, rater = r.rater, stars = r.stars, id = r.id, ts = r.ts,
          owed = r.owed, received = r.received, pct = r.pct,
        }
      end
    end
  end

  local deaths = sub(db, "deaths", name)
  for id, d in pairs(deaths) do
    if
      type(d) == "table"
      and d.heavy == true
      and nonEmptyString(d.victim)
      and finite(d.ts)
      and nonEmptyString(id)
      and deathWeight(db, d)
    then
      out[#out + 1] = { kind = "death", rater = d.victim, id = id, ts = d.ts, other = d.victim }
    end
  end

  if ns.Names.same(target, me) then
    for id, log in pairs(sub(db, "rideLogs", name)) do
      if type(log) == "table" and nonEmptyString(id) and finite(log.ts) then
        out[#out + 1] = { kind = "ridelog", rater = name, id = id, ts = log.ts, other = log.traveler }
      end
    end
  end

  table.sort(out, newestFirst)
  for i = math.max(math.floor(max), 0) + 1, #out do
    out[i] = nil
  end
  return out
end

ns.Ratings = M
