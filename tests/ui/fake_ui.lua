-- luacheck: ignore 212/self (fake methods that ignore their frame)
-- A strict fake of the frame API Taxi's windows use, to run Taxi/UI/*.lua on a
-- PC. Strict means a method the windows call that is not defined here raises
-- "attempt to call method 'X' (a nil value)", so a typo in a window fails a
-- test instead of the game. It does not prove the real API behaves this way
-- (the in-game checklist does that); it pins the windows' own logic.
--
--   local ui = FakeUI.new()
--   ui.load(ns)                       -- runs Taxi/UI/*.lua in TOC order with this API as globals
--   ui:click(button)                  -- OnClick (a disabled button ignores it), then PostClick hooks
--   ui:visible(frame)                 -- shown, and so is every parent
--   ui:find{kind = "Button", text = "Request"}   -- visible frames matching every given field
--
-- A frame made from SecureActionButtonTemplate is protected, and so are the
-- frames it hangs from (its parents and what it is anchored to): changing one
-- of them with a protected function (Show, Hide, SetPoint, SetEnabled,
-- SetAttribute, StartMoving ...) during ui.combat raises, as the game does
-- (ADDON_ACTION_BLOCKED). The tests must therefore keep to what combat allows.
local M = {}

local UI_FILES = {
  "Widgets.lua", "MainWindow.lua", "StandList.lua", "MyStand.lua", "Clicking.lua", "History.lua", "MinimapButton.lua",
}

function M.new()
  local ui = {
    frames = {}, -- every frame made, in order
    combat = false,
    cursor = { 0, 0 },
    casts = {}, -- spells a secure button cast: { spell, unit }
    tooltip = { lines = {}, shown = false },
    prints = {},
  }

  local function checkText(text)
    local t = type(text)
    if t ~= "string" and t ~= "number" then
      error("SetText wants a string, got " .. t, 3)
    end
    return tostring(text)
  end

  -- Fonts strings and textures ----------------------------------------------------------------

  local Region = {}
  Region.__index = Region
  function Region:SetText(text) self.text = checkText(text) end
  function Region:GetText() return self.text or "" end
  function Region:SetTextColor(r, g, b) self.color = { r, g, b } end
  function Region:SetJustifyH(where) self.justify = where end
  function Region:SetWordWrap(on) self.wrap = on end
  function Region:SetWidth(w) self.width = w end
  function Region:SetSize(w, h) self.width, self.height = w, h end
  function Region:SetPoint(...) self.points = self.points or {}; self.points[#self.points + 1] = { ... } end
  function Region:ClearAllPoints() self.points = {} end
  function Region:SetAllPoints() end
  function Region:SetColorTexture(r, g, b, a) self.rgba = { r, g, b, a } end
  function Region:SetTexture(file) self.file = file end
  function Region:Show() self.shown = true end
  function Region:Hide() self.shown = false end
  function Region:SetShown(on) self.shown = on and true or false end
  function Region:IsShown() return self.shown end

  -- Frames, buttons, edit boxes ------------------------------------------------------------------

  local Frame = {}
  Frame.__index = Frame

  local function protectedNow(self)
    if (self.protected or self.implicit) and ui.combat then
      error("ADDON_ACTION_BLOCKED: a protected frame was changed in combat", 3)
    end
  end

  -- The frames a protected frame hangs from are protected too.
  local function hangFrom(frame)
    while frame and frame.name ~= "UIParent" do
      frame.implicit = true
      frame = frame.parent
    end
  end

  function Frame:SetPoint(point, relative, ...)
    protectedNow(self)
    if self.protected and type(relative) == "table" then
      hangFrom(relative)
    end
    self.points = self.points or {}
    self.points[#self.points + 1] = { point, relative, ... }
  end
  function Frame:ClearAllPoints() protectedNow(self); self.points = {} end
  function Frame:SetAllPoints() protectedNow(self) end
  function Frame:SetSize(w, h) protectedNow(self); self.width, self.height = w, h end
  function Frame:SetWidth(w) protectedNow(self); self.width = w end
  function Frame:SetHeight(h) protectedNow(self); self.height = h end
  function Frame:GetWidth() return self.width or 0 end
  function Frame:Show()
    protectedNow(self)
    local was = self.shown
    self.shown = true
    if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
  end
  function Frame:Hide()
    protectedNow(self)
    local was = self.shown
    self.shown = false
    if was and self.scripts.OnHide then self.scripts.OnHide(self) end
  end
  function Frame:SetShown(on) if on then self:Show() else self:Hide() end end
  function Frame:IsShown() return self.shown end
  function Frame:SetText(text) self.text = checkText(text) end
  function Frame:GetText() return self.text or "" end
  function Frame:SetEnabled(on) protectedNow(self); self.enabled = on and true or false end
  function Frame:SetScript(name, fn) self.scripts[name] = fn end
  function Frame:HookScript(name, fn)
    self.hooks[name] = self.hooks[name] or {}
    table.insert(self.hooks[name], fn)
  end
  function Frame:RegisterForClicks(...) protectedNow(self); self.clicks = { ... } end
  function Frame:RegisterForDrag(...) self.drags = { ... } end
  function Frame:RegisterEvent(event) self.events[event] = true end
  function Frame:EnableMouse() protectedNow(self) end
  function Frame:EnableMouseWheel() protectedNow(self) end
  function Frame:SetMovable() end
  function Frame:StartMoving() protectedNow(self); self.moving = true end
  function Frame:StopMovingOrSizing() protectedNow(self); self.moving = false end
  function Frame:SetClampedToScreen() protectedNow(self) end
  function Frame:SetToplevel() protectedNow(self) end
  function Frame:SetFrameStrata() protectedNow(self) end
  function Frame:SetFrameLevel() protectedNow(self) end
  function Frame:SetHighlightTexture() end
  function Frame:SetAttribute(name, value)
    protectedNow(self)
    self.attributes[name] = value
  end
  function Frame:GetAttribute(name) return self.attributes[name] end
  function Frame:SetAutoFocus() end
  function Frame:SetNumeric(on) self.numeric = on end
  function Frame:SetMaxLetters(n) self.maxLetters = n end
  function Frame:GetNumber() return tonumber(self.text) or 0 end
  function Frame:ClearFocus() end
  function Frame:GetCenter() return 500, 400 end
  function Frame:GetEffectiveScale() return 1 end
  function Frame:CreateFontString(_, _, font)
    local fs = setmetatable({ parent = self, kind = "FontString", font = font, shown = true }, Region)
    table.insert(ui.frames, fs)
    return fs
  end
  function Frame:CreateTexture()
    local tex = setmetatable({ parent = self, kind = "Texture", shown = true }, Region)
    table.insert(ui.frames, tex)
    return tex
  end

  local env = setmetatable({}, { __index = _G })
  ui.env = env

  function env.CreateFrame(kind, name, parent, template)
    local f = setmetatable({
      kind = kind, name = name, parent = parent, template = template or "",
      shown = true, enabled = true, scripts = {}, hooks = {}, events = {}, attributes = {},
    }, Frame)
    f.protected = f.template:find("SecureActionButtonTemplate", 1, true) ~= nil
    if f.protected then
      hangFrom(parent)
    end
    if f.template:find("BasicFrameTemplate", 1, true) then
      f.TitleText = f:CreateFontString()
      f.CloseButton = env.CreateFrame("Button", nil, f)
    end
    if name then
      env[name] = f
    end
    table.insert(ui.frames, f)
    return f
  end

  env.UIParent = env.CreateFrame("Frame", "UIParent")
  env.Minimap = env.CreateFrame("Frame", "Minimap", env.UIParent)
  env.Minimap.width = 140
  env.UISpecialFrames = {}
  env.date = os.date
  env.print = function(text) ui.prints[#ui.prints + 1] = text end
  env.InCombatLockdown = function() return ui.combat end
  env.UnitAffectingCombat = function() return ui.combat end
  env.GetCursorPosition = function() return ui.cursor[1], ui.cursor[2] end
  env.GameTooltip = {
    SetOwner = function(_, owner) ui.tooltip.owner = owner; ui.tooltip.lines = {} end,
    SetText = function(_, text) table.insert(ui.tooltip.lines, text) end,
    AddLine = function(_, text) table.insert(ui.tooltip.lines, text) end,
    Show = function() ui.tooltip.shown = true end,
    Hide = function() ui.tooltip.shown = false end,
  }

  -- Loading, driving and looking --------------------------------------------------------------

  -- Runs Taxi/UI/*.lua into `ns` the way the game does, with this API as their globals.
  function ui.load(ns)
    for _, file in ipairs(UI_FILES) do
      local chunk = assert(loadfile("Taxi/UI/" .. file))
      setfenv(chunk, env)
      chunk("Taxi", ns)
    end
  end

  function ui:visible(frame)
    while frame do
      if not frame.shown then
        return false
      end
      frame = frame.parent
    end
    return true
  end

  -- The visible frames that have every field of `want` (kind, text, name, ...).
  function ui:find(want)
    local out = {}
    for _, f in ipairs(self.frames) do
      local ok = self:visible(f)
      for k, v in pairs(want) do
        ok = ok and (k == "text" and f.GetText and f:GetText() or f[k]) == v
      end
      if ok then
        out[#out + 1] = f
      end
    end
    return out
  end

  -- The one visible frame matching, or an error saying how many there were.
  function ui:one(want)
    local found = self:find(want)
    if #found ~= 1 then
      local parts = {}
      for k, v in pairs(want) do parts[#parts + 1] = k .. "=" .. tostring(v) end
      error(#found .. " visible frames match " .. table.concat(parts, ", "), 2)
    end
    return found[1]
  end

  function ui:fire(frame, script, ...)
    if frame.scripts[script] then
      frame.scripts[script](frame, ...)
    end
    for _, hook in ipairs(frame.hooks[script] or {}) do
      hook(frame, ...)
    end
  end

  -- A click: nothing on a disabled button. A secure button first does what its
  -- attributes say, as the game would (a spell cast is recorded in ui.casts).
  function ui:click(button)
    assert(self:visible(button), "clicked a button that is not visible")
    if button.enabled == false then
      return false
    end
    if button.protected and button.attributes.type == "spell" then
      self.casts[#self.casts + 1] = { spell = button.attributes.spell, unit = button.attributes.unit }
    end
    if button.scripts.OnClick then
      button.scripts.OnClick(button, "LeftButton", false)
    end
    for _, hook in ipairs(button.hooks.PostClick or {}) do
      hook(button, "LeftButton", false)
    end
    return true
  end

  -- Clicks the visible button with this text.
  function ui:press(text)
    return self:click(self:one{ kind = "Button", text = text })
  end

  -- A game event for every frame registered for it.
  function ui:event(event, ...)
    for _, f in ipairs(self.frames) do
      if f.events and f.events[event] and f.scripts.OnEvent then
        f.scripts.OnEvent(f, event, ...)
      end
    end
  end

  -- Frames' OnUpdate for `elapsed` seconds, on the visible ones.
  function ui:update(elapsed)
    for _, f in ipairs(self.frames) do
      if f.scripts and f.scripts.OnUpdate and self:visible(f) then
        f.scripts.OnUpdate(f, elapsed)
      end
    end
  end

  -- The texts of the visible font strings and buttons, in creation order.
  function ui:texts()
    local out = {}
    for _, f in ipairs(self.frames) do
      if (f.kind == "FontString" or f.kind == "Button") and self:visible(f) and f:GetText() ~= "" then
        out[#out + 1] = f:GetText()
      end
    end
    return out
  end

  -- Whether any visible text contains `needle` (plain).
  function ui:shows(needle)
    for _, text in ipairs(self:texts()) do
      if text:find(needle, 1, true) then
        return true
      end
    end
    return false
  end

  return ui
end

return M
