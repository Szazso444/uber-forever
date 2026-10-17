local _, ns = ...

-- Player-facing strings (English). Later tasks add their keys to this table.
-- ns.L[key] reads a string; a missing key falls back to the key itself so a
-- gap shows up on screen instead of raising an error in a UI handler.
-- ns.L.fmt(key, ...) is string.format(ns.L[key], ...).
local M = {}

function M.fmt(key, ...)
  return string.format(M[key], ...)
end

setmetatable(M, {
  __index = function(_, key)
    return key
  end,
})

ns.L = M
