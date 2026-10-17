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

-- Stores `view` (replacing the entry with the same standId) and stamps its
-- changedAt: `now` for a new stand or one that has moved, otherwise the earlier
-- entry's changedAt carried forward.
function M.upsert(b, view, now)
  local previous = b.stands[view.standId]
  if previous ~= nil and samePlace(previous, view) then
    view.changedAt = previous.changedAt
  else
    view.changedAt = now
  end
  view.seenAt = view.seenAt or now
  b.stands[view.standId] = view
end

function M.remove(b, standId)
  b.stands[standId] = nil
end

function M.get(b, standId)
  return b.stands[standId]
end

-- Drops every stand not heard from for more than STAND_TTL seconds.
function M.expire(b, now)
  for standId, view in pairs(b.stands) do
    if now - view.seenAt > ns.Config.STAND_TTL then
      b.stands[standId] = nil
    end
  end
end

-- The stands matching `opts`, best first. `opts`:
--   kind, faction  keep only this kind / faction when given
--   zone           keep only stands in exactly this zone when given
--   isGuildmate    function(owner) -> bool; guildmates sort first
--   rank           function(owner) -> score, count
-- Order: guildmates, then higher score, then more ratings, then owner name.
-- Without isGuildmate nobody is a guildmate; without rank everyone ranks 0, 0.
function M.list(b, opts)
  opts = opts or {}
  local entries = {}
  for _, view in pairs(b.stands) do
    if (opts.kind == nil or view.kind == opts.kind)
      and (opts.faction == nil or view.faction == opts.faction)
      and (opts.zone == nil or view.zone == opts.zone) then
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
    -- One owner with two stands (a new one heard before the old one expired).
    return a.view.standId < c.view.standId
  end)

  local out = {}
  for i, entry in ipairs(entries) do
    out[i] = entry.view
  end
  return out
end

ns.Board = M
