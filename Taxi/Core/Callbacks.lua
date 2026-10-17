local _, ns = ...

-- A tiny event emitter. Each emitter keeps its own handlers.
--   local cb = ns.Callbacks.new()
--   local token = cb:on("EVENT", function(...) end)
--   cb:emit("EVENT", ...)
--   cb:off(token)
local M = {}

local Callbacks = {}
Callbacks.__index = Callbacks

function M.new()
  return setmetatable({
    handlers = {}, -- event -> ordered list of { token = n, fn = f }
    eventOf = {}, -- token -> event
    lastToken = 0,
  }, Callbacks)
end

function Callbacks:on(event, fn)
  self.lastToken = self.lastToken + 1
  local token = self.lastToken
  local list = self.handlers[event]
  if not list then
    list = {}
    self.handlers[event] = list
  end
  list[#list + 1] = { token = token, fn = fn }
  self.eventOf[token] = event
  return token
end

-- Unknown or already-removed tokens are ignored.
function Callbacks:off(token)
  local event = self.eventOf[token]
  if not event then
    return
  end
  self.eventOf[token] = nil
  local list = self.handlers[event]
  for i = 1, #list do
    if list[i].token == token then
      table.remove(list, i)
      break
    end
  end
end

-- Handlers run in registration order. Handlers added or removed while an
-- emit is running do not disturb it: it runs the handlers that were
-- registered when it began and skips any removed before their turn.
function Callbacks:emit(event, ...)
  local list = self.handlers[event]
  if not list then
    return
  end
  local snapshot = {}
  for i = 1, #list do
    snapshot[i] = list[i]
  end
  for i = 1, #snapshot do
    local handler = snapshot[i]
    if self.eventOf[handler.token] then
      handler.fn(...)
    end
  end
end

ns.Callbacks = M
