-- A missing string shows its own key on screen (Locale falls back to the key),
-- which a window test would only see if it happened to look at that text. This
-- reads the UI sources and checks that every key they ask for exists.
local FILES = {
  "Widgets", "MainWindow", "StandList", "MyStand", "Clicking", "History", "MinimapButton",
  "Dialogs", "GuardPanel", "ArrivalWindow", "ShiftEndWindow", "SimControls",
}

local function source(name)
  local f = assert(io.open("Taxi/UI/" .. name .. ".lua", "rb"))
  local text = f:read("*a")
  f:close()
  return text
end

describe("UI strings", function()
  local L

  before_each(function() L = Taxi.load().L end)

  it("has every key the windows name", function()
    local missing, found = {}, 0
    local function need(key, where)
      if key:sub(-1) == "_" then
        return -- the start of a key built from a state; the next test lists those
      end
      found = found + 1
      if rawget(L, key) == nil then
        missing[#missing + 1] = where .. ": " .. key
      end
    end
    for _, name in ipairs(FILES) do
      local text = source(name)
      for key in text:gmatch("[^%w_.]L%.([A-Z][A-Z0-9_]+)") do need(key, name) end
      for key in text:gmatch('L%.fmt%("([%w_]+)"') do need(key, name) end
      for key in text:gmatch('and "([A-Z][A-Z0-9_]+)" or "[A-Z][A-Z0-9_]+"') do need(key, name) end
      for key in text:gmatch('and "[A-Z][A-Z0-9_]+" or "([A-Z][A-Z0-9_]+)"') do need(key, name) end
      for key in text:gmatch('label = "([A-Z][A-Z0-9_]+)"') do need(key, name) end
      for key in text:gmatch('{ "([A-Z][A-Z0-9_]+)", "%l+" }') do need(key, name) end -- the sim's buttons
    end
    assert.is_true(found > 100, "the scan found only " .. found .. " keys") -- it is reading the files
    assert.are.same({}, missing)
  end)

  it("has a line for every state a ride, rider, outcome and portal can show", function()
    local keys = {}
    for _, state in ipairs({ "requested", "accepted", "grouped", "summoning", "portal", "arrived" }) do
      keys[#keys + 1] = "RIDE_" .. state
    end
    for _, state in ipairs({ "accepted", "grouped", "summoning", "portal" }) do
      keys[#keys + 1] = "RIDER_" .. state
    end
    for _, outcome in ipairs({ "arrived", "declined", "cancelled", "shift" }) do
      keys[#keys + 1] = "OUTCOME_" .. outcome
    end
    for _, level in ipairs({ "GREEN", "YELLOW", "RED" }) do
      keys[#keys + 1] = "GUARD_TITLE_" .. level
    end
    for _, role in ipairs({ "traveler_summon", "traveler_portal", "provider_summon", "provider_portal", "clicker" }) do
      keys[#keys + 1] = "HISTORY_" .. role
    end
    local config = Taxi.load().Config
    for _, portal in ipairs(config.PORTALS) do
      keys[#keys + 1] = "PORTAL_" .. portal.key:upper()
    end
    local missing = {}
    for _, key in ipairs(keys) do
      if rawget(L, key) == nil then missing[#missing + 1] = key end
    end
    assert.are.same({}, missing)
  end)

  it("explains the reasons the Engine's actions return that a window can meet", function()
    local codes = {
      "disabled", "dead", "unknown_stand", "bad_offer", "bad_dest", "pending", "instance", "already_open",
      "bad_kind", "not_warlock", "low_level", "no_portals", "bad_seats", "bad_pct", "bad_note", "no_position",
      "unknown_ride", "full", "needs_raid", "no_trade", "unknown_clicker", "no_stand", "is_owner", "not_in_group",
      "already_crew", "seated", "own_stand", "mage", "on_shift", "over_share", "no_offer", "not_on_shift",
      -- the arrival and shift-end windows
      "zero", "too_much", "not_arrived", "bad_stars", "no_rating_for_portals", "unknown_shift", "no_window",
    }
    local missing = {}
    for _, code in ipairs(codes) do
      if rawget(L, "ERR_" .. code) == nil then missing[#missing + 1] = code end
    end
    assert.are.same({}, missing)
  end)
end)
