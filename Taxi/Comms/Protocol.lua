local _, ns = ...

-- The versioned wire format every Taxi client speaks. Pure text in, pure text
-- out: no WoW API, no transport (chunking and sending live in Comms/Transport).
--
--   1^TYPE^msgId^field1^field2^...
--
-- The fields follow the schema of TYPE in order, so the order is part of the
-- format. Every field is present. Field kinds:
--   s  string (empty decodes to nil)
--   n  number (empty decodes to nil; tostring/tonumber, so integers and map
--      coordinates survive)
--   L  list of strings, items joined with "," (empty decodes to {})
--   R  list of records, records joined with ";", record fields (M.RECORD)
--      joined with "," (empty decodes to {})
-- The characters % ^ , ; | and newline never appear raw inside a value: they
-- are written as %25 %5E %2C %3B %7C %0A. ("|" is WoW's chat escape.)
--
-- Messages come from untrusted players. decode never raises: anything that is
-- not exactly a well-formed message of this version is refused with a reason.
local M = {}

M.VERSION = ns.Config.PROTOCOL

local STAND_ID = { { "standId", "s" } }
local RIDE_WARLOCK = { { "rideId", "s" }, { "warlock", "s" } }
local RIDE_AMOUNT = { { "rideId", "s" }, { "amount", "n" } }

M.SCHEMAS = {
  STAND = {
    { "standId", "s" }, { "kind", "s" }, { "faction", "s" },
    { "mapID", "n" }, { "x", "n" }, { "y", "n" }, { "wx", "n" }, { "wy", "n" },
    { "zone", "s" }, { "subzone", "s" },
    { "seatsFree", "n" }, { "clickers", "n" }, { "clickerPct", "n" },
    { "portals", "L" }, { "note", "s" }, { "status", "s" },
  },
  STAND_END = STAND_ID,
  REQUEST = { { "standId", "s" }, { "offer", "n" }, { "level", "n" }, { "dest", "s" } },
  ACCEPT = { { "rideId", "s" }, { "standId", "s" } },
  DECLINE = { { "standId", "s" }, { "reason", "s" } },
  CLICK_APPLY = { { "standId", "s" }, { "askedPct", "n" } },
  CLICK_OFFER = { { "standId", "s" }, { "offeredPct", "n" } },
  CLICK_OK = { { "standId", "s" }, { "agreedPct", "n" } },
  CLICK_NO = STAND_ID,
  CLICK_LEAVE = STAND_ID,
  RIDE_START = RIDE_WARLOCK,
  ARRIVED = RIDE_WARLOCK,
  RIDE_LOG = { { "rideId", "s" }, { "traveler", "s" } },
  RATING = {
    { "kind", "s" }, { "target", "s" }, { "stars", "n" }, { "id", "s" },
    { "ts", "n" }, { "owed", "n" }, { "received", "n" }, { "pct", "n" },
  },
  DEATH = {
    { "rideId", "s" }, { "victim", "s" }, { "warlock", "s" }, { "secs", "n" }, { "source", "s" },
  },
  TIP = RIDE_AMOUNT,
  TIP_ACK = RIDE_AMOUNT,
  PORTAL_UP = { { "dest", "s" } },
  QUERY = { { "target", "s" } },
  QUERY_R = { { "target", "s" }, { "records", "R" } },
}

-- A rating record in a QUERY_R reply. `kind` is "trust", "share", "death" or
-- "ridelog"; `other` is the victim of a death or the traveler of a ride log.
local RECORD_FIELDS = {
  { "kind", "s" }, { "rater", "s" }, { "stars", "n" }, { "id", "s" }, { "ts", "n" },
  { "owed", "n" }, { "received", "n" }, { "pct", "n" }, { "other", "s" },
}

M.RECORD = {}
for i, field in ipairs(RECORD_FIELDS) do
  M.RECORD[i] = field[1]
end

local FIELD_SEP, LIST_SEP, RECORD_SEP = "^", ",", ";"

local ESCAPE = {
  ["%"] = "%25", ["^"] = "%5E", [","] = "%2C", [";"] = "%3B", ["|"] = "%7C", ["\n"] = "%0A",
}
local UNESCAPE = {
  ["25"] = "%", ["5E"] = "^", ["2C"] = ",", ["3B"] = ";", ["7C"] = "|", ["0A"] = "\n",
}

local function isFinite(n)
  return type(n) == "number" and n == n and n ~= math.huge and n ~= -math.huge
end

-- Encoding --------------------------------------------------------------------

local function escape(s)
  return (s:gsub("[%%%^,;|\n]", ESCAPE))
end

local function fail(msgType, name, part)
  error("bad field " .. msgType .. "." .. name .. (part and ("." .. part) or ""), 0)
end

-- One "s" or "n" value. nil is an empty field.
local function encodeScalar(value, kind, msgType, name, part)
  if value == nil then
    return ""
  elseif kind == "s" and type(value) == "string" then
    return escape(value)
  elseif kind == "n" and isFinite(value) then
    return tostring(value)
  end
  fail(msgType, name, part)
end

local function encodeRecord(record, msgType, name)
  if type(record) ~= "table" then
    fail(msgType, name)
  end
  local parts = {}
  for i, field in ipairs(RECORD_FIELDS) do
    parts[i] = encodeScalar(record[field[1]], field[2], msgType, name, field[1])
  end
  return table.concat(parts, LIST_SEP)
end

local function encodeField(value, kind, msgType, name)
  if kind == "L" or kind == "R" then
    if value == nil then
      return ""
    elseif type(value) ~= "table" then
      fail(msgType, name)
    end
    local parts = {}
    for i, item in ipairs(value) do
      if kind == "L" then
        parts[i] = encodeScalar(item, "s", msgType, name)
      else
        parts[i] = encodeRecord(item, msgType, name)
      end
    end
    return table.concat(parts, kind == "L" and LIST_SEP or RECORD_SEP)
  end
  return encodeScalar(value, kind, msgType, name)
end

-- encode(type, msgId, fields) -> wire text. `fields` is a table keyed by the
-- schema's field names; nil fields are sent empty and unknown keys are ignored.
-- Raises on an unknown type, an unusable msgId, or a field of the wrong type
-- (a bug in the caller, never something a remote player can cause).
function M.encode(msgType, msgId, fields)
  local schema = M.SCHEMAS[msgType]
  if not schema then
    error("unknown type", 0)
  end
  if fields == nil then
    fields = {}
  elseif type(fields) ~= "table" then
    error("bad fields " .. msgType, 0)
  end
  if not ((type(msgId) == "string" and msgId ~= "") or isFinite(msgId)) then
    error("bad msgId " .. msgType, 0)
  end

  local parts = { tostring(M.VERSION), msgType, escape(tostring(msgId)) }
  for _, field in ipairs(schema) do
    parts[#parts + 1] = encodeField(fields[field[1]], field[2], msgType, field[1])
  end
  return table.concat(parts, FIELD_SEP)
end

-- Decoding --------------------------------------------------------------------

-- Splits on a one-character separator and keeps empty pieces, trailing ones
-- included: "a^^" is {"a", "", ""}. Returns the pieces and their count.
local function split(text, sep)
  local pieces, count = {}, 0
  for piece in (text .. sep):gmatch("([^%" .. sep .. "]*)%" .. sep) do
    count = count + 1
    pieces[count] = piece
  end
  return pieces, count
end

-- Undoes escape(). Only the six escapes this module writes are accepted, in
-- upper case; any other "%" is not a valid message, so nil.
local function unescape(text)
  local bad = false
  local out = text:gsub("%%(.?.?)", function(code)
    local char = UNESCAPE[code]
    if not char then
      bad = true
      return ""
    end
    return char
  end)
  if bad then
    return nil
  end
  return out
end

-- Plain decimal numbers only, as tostring writes them (digits, ".", exponent,
-- signs). tonumber alone would also take hex, spaces, "inf" and "nan".
local function decodeNumber(text)
  if text:find("[^%d%.eE%+%-]") then
    return nil
  end
  local n = tonumber(text)
  if not isFinite(n) then
    return nil
  end
  return n
end

-- Returns ok, value. An empty field is ok and nil.
local function decodeScalar(text, kind)
  if text == "" then
    return true, nil
  end
  local value
  if kind == "n" then
    value = decodeNumber(text)
  else
    value = unescape(text)
  end
  return value ~= nil, value
end

local function decodeList(text)
  local pieces, count = split(text, LIST_SEP)
  local list = {}
  for i = 1, count do
    local ok, item = decodeScalar(pieces[i], "s")
    if not ok then
      return false
    end
    if item then
      list[#list + 1] = item
    end
  end
  return true, list
end

local function decodeRecords(text)
  local segments, segmentCount = split(text, RECORD_SEP)
  local records = {}
  for i = 1, segmentCount do
    if segments[i] ~= "" then
      local pieces, count = split(segments[i], LIST_SEP)
      if count ~= #RECORD_FIELDS then
        return false
      end
      local record = {}
      for j, field in ipairs(RECORD_FIELDS) do
        local ok, value = decodeScalar(pieces[j], field[2])
        if not ok then
          return false
        end
        record[field[1]] = value
      end
      -- A record with every field empty says nothing, so it is dropped.
      if next(record) ~= nil then
        records[#records + 1] = record
      end
    end
  end
  return true, records
end

local function decodeField(text, kind)
  if kind == "L" then
    return decodeList(text)
  elseif kind == "R" then
    return decodeRecords(text)
  end
  return decodeScalar(text, kind)
end

-- decode(text) -> msg, or nil plus a reason:
--   "malformed"     not a well-formed message (wrong field count, bad escape,
--                   bad number, missing msgId, not a string at all)
--   "version"       another protocol version; the third result is that version
--   "unknown_type"  a type this client does not know
-- msg is {v, type, msgId, <field> = value}. Numbers are numbers. An empty s or
-- n field is nil, but an L or R field is always a table, {} when it is empty,
-- so a handler can ipairs it without a nil check.
function M.decode(text)
  if type(text) ~= "string" then
    return nil, "malformed"
  end
  local parts, count = split(text, FIELD_SEP)

  -- Any other version may lay its fields out differently, so it is reported
  -- as such before anything after the version is looked at.
  local versionText = parts[1]
  if #versionText > 9 or not versionText:find("^%d+$") then
    return nil, "malformed"
  end
  local version = tonumber(versionText)
  if version ~= M.VERSION then
    return nil, "version", version
  end

  if count < 2 then
    return nil, "malformed"
  end
  local msgType = parts[2]
  local schema = M.SCHEMAS[msgType]
  if not schema then
    return nil, "unknown_type"
  end
  if count ~= 3 + #schema then
    return nil, "malformed"
  end
  local msgId = unescape(parts[3])
  if msgId == nil or msgId == "" then
    return nil, "malformed"
  end

  local msg = { v = version, type = msgType, msgId = msgId }
  for i, field in ipairs(schema) do
    local ok, value = decodeField(parts[3 + i], field[2])
    if not ok then
      return nil, "malformed"
    end
    msg[field[1]] = value
  end
  return msg
end

ns.Protocol = M
