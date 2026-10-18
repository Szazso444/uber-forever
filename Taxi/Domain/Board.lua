local _, ns = ...

-- The Board: this client's view of every other player's stand, built from the
-- STAND heartbeats it hears. An entry is a view from Stand.fromFields, keyed by
-- standId, and lives until its owner ends it or goes quiet for STAND_TTL.
local M = {}

-- Where a stand is. When any of these differ between two heartbeats the stand
-- has moved; the Summon Guard compares changedAt with the time of a request to
-- warn that the stand moved after you asked.
local PLACE_FIELDS = { "mapID", "wx", "wy", "zone", "subzone" }

local function samePlace(a, b)
  for _, field in ipairs(PLACE_FIELDS) do
    if a[field] ~= b[field] then
      return false
    end
  end
  return true
end

function M.new()
  return { stands = {} }
end

-- The seconds a stand id ends in (ids are owner@seconds), or nil.
local function idTime(standId)
  return tonumber(type(standId) == "string" and standId:match("@(%d+)$") or nil)
end

-- Whether stand id `a` is older than `b`, both of one owner: by the seconds
-- they end in; when either has none, `a` (heard before) is the older.
local function olderId(a, b)
  local ta, tb = idTime(a), idTime(b)
  if ta == nil or tb == nil then
    return true
  end
  return ta <= tb
end

-- Stores `view` (replacing the entry with the same standId) and stamps its
-- changedAt: `now` for a new stand or one that has moved, otherwise the earlier
-- entry's changedAt carried forward. An owner has one stand on the board, the
-- newest (M6): a new id replaces the owner's older entry, and a late heartbeat
-- of an older stand is not stored. Returns whether the view was stored.
function M.upsert(b, view, now)
  for standId, other in pairs(b.stands) do
    if standId ~= view.standId and ns.Names.same(other.owner, view.owner) then
      if olderId(standId, view.standId) then
        b.stands[standId] = nil
      else
        return false
      end
    end
  end
  local previous = b.stands[view.standId]
  if previous ~= nil and samePlace(previous, view) then
    view.changedAt = previous.changedAt
  else
    view.changedAt = now
  end
  view.seenAt = view.seenAt or now
  b.stands[view.standId] = view
  return true
end

function M.remove(b, standId)
  b.stands[standId] = nil
end

-- True when a stand heard last at view.seenAt is still listed at time now: not
-- silent for more than STAND_TTL seconds. Without a time every stand is.
local function listed(view, now)
  return now == nil or now - view.seenAt <= ns.Config.STAND_TTL
end

-- The stand with this id, or nil. Given the current time `now`, a stand that has
-- gone quiet for more than STAND_TTL is not there (R51): the sweep (expire)
-- only runs now and then, and a stand must not outlive its TTL until it does.
function M.get(b, standId, now)
  local view = b.stands[standId]
  if view ~= nil and not listed(view, now) then
    return nil
  end
  return view
end

-- Drops every stand not heard from for more than STAND_TTL seconds.
function M.expire(b, now)
  for standId, view in pairs(b.stands) do
    if not listed(view, now) then
      b.stands[standId] = nil
    end
  end
end

-- The stands matching `opts`, best first. `opts`:
--   kind, faction  keep only this kind / faction when given
--   zone           keep only stands in exactly this zone when given
--   statuses       a set ({live = true, ...}): keep only stands with one of
--                  these statuses when given (R69)
--   isGuildmate    function(owner) -> bool; guildmates sort first
--   rank           function(owner) -> score, count
--   now            the current time: stands silent for more than STAND_TTL are
--                  left out (R51); without it every stand on the board is listed
-- Order: guildmates, then higher score, then more ratings, then owner name.
-- Without isGuildmate nobody is a guildmate; without rank everyone ranks 0, 0.
function M.list(b, opts)
  opts = opts or {}
  local entries = {}
  for _, view in pairs(b.stands) do
    if listed(view, opts.now)
      and (opts.kind == nil or view.kind == opts.kind)
      and (opts.faction == nil or view.faction == opts.faction)
      and (opts.zone == nil or view.zone == opts.zone)
      and (opts.statuses == nil or opts.statuses[view.status] == true) then
      -- Ask once per stand here, so the sort does not call back into rating
      -- code on every comparison.
      local score, count = 0, 0
      if opts.rank then
        score, count = opts.rank(view.owner)
      end
      entries[#entries + 1] = {
        view = view,
        guild = opts.isGuildmate ~= nil and opts.isGuildmate(view.owner) and true or false,
        score = score or 0,
        count = count or 0,
      }
    end
  end

  table.sort(entries, function(a, c)
    if a.guild ~= c.guild then
      return a.guild
    elseif a.score ~= c.score then
      return a.score > c.score
    elseif a.count ~= c.count then
      return a.count > c.count
    elseif a.view.owner ~= c.view.owner then
      return a.view.owner < c.view.owner
    end
    -- An owner has one stand (upsert, M6); the id still keeps the order from
    -- ever depending on pairs().
    return a.view.standId < c.view.standId
  end)

  local out = {}
  for i, entry in ipairs(entries) do
    out[i] = entry.view
  end
  return out
end

ns.Board = M
