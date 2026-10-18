local _, ns = ...

-- Building blocks the Taxi windows share: text that is safe to show, trust and
-- share lines, buttons, edit boxes, the 1-5 stars, a pop-up menu and dropdown,
-- a paged list of rows and a gold/silver input. They use only Blizzard
-- templates that Forever has (UIPanelButtonTemplate, InputBoxTemplate,
-- UIPanelScrollUpButtonTemplate) and no UIDropDownMenu or MenuUtil: a menu that
-- an addon builds from those spreads taint into Blizzard's secure menus, and a
-- menu made here is a plain frame.
--
-- Text that came off the wire (names, zones, notes) can hold "|", which the
-- game reads as the start of a colour or link code, and control characters
-- (a newline would add a line to a row and could forge one, say a trust line).
-- Everything a list row or setText shows goes through W.escape, so no window
-- can forget it (R14, R57).
local L, Config, Money = ns.L, ns.Config, ns.Money

local UI = ns.UI or {}
ns.UI = UI
local W = {}
UI.Widgets = W

W.STAR = "★" -- U+2605; verify in game (Task 19), swap this one line if the font lacks it
-- The Summon Guard's lines start with these. Plain game fonts may lack them
-- (the lines are also coloured, so a missing glyph costs looks, not meaning);
-- verify in game (Task 19) and swap these two lines if need be.
W.CHECK = "✓" -- U+2713
W.CROSS = "✗" -- U+2717

W.COLOR = {
  gold = { 1, 0.82, 0 },
  white = { 1, 1, 1 },
  green = { 0.3, 1, 0.3 },
  red = { 1, 0.35, 0.3 },
  gray = { 0.6, 0.6, 0.6 },
}

-- Text -----------------------------------------------------------------------------

-- Text safe to show: every ASCII control character becomes a space and "|"
-- becomes "||". The class is spelled out (NUL, 1-31, DEL) instead of %c, which
-- in some locales also matches bytes 0x80-0x9F and would eat the middle of
-- UTF-8 glyphs such as ★ ⚠ → (R59).
function W.escape(text)
  local plain = tostring(text == nil and "" or text):gsub("[%z\1-\31\127]", " ")
  return (plain:gsub("|", "||"))
end

-- Sets the text of a font string or button; the text is escaped.
function W.setText(target, text)
  target:SetText(W.escape(text))
end

-- A font string on parent. font is a game font object name.
function W.text(parent, font, justify)
  local fs = parent:CreateFontString(nil, "ARTWORK", font or "GameFontHighlightSmall")
  fs:SetJustifyH(justify or "LEFT")
  fs:SetWordWrap(false)
  return fs
end

function W.paint(fs, color)
  local c = color or W.COLOR.white
  fs:SetTextColor(c[1], c[2], c[3])
end

-- A destination's display name ("stormwind" -> "Stormwind").
function W.portalName(key)
  return rawget(L, "PORTAL_" .. tostring(key):upper()) or tostring(key)
end

