local _, ns = ...

-- The minimap button, written by hand (no LibDBIcon, plan decision 2): a click
-- opens or closes the main window, and it can be dragged around the minimap.
-- Its place is the angle in degrees in db.settings.minimap.angle.
local L = ns.L
local UI = ns.UI
local W = UI.Widgets

local M = {}
UI.MinimapButton = M

local DEFAULT_ANGLE = 215
local ICON = "Interface\\Icons\\INV_Misc_Map_01"

local function settings()
  local db = ns.db
  if db == nil or type(db.settings) ~= "table" then
    return {}
  end
  if type(db.settings.minimap) ~= "table" then
    db.settings.minimap = {}
  end
  return db.settings.minimap
end

-- Puts the button on the minimap's rim at `degrees` (0 = east, counter-clockwise).
function M.place(button, degrees)
  local rim = (Minimap:GetWidth() / 2) + 5
  local radians = math.rad(degrees)
  button:ClearAllPoints()
  button:SetPoint("CENTER", Minimap, "CENTER", math.cos(radians) * rim, math.sin(radians) * rim)
end

-- While dragging: the button follows the cursor's direction from the minimap's centre.
local function follow(button)
  local mx, my = Minimap:GetCenter()
  local cx, cy = GetCursorPosition()
  local scale = Minimap:GetEffectiveScale()
  local degrees = math.deg(math.atan2(cy / scale - my, cx / scale - mx)) % 360
  settings().angle = degrees
  M.place(button, degrees)
end

local function tooltip(button)
  GameTooltip:SetOwner(button, "ANCHOR_LEFT")
  GameTooltip:SetText(L.UI_TITLE)
  GameTooltip:AddLine(L.MINIMAP_TIP, 1, 1, 1)
  local status = UI.Main:statusText()
  if status ~= "" then
    GameTooltip:AddLine(W.escape(status), 1, 0.82, 0)
  end
  GameTooltip:Show()
end

-- Builds the button once.
function M.create()
  if M.button or Minimap == nil then
    return M.button
  end
  local button = CreateFrame("Button", "TaxiMinimapButton", Minimap)
  M.button = button
  button:SetSize(31, 31)
  button:SetFrameStrata("MEDIUM")
  button:SetFrameLevel(8)
  button:SetHighlightTexture("Interface\\Minimap\\UI-Minimap-ZoomButton-Highlight")
  button:RegisterForClicks("LeftButtonUp")
  button:RegisterForDrag("LeftButton")

  local border = button:CreateTexture(nil, "OVERLAY")
  border:SetSize(53, 53)
  border:SetTexture("Interface\\Minimap\\MiniMap-TrackingBorder")
  border:SetPoint("TOPLEFT", button, "TOPLEFT", 0, 0)
  local background = button:CreateTexture(nil, "BACKGROUND")
  background:SetSize(20, 20)
  background:SetTexture("Interface\\Minimap\\UI-Minimap-Background")
  background:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -5)
  local icon = button:CreateTexture(nil, "ARTWORK")
  icon:SetSize(17, 17)
  icon:SetTexture(ICON)
  icon:SetPoint("TOPLEFT", button, "TOPLEFT", 7, -6)

  button:SetScript("OnClick", function()
    UI.Main:Toggle()
  end)
  button:SetScript("OnDragStart", function(self)
    GameTooltip:Hide()
    self:SetScript("OnUpdate", follow)
  end)
  button:SetScript("OnDragStop", function(self)
    self:SetScript("OnUpdate", nil)
  end)
  button:SetScript("OnEnter", tooltip)
  button:SetScript("OnLeave", function()
    GameTooltip:Hide()
  end)

  M.place(button, settings().angle or DEFAULT_ANGLE)
  return button
end
