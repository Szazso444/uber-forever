local _, ns = ...

-- TaxiDB, the account-wide SavedVariables table: schema, migration, pruning.
-- This is where ratings live between sessions, so nothing here may wipe data:
-- missing tables are filled in, older formats are migrated, and data written
-- by a newer addon version is left exactly as it is.
local M = {}

M.VERSION = 1

-- migrations[v](db) upgrades a db from schema version v to v + 1 in place.
-- A version that needs no step has no entry. A step runs again after a crash
-- or error part-way through, so it must be safe to repeat.
M.migrations = {}

-- Tables every db has, whatever its version.
local TABLES = { "ratings", "given", "deaths", "rideLogs", "receipts", "rides", "liars", "strikes", "settings" }

-- The two rating lists kept for each warlock.
local KINDS = { trust = true, share = true }

local function isVersion(v)
  return type(v) == "number" and v >= 1 and v == math.floor(v)
end

-- Make saved (or a new table when there is none) a usable db and return it.
-- A saved version above VERSION means a newer addon wrote it: the db comes
-- back untouched apart from the db._newer flag, and the caller must not write
-- to it. The flag is cleared again once the version matches, because it is
-- saved to disk with everything else. A missing or invalid version is taken
-- to be the current one.
function M.init(saved)
  local db = type(saved) == "table" and saved or {}
  local version = db.version
  if type(version) == "number" and version > M.VERSION then
    db._newer = true
    return db
  end
  db._newer = nil
  if not isVersion(version) then
    version = M.VERSION
  end
  for from = version, M.VERSION - 1 do
    local step = M.migrations[from]
    if step then
      step(db)
    end
    db.version = from + 1
  end
  db.version = M.VERSION
  for _, name in ipairs(TABLES) do
    if type(db[name]) ~= "table" then
      db[name] = {}
    end
  end
  return db
end

-- The rating list of one kind ("trust" or "share") for a warlock, created on
-- demand along with the warlock's entry. A newer db is never written to, so
-- it gets a new empty list that is not attached to it.
function M.ratingList(db, target, kind)
  if not KINDS[kind] then
    error('Store.ratingList: kind must be "trust" or "share"', 2)
  end
  if db._newer then
    return {}
  end
  local entry = db.ratings[target]
  if type(entry) ~= "table" then
    entry = {}
    db.ratings[target] = entry
  end
  local list = entry[kind]
  if type(list) ~= "table" then
    list = {}
    entry[kind] = list
  end
  return list
end

-- A record's timestamp for ordering. A missing or invalid one counts as the
-- oldest possible.
local function timestamp(record)
  local ts = type(record) == "table" and record.ts
  if type(ts) == "number" and ts == ts then
    return ts
  end
  return -math.huge
end

-- Oldest first. Equal timestamps keep their list order, because table.sort
-- alone does not.
local function oldestFirst(a, b)
  if a.ts ~= b.ts then
    return a.ts < b.ts
  end
  return a.idx < b.idx
end

-- The order records are dropped in: relayed ones (non-nil `via`, second-hand
-- and cheap to forge) before direct ones, oldest first within each group.
local function droppedFirst(a, b)
  if a.relayed ~= b.relayed then
    return a.relayed
  end
  return oldestFirst(a, b)
end

-- Drop records of list, in place, until at most cap are left: relayed ones
-- before direct ones, the oldest first within each. What stays is ordered
-- oldest to newest.
local function trim(list, cap)
  local n = #list
  if n <= cap then
    return
  end
  local ranked = {}
  for i = 1, n do
    local record = list[i]
    ranked[i] = {
      record = record,
      ts = timestamp(record),
      idx = i,
      relayed = type(record) == "table" and record.via ~= nil,
    }
  end
  table.sort(ranked, droppedFirst)
  local kept = {}
  for i = n - cap + 1, n do
    kept[#kept + 1] = ranked[i]
  end
  table.sort(kept, oldestFirst)
  for i = 1, cap do
    list[i] = kept[i].record
  end
  for i = cap + 1, n do
    list[i] = nil
  end
end

-- The order deaths are dropped in: light (non-heavy) before heavy, oldest first
-- within each group, then by id so the result is the same every time.
local function deathDroppedFirst(a, b)
  if a.heavy ~= b.heavy then
    return not a.heavy
  end
  if a.ts ~= b.ts then
    return a.ts < b.ts
  end
  return a.key < b.key
end

-- Drop deaths of one warlock (a table of death records by ride id), in place,
-- until at most cap are left. A row that is not a record counts as the oldest
-- light death.
local function trimDeaths(byId, cap)
  local ranked = {}
  for id, death in pairs(byId) do
    ranked[#ranked + 1] = {
      id = id,
      key = tostring(id),
      ts = timestamp(death),
      heavy = type(death) == "table" and death.heavy == true,
    }
  end
  local n = #ranked
  if n <= cap then
    return
  end
  table.sort(ranked, deathDroppedFirst)
  for i = 1, n - cap do
    byId[ranked[i].id] = nil
  end
end

-- Cap every warlock's trust and share lists, and the deaths on file for each
-- warlock, at RATING.CAP_PER_KIND. Ratings drop relayed records before direct
-- ones and the oldest first within each; deaths drop light ones before heavy
-- ones, the oldest first within each. Nothing else is pruned: `given` in
-- particular is kept for good. A newer db is not touched.
function M.prune(db)
  if db._newer then
    return
  end
  local cap = ns.Config.RATING.CAP_PER_KIND
  for _, entry in pairs(db.ratings) do
    if type(entry) == "table" then
      for kind in pairs(KINDS) do
        if type(entry[kind]) == "table" then
          trim(entry[kind], cap)
        end
      end
    end
  end
  for _, byId in pairs(db.deaths) do
    if type(byId) == "table" then
      trimDeaths(byId, cap)
    end
  end
end

ns.Store = M
