local _, ns = ...

-- Player names. On WoW Forever a player is their full two-part name (first
-- name + surname); only the whole combination is unique. Names are compared
-- as exact strings after tidying whitespace, never by first name alone.
local M = {}

-- Trim the ends and collapse inner runs of whitespace to one space. Nothing
-- else changes: no lowercasing, no realm stripping. Returns nil when name is
-- not a string.
function M.normalize(name)
  local trimmed = ns.Util.trim(name)
  if trimmed == nil then
    return nil
  end
  return (trimmed:gsub("%s+", " "))
end

-- True only when both names are real and identical after normalizing. A
-- missing or blank name matches nothing, itself included: the Summon Guard
-- relies on this to refuse an unidentified summoner.
function M.same(a, b)
  local na, nb = M.normalize(a), M.normalize(b)
  if na == nil or nb == nil or na == "" then
    return false
  end
  return na == nb
end

ns.Names = M
