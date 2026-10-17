local _, ns = ...

-- Ratings: every warlock has a Trust rating (from travelers; safety) and a
-- Share rating (from clickers; payout fairness), one to five stars each.
--
-- Ratings spread from addon to addon with no server, so nobody can be taken at
-- their word and the rules do the checking:
--   * a direct rating counts only when its sender is its rater;
--   * a copy passed on by someone else (relayed) counts at low weight, and
--     more when three or more relayers back the same record;
--   * all the relayed weight for a warlock is capped, per relayer and in total,
--     so a flood of invented records buys only a small, fixed amount;
--   * a relayer whose copy was provably altered (same id and time as the
--     rater's own rating, other stars) gets a strike, and one with
--     STRIKES_MAX strikes is ignored;
--   * a rating counts in full only when the warlock's ride log names its
--     rater; all of one rater's other (one-sided) trust ratings count as one,
--     and so do all of a rater's direct share ratings;
--   * records dated ahead of the receiver's clock are refused;
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

-- The relayers in via that are still believed, sorted so every sum made from
-- them comes out the same each time. A via that is not a table has none.
local function liveRelayers(db, via)
  local live = {}
  if type(via) == "table" then
    for relayer in pairs(via) do
      if type(relayer) == "string" and not isLiar(db, relayer) and not isStruck(db, relayer) then
        live[#live + 1] = relayer
      end
    end
    table.sort(live)
  end
  return live
end

-- True when ts is dated further ahead of now than clocks can honestly differ.
-- Without a usable now there is nothing to compare with.
local function tooFar(ts, now)
  return finite(now) and ts > now + ns.Config.RATING.FUTURE_SLACK
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

-- True when every share amount a row carries is a finite number >= 0.
local function validAmounts(r)
  for _, field in ipairs(AMOUNTS) do
    local v = r[field]
    if v ~= nil and (not finite(v) or v < 0) then
      return false
    end
  end
  return true
end

-- A stored rating row that can be used: a hand-edited SavedVariables must
-- never make a read raise, so anything malformed is skipped.
local function validRating(r, kind)
  return type(r) == "table"
    and isStars(r.stars)
    and nonEmptyString(r.id)
    and nonEmptyString(r.rater)
    and finite(r.ts)
    and (kind ~= "share" or validAmounts(r))
end

local function validDeath(d)
  return type(d) == "table" and nonEmptyString(d.victim) and finite(d.ts)
end

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
    if not validAmounts(rec) then
      return nil, "bad_record"
    end
    for _, field in ipairs(AMOUNTS) do
      r[field] = rec[field]
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
local function accept(db, rec, sender, now)
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
  if tooFar(r.ts, now) then
    return nil, "future"
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
  -- very rating (same id, same time) that said other stars was altered on the
  -- way, so its relayers are struck. A copy with another time is just older
  -- or newer than this one, and no relayer is blamed for that.
  for i = #list, 1, -1 do
    local e = list[i]
    if sameSlot(e, r, day) then
      if isRelayed(e) and e.id == r.id and e.ts == r.ts and e.stars ~= r.stars then
        strikeAll(db, e.via)
      end
      table.remove(list, i)
    end
  end
  list[#list + 1] = r
  return r
end

-- A rating sent by its rater. now is the receiver's clock (seconds); leave it
-- out and the date is not checked. Returns true, or nil and a reason:
-- "not_rater", "bad_stars", "bad_record", "future" (dated ahead of now), "liar"
-- or "readonly".
-- The same rater's rating of the same warlock and kind on the same day
-- replaces the older one. A relayed copy of this rating is upgraded to direct,
-- and its relayers are struck only when the copy was provably altered.
function M.addDirect(db, rec, sender, now)
  local r, why = accept(db, rec, sender, now)
  if not r then
    return nil, why
  end
  return true
end

-- A rating passed on by relayer. Returns true, or nil and a reason:
-- "liar" (the rater or the relayer is one), "struck" (the relayer has too many
-- strikes), "contradicts_direct" (a copy of the rater's own rating with other
-- stars: the relayer gets a strike), "has_direct" (the rater's own rating is
-- already here, so this copy adds nothing and nobody is struck), "conflict"
-- (a relayed version with the same or fewer stars is here and stays), plus
-- "bad_stars", "bad_record", "future" and "readonly". A warlock relaying
-- ratings about itself is "bad_record".
-- A second relayer of the very same record (id, stars and time) is added to its
-- via. When two relayed versions differ, the one with the lower stars is kept,
-- which is the safe way round for a traveler; no relayer is struck for it.
function M.addRelayed(db, rec, relayer, now)
  if db._newer then
    return nil, "readonly"
  end
  local rater, target = identify(rec)
  local who = nameOf(relayer)
  -- A warlock passing on ratings of itself would be marking its own homework.
  if rater == nil or who == nil or who == target then
    return nil, "bad_record"
  end
  local r, why = build(rec, rater, target)
  if not r then
    return nil, why
  end
  if tooFar(r.ts, now) then
    return nil, "future"
  end
  -- A rater passing on their own rating is just sending it.
  if who == rater then
    return M.addDirect(db, rec, relayer, now)
  end
  if isLiar(db, rater) or isLiar(db, who) then
    return nil, "liar"
  end
  if isStruck(db, who) then
    return nil, "struck"
  end

  local list = ns.Store.ratingList(db, target, r.kind)
  local day = ns.Util.day(r.ts)
  local rivals = {} -- indexes of the relayed versions in this rater's slot
  for i, e in ipairs(list) do
    if sameSlot(e, r, day) then
      if isDirect(e) then
        -- Only a copy of this very record (same id, same time) with other
        -- stars was altered; any other difference is just an older or newer
        -- version, and the rater's own rating wins without blame.
        if e.id == r.id and e.ts == r.ts and e.stars ~= r.stars then
          M.strike(db, who)
          return nil, "contradicts_direct"
        end
        return nil, "has_direct"
      elseif isRelayed(e) and isStars(e.stars) then
        rivals[#rivals + 1] = i
      end
    end
  end

  if #rivals > 0 then
    local lowest = 5
    for _, i in ipairs(rivals) do
      lowest = math.min(lowest, list[i].stars)
    end
    if r.stars < lowest then
      -- The lower version replaces every higher one.
      for k = #rivals, 1, -1 do
        table.remove(list, rivals[k])
      end
    elseif r.stars == lowest then
      for _, i in ipairs(rivals) do
        local e = list[i]
        if e.id == r.id and e.stars == r.stars and e.ts == r.ts then
          e.via[who] = true
          return true
        end
      end
      return nil, "conflict"
    else
      return nil, "conflict"
    end
  end

  r.via = { [who] = true }
  list[#list + 1] = r
  return true
end

-- The rating the player gives: kept in `given` for good, then counted as a
-- direct rating from its rater. Returns what addDirect returns; a rating it
-- refuses is not added to `given`.
function M.give(db, rec, now)
  local r, why = accept(db, rec, type(rec) == "table" and rec.rater or nil, now)
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
-- or nil and "bad_record", "future" (dated ahead of now, the receiver's clock;
-- leave it out and the date is not checked) or "readonly".
function M.addDeath(db, d, now)
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
  if tooFar(d.ts, now) then
    return nil, "future"
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
-- Returns true, or nil and "bad_record", "future" (ts is ahead of now, the
-- receiver's clock; leave now out and it is not checked) or "readonly".
function M.addRideLog(db, warlock, id, ts, traveler, now)
  if db._newer then
    return nil, "readonly"
  end
  local name, rider = nameOf(warlock), nameOf(traveler)
  if name == nil or rider == nil or not nonEmptyString(id) or not finite(ts) then
    return nil, "bad_record"
  end
  if tooFar(ts, now) then
    return nil, "future"
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
-- Returns true, or nil and "bad_record", "future" (ts is ahead of now, the
-- receiver's clock; leave now out and it is not checked) or "readonly".
function M.addReceipt(db, warlock, id, ts, now)
  if db._newer then
    return nil, "readonly"
  end
  local name = nameOf(warlock)
  if name == nil or not nonEmptyString(id) or not finite(ts) then
    return nil, "bad_record"
  end
  if tooFar(ts, now) then
    return nil, "future"
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

-- The string keys of a table in a fixed order, so sums come out the same every time.
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

-- True when the ride log for a rating names its rater as the traveler.
local function namesRater(logs, r)
  local log = logs[r.id]
  return type(log) == "table" and ns.Names.same(log.traveler, r.rater)
end

-- Whether a death counts, and who stands behind it. Returns false for a death
-- that is ignored (malformed, or its victim is a liar, or every relayer is
-- struck or a liar). Otherwise true and the live relayers, nil for a first-hand
-- report that has none.
local function deathStanding(db, d)
  if not validDeath(d) or isLiar(db, d.victim) then
    return false
  end
  if d.via == nil then
    return true, nil
  end
  local live = liveRelayers(db, d.via)
  return #live > 0, live
end

-- Set the weight of every relayed entry. An entry has a base weight (W_RELAYED,
-- or W_RELAYED_CORROBORATED when three or more relayers back it) that is split
-- equally among its live relayers. What one relayer carries over all its
-- entries is then scaled down to RELAY_CAP_PER_RELAYER, and the sum over all
-- the entries to RELAY_CAP_TOTAL, each time in proportion. A forged flood of
-- second-hand records therefore buys a fixed, small amount of weight and no more.
local function weighRelayed(entries)
  local C = ns.Config.RATING
  local carried = {}
  for _, e in ipairs(entries) do
    local part = e.base / #e.relayers
    for _, relayer in ipairs(e.relayers) do
      carried[relayer] = (carried[relayer] or 0) + part
    end
  end
  local scale = {}
  for relayer, sum in pairs(carried) do
    scale[relayer] = sum > C.RELAY_CAP_PER_RELAYER and C.RELAY_CAP_PER_RELAYER / sum or 1
  end
  local total = 0
  for _, e in ipairs(entries) do
    local kept = 0
    for _, relayer in ipairs(e.relayers) do
      kept = kept + scale[relayer]
    end
    e.weight = e.base * (kept / #e.relayers)
    total = total + e.weight
  end
  if total > C.RELAY_CAP_TOTAL then
    local factor = C.RELAY_CAP_TOTAL / total
    for _, e in ipairs(entries) do
      e.weight = e.weight * factor
    end
  end
end

-- summary(db, target, kind) -> {stars, score, count, isNew, deathsReported}
--   stars           the weighted mean, one decimal, without the prior; nil
--                   when nothing counts
--   score           the weighted mean pulled toward the prior mean, for
--                   sorting and warnings
--   count           trust: distinct ride ids across ratings, deaths and
--                   receipts; share: the number of ratings. A display figure
--                   only: relayed ratings and receipts are in it.
--   isNew           fewer than NEW_BELOW direct ratings (and heavy deaths, for
--                   trust). Second-hand records and receipts never clear it.
--   deathsReported  deaths counted against the warlock, heavy or light
-- Weights:
--   * a direct trust rating is two-sided (W_TWO_SIDED) only when the
--     warlock's ride log for its id names its rater as the traveler, else
--     one-sided (W_ONE_SIDED); all of one rater's one-sided ratings together
--     count as one, the newest, and the rest weigh nothing (but are kept);
--   * all of one rater's direct share ratings together count as one, the
--     newest, at W_TWO_SIDED; the rest weigh nothing (but are kept);
--   * a relayed rating or light death with relayers weighs what weighRelayed
--     leaves it; a light death nobody relayed (seen first hand) weighs
--     W_RELAYED; a heavy death weighs W_DEATH.
-- Ignored records do not count anywhere: those of a liar, those whose relayers
-- are all struck or liars, and malformed rows. Reading creates nothing.
function M.summary(db, target, kind)
  if not KINDS[kind] then
    error('Ratings.summary: kind must be "trust" or "share"', 2)
  end
  local C = ns.Config.RATING
  local name = not db._newer and nameOf(target) or nil
  local entries, relayed = {}, {}
  local ratings, directRatings, deaths, heavyDeaths = 0, 0, 0, 0
  local ids, distinct = {}, 0
  local function seen(id)
    if not ids[id] then
      ids[id] = true
      distinct = distinct + 1
    end
  end

  if name then
    local list = stored(db, name, kind)
    local logs = sub(db, "rideLogs", name)

    -- A rater's direct share ratings, and their direct one-sided trust ratings
    -- (the ride log does not name them), count once: only the newest does.
    local function countsOnce(r)
      return kind == "share" or not namesRater(logs, r)
    end
    local newest = {}
    for _, r in ipairs(list) do
      if validRating(r, kind) and r.via == nil and not isLiar(db, r.rater) and countsOnce(r) then
        local best = newest[r.rater]
        if best == nil or r.ts > best.ts or (r.ts == best.ts and r.id > best.id) then
          newest[r.rater] = r
        end
      end
    end

    for _, r in ipairs(list) do
      if validRating(r, kind) and not isLiar(db, r.rater) then
        if r.via == nil then
          local weight
          if not countsOnce(r) then
            weight = C.W_TWO_SIDED
          elseif newest[r.rater] == r then
            weight = kind == "share" and C.W_TWO_SIDED or C.W_ONE_SIDED
          end
          if weight then
            entries[#entries + 1] = { stars = r.stars, weight = weight }
            ratings, directRatings = ratings + 1, directRatings + 1
            seen(r.id)
          end
        elseif type(r.via) == "table" then
          local live = liveRelayers(db, r.via)
          if #live > 0 then
            local e = {
              stars = r.stars,
              base = #live >= C.CORROBORATE_MIN and C.W_RELAYED_CORROBORATED or C.W_RELAYED,
              relayers = live,
            }
            entries[#entries + 1] = e
            relayed[#relayed + 1] = e
            ratings = ratings + 1
            seen(r.id)
          end
        end
      end
    end

    if kind == "trust" then
      local byId = sub(db, "deaths", name)
      for _, id in ipairs(sortedKeys(byId)) do
        local d = byId[id]
        local counts, live = deathStanding(db, d)
        if counts then
          if d.heavy == true then
            entries[#entries + 1] = { stars = 1, weight = C.W_DEATH }
            heavyDeaths = heavyDeaths + 1
          elseif live then
            local e = { stars = 1, base = C.W_RELAYED, relayers = live }
            entries[#entries + 1] = e
            relayed[#relayed + 1] = e
          else
            entries[#entries + 1] = { stars = 1, weight = C.W_RELAYED }
          end
          deaths = deaths + 1
          seen(id)
        end
      end
      for id in pairs(sub(db, "receipts", name)) do
        if nonEmptyString(id) then
          seen(id)
        end
      end
    end
  end

  weighRelayed(relayed)
  local sumW, sumWS = 0, 0
  for _, e in ipairs(entries) do
    sumW, sumWS = sumW + e.weight, sumWS + e.weight * e.stars
  end

  local stars = nil
  if sumW > 0 then
    stars = round1(sumWS / sumW)
  end
  return {
    stars = stars,
    score = (C.PRIOR_WEIGHT * C.PRIOR_MEAN + sumWS) / (C.PRIOR_WEIGHT + sumW),
    count = kind == "trust" and distinct or ratings,
    isNew = directRatings + heavyDeaths < C.NEW_BELOW,
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
-- Liars' records and malformed rows are not passed on. Reading creates nothing.
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
      if validRating(r, kind) and r.via == nil and not isLiar(db, r.rater) then
        local rec = { kind = kind, rater = r.rater, stars = r.stars, id = r.id, ts = r.ts }
        if kind == "share" then
          rec.owed, rec.received, rec.pct = r.owed, r.received, r.pct
        end
        out[#out + 1] = rec
      end
    end
  end

  for id, d in pairs(sub(db, "deaths", name)) do
    if nonEmptyString(id) and type(d) == "table" and d.heavy == true and deathStanding(db, d) then
      out[#out + 1] = { kind = "death", rater = d.victim, id = id, ts = d.ts, other = d.victim }
    end
  end

  if ns.Names.same(target, me) then
    for id, log in pairs(sub(db, "rideLogs", name)) do
      if nonEmptyString(id) and type(log) == "table" and finite(log.ts) and nonEmptyString(log.traveler) then
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