-- "Stormwind, Ironforge" for a list of portal keys.
function W.portalNames(keys)
  local names = {}
  for _, key in ipairs(keys or {}) do
    names[#names + 1] = W.portalName(key)
  end
  return table.concat(names, ", ")
end

-- Where a stand is: "Tanaris - Gadgetzan" (just the zone when there is no subzone).
function W.place(stand)
  local zone = tostring(stand.zone or "")
  if stand.subzone == nil or stand.subzone == "" then
    return zone
  end
  return L.fmt("LOCATION", zone, stand.subzone)
end

-- The trust rating of a warlock (Ratings.summary(..., "trust")) as the line
-- "★ 4.8 · 137 summons · New" and, when deaths were reported, the warning
-- "⚠ 2 reported deaths" (nil otherwise).
function W.trustLine(summary)
  local text
  if summary.stars == nil then
    text = L.TRUST_NONE
  else
    local count = summary.count == 1 and L.TRUST_COUNT_ONE or L.fmt("TRUST_COUNT_MANY", summary.count)
    text = L.fmt("TRUST_LINE", summary.stars, count)
    if summary.isNew then
      text = text .. " · " .. L.TRUST_NEW
    end
  end
  local warn
  local deaths = summary.deathsReported or 0
  if deaths == 1 then
    warn = L.DEATHS_ONE
  elseif deaths > 1 then
    warn = L.fmt("DEATHS_MANY", deaths)
  end
  return text, warn
end

-- The Share rating (Ratings.summary(..., "share")) as "Share ★ 4.2 · 12 shifts · New".
function W.shareLine(summary)
  if summary.stars == nil then
    return L.SHARE_NONE
  end
  local count = summary.count == 1 and L.SHARE_COUNT_ONE or L.fmt("SHARE_COUNT_MANY", summary.count)
  local text = L.fmt("SHARE_LINE", summary.stars, count)
  if summary.isNew then
    text = text .. " · " .. L.TRUST_NEW
  end
  return text
end

-- Controls -----------------------------------------------------------------------------

-- A push button. onClick(button) runs on a click; assign button.onClick to
-- change what it does (a recycled row's button).
function W.button(parent, text, width, onClick)
  local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
  b:SetSize(width or 100, 22)
  W.setText(b, text)
  b.onClick = onClick
  b:SetScript("OnClick", function(self, ...)
    if self.onClick then
      self.onClick(self, ...)
    end
  end)
  return b
end

-- A one-line edit box. opts: numeric, maxLetters.
function W.editBox(parent, width, opts)
  opts = opts or {}
  local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
  box:SetSize(width, 20)
  box:SetAutoFocus(false)
  if opts.numeric then
    box:SetNumeric(true)
  end
  if opts.maxLetters then
    box:SetMaxLetters(opts.maxLetters)
  end
  box:SetScript("OnEnterPressed", function(self)
    self:ClearFocus()
  end)
  return box
end

-- Gold and silver boxes for a copper amount (MoneyInputFrameTemplate is not in
-- Forever). input:GetCopper() is nil for nothing or an unusable amount
-- (Money.fromParts); input:SetCopper(c) fills the boxes; input:Clear().
function W.moneyInput(parent)
  local input = CreateFrame("Frame", nil, parent)
  input:SetSize(110, 22)
  input.gold = W.editBox(input, 56, { numeric = true, maxLetters = 6 })
  input.gold:SetPoint("LEFT", input, "LEFT", 6, 0)
  local g = W.text(input, "GameFontNormalSmall")
  g:SetPoint("LEFT", input.gold, "RIGHT", 3, 0)
  g:SetText("g")
  input.silver = W.editBox(input, 28, { numeric = true, maxLetters = 2 })
  input.silver:SetPoint("LEFT", g, "RIGHT", 8, 0)
  local s = W.text(input, "GameFontNormalSmall")
  s:SetPoint("LEFT", input.silver, "RIGHT", 3, 0)
  s:SetText("s")

  function input:GetCopper()
    return Money.fromParts(self.gold:GetNumber(), self.silver:GetNumber(), 0)
  end
  function input:SetCopper(copper)
    copper = copper or 0
    self.gold:SetText(copper >= 10000 and tostring(math.floor(copper / 10000)) or "")
    local silver = math.floor(copper % 10000 / 100)
    self.silver:SetText(silver > 0 and tostring(silver) or "")
  end
  function input:Clear()
    self.gold:SetText("")
    self.silver:SetText("")
  end
  return input
end

-- The stars -------------------------------------------------------------------------------

local STAR_SIZE = 22

-- Five clickable stars. onPick(n) runs when the player picks n (1 to 5).
-- stars:SetValue(n) fills them without calling onPick (a rating to suggest);
-- stars:GetValue() is 0 until something is picked; stars:SetPickable(false)
-- makes them display only.
function W.stars(parent, onPick)
  local box = CreateFrame("Frame", nil, parent)
  box:SetSize(STAR_SIZE * 5, STAR_SIZE)
  box.value = 0
  box.pickable = true
  box.buttons = {}

  local function paint(upTo)
    for i, b in ipairs(box.buttons) do
      W.paint(b.label, i <= upTo and W.COLOR.gold or W.COLOR.gray)
    end
  end

  for i = 1, 5 do
    local b = CreateFrame("Button", nil, box)
    b:SetSize(STAR_SIZE, STAR_SIZE)
    b:SetPoint("LEFT", box, "LEFT", (i - 1) * STAR_SIZE, 0)
    b.label = b:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    b.label:SetPoint("CENTER", b, "CENTER", 0, 0)
    b.label:SetText(W.STAR)
    b:SetScript("OnClick", function()
      if box.pickable then
        box:SetValue(i)
        if onPick then
          onPick(i)
        end
      end
    end)
    b:SetScript("OnEnter", function()
      if box.pickable then
        paint(i)
      end
    end)
    b:SetScript("OnLeave", function()
      paint(box.value)
    end)
    box.buttons[i] = b
  end

  function box:SetValue(n)
    self.value = n or 0
    paint(self.value)
  end
  function box:GetValue()
    return self.value
  end
  function box:SetPickable(on)
    self.pickable = on ~= false
    for _, b in ipairs(self.buttons) do
      b:EnableMouse(self.pickable)
    end
  end

  paint(0)
  return box
end

-- Pop-up menu and dropdown ---------------------------------------------------------------------

local MENU_ROW = 20
local MENU_MAX = 14 -- entries a menu shows; a longer list is cut here
local menu, catcher

function W.closeMenu()
  if menu then
    menu:Hide()
  end
  if catcher then
    catcher:Hide()
  end
end

local function buildMenu()
  if menu then
    return
  end
  -- A click anywhere else closes the menu: this invisible button covers the screen.
  catcher = CreateFrame("Button", nil, UIParent)
  catcher:SetAllPoints(UIParent)
  catcher:SetFrameStrata("FULLSCREEN_DIALOG")
  catcher:SetFrameLevel(1)
  catcher:SetScript("OnClick", W.closeMenu)
  catcher:Hide()

  menu = CreateFrame("Frame", nil, UIParent)
  menu:SetFrameStrata("FULLSCREEN_DIALOG")
  menu:SetFrameLevel(10)
  menu:EnableMouse(true)
  local bg = menu:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.05, 0.05, 0.08, 0.95)
  menu.items = {}
  for i = 1, MENU_MAX do
    local item = CreateFrame("Button", nil, menu)
    item:SetHeight(MENU_ROW)
    item:SetPoint("TOPLEFT", menu, "TOPLEFT", 4, -4 - (i - 1) * MENU_ROW)
    item:SetPoint("TOPRIGHT", menu, "TOPRIGHT", -4, -4 - (i - 1) * MENU_ROW)
    item.label = W.text(item, "GameFontHighlightSmall")
    item.label:SetPoint("LEFT", item, "LEFT", 4, 0)
    local hl = item:CreateTexture(nil, "HIGHLIGHT")
    hl:SetAllPoints()
    hl:SetColorTexture(1, 1, 1, 0.15)
    item:SetScript("OnClick", function(self)
      local pick = menu.onPick
      W.closeMenu()
      if pick then
        pick(self.value, self.caption)
      end
    end)
    menu.items[i] = item
  end
  menu:Hide()
end

-- Opens a menu of items ({value, text}, ...) under anchor; onPick(value, text)
-- runs for the one picked. Opening it again on the same anchor closes it.
function W.popupMenu(anchor, items, onPick, width)
  buildMenu()
  if menu:IsShown() and menu.anchor == anchor then
    W.closeMenu()
    return
  end
  local n = math.min(#items, MENU_MAX)
  if n == 0 then
    return
  end
  menu.anchor, menu.onPick = anchor, onPick
  menu:ClearAllPoints()
  menu:SetPoint("TOPLEFT", anchor, "BOTTOMLEFT", 0, -2)
  menu:SetSize(width or math.max(anchor:GetWidth(), 120), n * MENU_ROW + 8)
  for i, item in ipairs(menu.items) do
    local entry = i <= n and items[i] or nil
    if entry then
      item.value, item.caption = entry.value, entry.text
      W.setText(item.label, entry.text)
      item:Show()
    else
      item:Hide()
    end
  end
  catcher:Show()
  menu:Show()
end

-- A button that opens a menu. dd:SetItems({{value, text}, ...}); dd:Select(value)
-- shows the item with that value (nil clears); onPick(value) runs when the
-- player picks one.
function W.dropdown(parent, width, onPick)
  local dd = W.button(parent, "", width)
  dd.items = {}
  function dd:SetItems(items)
    self.items = items
  end
  function dd:Select(value)
    self.value = value
    local text = ""
    for _, item in ipairs(self.items) do
      if item.value == value then
        text = item.text
      end
    end
    W.setText(self, text)
  end
  dd.onClick = function(self)
    W.popupMenu(self, self.items, function(value)
      self:Select(value)
      if onPick then
        onPick(value)
      end
    end)
  end
  return dd
end

-- A paged list of rows ----------------------------------------------------------------------------

local ARROW_COLUMN = 22
-- Three lines of text (a 12 pt title, two 10 pt lines) and the gap between rows.
W.ROW_HEIGHT = 48

local function makeRow(list, index)
  local height = list.rowHeight
  local row = CreateFrame("Button", nil, list.frame)
  row:SetSize(list.width - ARROW_COLUMN, height - 2)
  row:SetPoint("TOPLEFT", list.frame, "TOPLEFT", 0, -(index - 1) * height)
  row.bg = row:CreateTexture(nil, "BACKGROUND")
  row.bg:SetAllPoints()
  local hl = row:CreateTexture(nil, "HIGHLIGHT")
  hl:SetAllPoints()
  hl:SetColorTexture(1, 1, 1, 0.07)
  row.title = W.text(row, "GameFontHighlight")
  row.title:SetPoint("TOPLEFT", row, "TOPLEFT", 8, -4)
  row.right = W.text(row, "GameFontHighlightSmall", "RIGHT")
  row.sub = W.text(row, "GameFontHighlightSmall")
  row.sub:SetPoint("TOPLEFT", row.title, "BOTTOMLEFT", 0, -2)
  row.sub2 = W.text(row, "GameFontHighlightSmall")
  row.sub2:SetPoint("TOPLEFT", row.sub, "BOTTOMLEFT", 0, -1)
  row.warn = W.text(row, "GameFontHighlightSmall", "RIGHT")
  if list.edit then
    row.edit = W.editBox(row, 34, { numeric = true, maxLetters = 2 })
  end
  row.buttons = {}
  for b = 1, list.buttons do
    row.buttons[b] = W.button(row, "", 80)
  end
  row:SetScript("OnClick", function(self)
    local spec = self.spec
    if spec and spec.onClick then
      spec.onClick(spec, self)
    end
  end)
  row:Hide()
  return row
end

local function bindRow(row, spec, number)
  row.spec = spec
  -- Buttons are laid out from the right edge; text gets what is left.
  local x = -6
  for b, button in ipairs(row.buttons) do
    local def = spec.buttons and spec.buttons[b]
    if def then
      local width = def.width or 80
      button:SetWidth(width)
      W.setText(button, def.text)
      button:SetEnabled(def.enabled ~= false)
      button.onClick = function()
        def.onClick(spec, row)
      end
      button:ClearAllPoints()
      button:SetPoint("RIGHT", row, "RIGHT", x, 0)
      button:Show()
      x = x - width - 4
    else
      button.onClick = nil
      button:Hide()
    end
  end
  if row.edit then
    if spec.edit then
      if row.editKey ~= spec.edit.key then
        row.edit:SetText(tostring(spec.edit.text or ""))
        row.editKey = spec.edit.key
      end
      row.edit:ClearAllPoints()
      row.edit:SetPoint("RIGHT", row, "RIGHT", x - 4, 0)
      row.edit:Show()
      x = x - 42
    else
      row.edit:Hide()
      row.editKey = nil
    end
  end

  local room = row:GetWidth() - 8 + x - 6 -- width left of the buttons
  local rightWidth = spec.right and math.min(room * 0.45, 170) or 0
  row.title:SetWidth(math.max(room - rightWidth - 4, 20))
  row.sub:SetWidth(math.max(room, 20))
  row.sub2:SetWidth(math.max(room - (spec.warn and 150 or 0), 20))
  row.right:ClearAllPoints()
  row.right:SetPoint("TOPRIGHT", row, "TOPRIGHT", x - 2, -6)
  row.right:SetWidth(math.max(rightWidth, 1))
  row.warn:ClearAllPoints()
  row.warn:SetPoint("TOPRIGHT", row, "TOPRIGHT", x - 2, -33) -- on the third line
  row.warn:SetWidth(145)

  W.setText(row.title, spec.title)
  W.paint(row.title, spec.titleColor or (spec.header and W.COLOR.gold or W.COLOR.white))
  W.setText(row.sub, spec.sub)
  W.setText(row.sub2, spec.sub2)
  W.setText(row.right, spec.right)
  W.paint(row.right, spec.rightColor or W.COLOR.gold)
  W.setText(row.warn, spec.warn)
  W.paint(row.warn, W.COLOR.red)
  if spec.header then
    row.bg:SetColorTexture(0, 0, 0, 0.35)
  elseif spec.selected then
    row.bg:SetColorTexture(1, 0.82, 0, 0.18)
  else
    row.bg:SetColorTexture(1, 1, 1, number % 2 == 0 and 0.05 or 0.02)
  end
  row:Show()
end

-- A list of `rows` rows of `rowHeight`, `width` wide in all (the arrows take
-- 22 of it); `buttons` is the most buttons a row can have, `edit` gives each row
-- a small numeric box left of its buttons. list.frame is the frame to place.
--   list:SetRows(specs)   shows specs, each:
--     title, titleColor, sub, sub2, right, rightColor, warn   texts (escaped here)
--     header                 a section heading: gold, no highlight
--     selected               the highlighted row
--     onClick(spec, row)     a click on the row
--     buttons                {{text, width, enabled, onClick(spec, row)}, ...}, right to left
--     edit                   {key, text}: the box is filled with text when key
--                            differs from the last one shown in that row, so a
--                            number typed by the player survives a refresh
--   list:Scroll(rows)      moves by rows (negative: up); the wheel and arrows do it
function W.list(parent, opts)
  local list = {
    width = opts.width,
    rowHeight = opts.rowHeight or W.ROW_HEIGHT,
    buttons = opts.buttons or 0,
    edit = opts.edit == true,
    visible = opts.rows,
    specs = {},
    offset = 0,
    rows = {},
  }
  local frame = CreateFrame("Frame", nil, parent)
  frame:SetSize(list.width, list.visible * list.rowHeight)
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta)
    list:Scroll(delta > 0 and -1 or 1)
  end)
  list.frame = frame

  list.up = CreateFrame("Button", nil, frame, "UIPanelScrollUpButtonTemplate")
  list.up:SetPoint("TOPRIGHT", frame, "TOPRIGHT", 0, 0)
  list.up:SetScript("OnClick", function()
    list:Scroll(-1)
  end)
  list.down = CreateFrame("Button", nil, frame, "UIPanelScrollDownButtonTemplate")
  list.down:SetPoint("BOTTOMRIGHT", frame, "BOTTOMRIGHT", 0, 0)
  list.down:SetScript("OnClick", function()
    list:Scroll(1)
  end)

  for i = 1, list.visible do
    list.rows[i] = makeRow(list, i)
  end

  function list:Render()
    for i, row in ipairs(self.rows) do
      local spec = self.specs[self.offset + i]
      if spec then
        bindRow(row, spec, self.offset + i)
      else
        row.spec = nil
        row:Hide()
      end
    end
    self.up:SetEnabled(self.offset > 0)
    self.down:SetEnabled(self.offset + self.visible < #self.specs)
  end

  function list:SetRows(specs)
    self.specs = specs
    self.offset = math.min(self.offset, math.max(0, #specs - self.visible))
    self:Render()
  end

  function list:Scroll(rows)
    local offset = math.max(0, math.min(self.offset + rows, #self.specs - self.visible))
    if offset ~= self.offset then
      self.offset = offset
      self:Render()
    end
  end

  return list
end

-- Windows of their own ---------------------------------------------------------------------------

-- Ties a window to one Engine. Engine events reach it only while that engine is
-- the one the UI shows (ns.engine: the real one, or "You" while /taxi sim runs),
-- so a window of the real engine is quiet during the sim and the other way round,
-- unless opts.always is set: such a window acts for another player of the sim.
-- opts.label names that player on the window; opts.slot moves the window a
-- little, so the windows of several players don't hide each other.
--   link:live()         whether events should reach the window now
--   link:on(event, fn)  listens to an Engine event, while live
--   link:dead()         whether this player is a dead Hardcore character (R35)
--   link:detach()       stops listening for good
function W.link(engine, opts)
  opts = opts or {}
  local link = { engine = engine, label = opts.label, slot = opts.slot or 0, always = opts.always == true, tokens = {} }
  function link:live()
    return not self.detached and (self.always or ns.engine == self.engine)
  end
  function link:on(event, fn)
    self.tokens[#self.tokens + 1] = self.engine:on(event, function(...)
      if self:live() then
        fn(...)
      end
    end)
  end
  function link:dead()
    local game = self.engine.game
    return game:isHardcore() == true and game:isDead() == true
  end
  function link:detach()
    self.detached = true
    for _, token in ipairs(self.tokens) do
      self.engine.callbacks:off(token)
    end
    self.tokens = {}
  end
  return link
end

-- A free-standing, movable window in Blizzard's frame style, hidden. It hangs
-- from UIParent, never from the main window: that one holds the secure Summon
-- button and is protected, so a window hanging from it could not be shown in
-- combat, and these have to be (a summon can come in a fight). o: name (only
-- for a window Esc should close), width, height, title, label (the sim player
-- it acts for), slot, point/x/y (where it sits on the screen).
function W.window(o)
  local f = CreateFrame("Frame", o.name, UIParent, "BasicFrameTemplateWithInset")
  f:Hide()
  f:SetSize(o.width, o.height)
  local point, slot = o.point or "CENTER", o.slot or 0
  f:SetPoint(point, UIParent, point, (o.x or 0) + slot * 26, (o.y or 0) - slot * 26)
  f:SetFrameStrata("DIALOG")
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(frame)
    frame:StartMoving()
  end)
  f:SetScript("OnDragStop", function(frame)
    frame:StopMovingOrSizing()
  end)
  if f.TitleText then
    W.setText(f.TitleText, o.label and (o.label .. " - " .. o.title) or o.title)
  end
  return f
end

-- A line of text in a colour (W.COLOR value); nil colour is white.
function W.say(fs, text, color)
  W.setText(fs, text)
  W.paint(fs, color)
end

-- A coloured edge for a frame: four thin textures (no backdrop template, which
-- Forever may not have). border:SetColor(r, g, b) colours all four; border.edges
-- lists them.
function W.border(frame, size)
  size = size or 2
  local edges = {}
  local function edge(first, second, vertical)
    local t = frame:CreateTexture(nil, "BORDER")
    t:SetPoint(first, frame, first, 0, 0)
    t:SetPoint(second, frame, second, 0, 0)
    if vertical then
      t:SetWidth(size)
    else
      t:SetHeight(size)
    end
    edges[#edges + 1] = t
  end
  edge("TOPLEFT", "TOPRIGHT", false)
  edge("BOTTOMLEFT", "BOTTOMRIGHT", false)
  edge("TOPLEFT", "BOTTOMLEFT", true)
  edge("TOPRIGHT", "BOTTOMRIGHT", true)
  local border = { edges = edges }
  function border:SetColor(r, g, b)
    for _, t in ipairs(self.edges) do
      t:SetColorTexture(r, g, b, 1)
    end
  end
  return border
end

-- The tip choice: none, each preset (50s, 1g) and custom (gold and silver
-- boxes). The chosen button is the disabled one, as with the tabs.
--   picker:SetOffer(copper)   picks the preset equal to it, custom for any other
--                             amount, none for nil or 0 (a tip offered earlier)
--   picker:Read()             true and the copper (nil for none), or false when
--                             custom holds nothing usable
-- onChange(choice) runs when the player picks one.
function W.tipPicker(parent, onChange)
  local picker = CreateFrame("Frame", nil, parent)
  picker:SetSize(300, 54)
  picker.choice = "none"
  picker.buttons = {}
  local options = { { choice = "none", text = L.TIP_NONE } }
  for _, copper in ipairs(Config.TIP_PRESETS) do
    options[#options + 1] = { choice = copper, text = Money.format(copper) }
  end
  options[#options + 1] = { choice = "custom", text = L.TIP_CUSTOM }
  for i, option in ipairs(options) do
    local b = W.button(picker, option.text, 70, function()
      picker:Select(option.choice)
    end)
    b:SetPoint("TOPLEFT", picker, "TOPLEFT", (i - 1) * 76, 0)
    b.choice = option.choice
    picker.buttons[i] = b
  end
  picker.custom = W.moneyInput(picker)
  picker.custom:SetPoint("TOPLEFT", picker, "TOPLEFT", 0, -28)

  function picker:Select(choice, quiet)
    self.choice = choice
    for _, b in ipairs(self.buttons) do
      b:SetEnabled(b.choice ~= choice)
    end
    self.custom:SetShown(choice == "custom")
    if onChange and not quiet then
      onChange(choice)
    end
  end
  function picker:SetOffer(copper)
    local choice = "none"
    if type(copper) == "number" and copper > 0 then
      choice = "custom"
      for _, preset in ipairs(Config.TIP_PRESETS) do
        if preset == copper then
          choice = preset
        end
      end
    end
    self.custom:Clear()
    if choice == "custom" then
      self.custom:SetCopper(copper)
    end
    self:Select(choice, true)
  end
  function picker:Read()
    if self.choice == "none" then
      return true, nil
    elseif self.choice == "custom" then
      local copper = self.custom:GetCopper()
      return copper ~= nil, copper
    end
    return true, self.choice
  end

  picker:Select("none", true)
  return picker
end
