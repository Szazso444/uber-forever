local _, ns = ...

-- The Summon Guard panel. When a summon is offered the Engine judges it
-- (GUARD_VERDICT) and this panel shows the verdict next to Blizzard's own
-- summon popup: a coloured border (green, yellow or red), a title, and one line
-- per check, "✓ Summoner: Dar Kbolt" or "✗ Destination: Searing Gorge (agreed:
-- Tanaris)". On RED it also offers "Decline summon" (Engine:cancelSummon).
-- There is never an accept button: accepting a summon is the player's own click
-- on Blizzard's popup, and this panel does not touch that popup (it only reads
-- where it is, to sit to its right; with no popup it sits at the top centre).
--
-- It goes away when the popup does (SUMMON_GONE) or the ride arrives (ARRIVED).
-- It is a plain frame hanging from UIParent, so it shows in combat, which is
-- exactly when a wrong summon is most dangerous. The text of every check is
-- escaped (it holds player names and area names).
local L = ns.L
local UI = ns.UI
local W = UI.Widgets

local M = {}
UI.GuardPanel = M

local WIDTH = 340
local MAX_LINES = 9 -- the guard has seven checks
local POLL_SECONDS = 0.25 -- how often a shown panel looks for the popup (it may open after the verdict)

M.COLORS = {
  GREEN = { 0.2, 0.8, 0.2 }, -- #3c3
  YELLOW = { 1, 0.8, 0.2 }, -- #fc3
  RED = { 0.93, 0.2, 0.2 }, -- #e33
}
local COLORS = M.COLORS

-- Blizzard's summon popup, or nil. Only read: the frame is an anchor and nothing else.
local function popup()
  local ok, frame = pcall(StaticPopup_FindVisible, "CONFIRM_SUMMON")
  return ok and frame or nil
end

local function heightOf(fs)
  return math.max(fs:GetStringHeight() or 0, 12)
end

local function build(view, link)
  local f = CreateFrame("Frame", nil, UIParent)
  f:Hide()
  f:SetWidth(WIDTH)
  f:SetFrameStrata("FULLSCREEN_DIALOG")
  f:SetClampedToScreen(true)
  local bg = f:CreateTexture(nil, "BACKGROUND")
  bg:SetAllPoints()
  bg:SetColorTexture(0.04, 0.04, 0.07, 0.94)
  f.border = W.border(f, 3)
  f.title = W.text(f, "GameFontNormal")
  f.title:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -10)
  f.title:SetWidth(WIDTH - 24)
  f.title:SetWordWrap(true)
  -- Each line hangs under the one above, so a line that wraps pushes the rest down.
  f.lines = {}
  for i = 1, MAX_LINES do
    local line = W.text(f, "GameFontHighlightSmall")
    line:SetWidth(WIDTH - 24)
    line:SetWordWrap(true)
    line:SetPoint("TOPLEFT", i == 1 and f.title or f.lines[i - 1], "BOTTOMLEFT", 0, -4)
    f.lines[i] = line
  end
  f.decline = W.button(f, L.GUARD_DECLINE, 170, function()
    link.engine:cancelSummon()
  end)
  f.decline:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 10)
  f:SetScript("OnUpdate", function(_, elapsed)
    view.elapsed = (view.elapsed or 0) + elapsed
    if view.elapsed >= POLL_SECONDS then
      view.elapsed = 0
      view:Anchor()
    end
  end)
  return f
end

local function newView(link)
  local view = {}

  function view:Hide()
    if self.frame then
      self.frame:Hide()
    end
  end

  -- To the right of Blizzard's summon popup when there is one, else top centre.
  -- Asked again while shown, in case the popup opens just after the verdict.
  function view:Anchor()
    local f, target = self.frame, popup()
    if self.anchored and target == self.anchoredTo then
      return
    end
    self.anchored, self.anchoredTo = true, target
    f:ClearAllPoints()
    if target ~= nil then
      f:SetPoint("TOPLEFT", target, "TOPRIGHT", 8, 0)
    else
      f:SetPoint("TOP", UIParent, "TOP", 0, -24)
    end
  end

  -- Shows `verdict` ({ level, checks = { {ok, level, text} } }, SummonGuard.evaluate).
  function view:Show(verdict)
    local f = self.frame or build(self, link)
    self.frame = f
    verdict = type(verdict) == "table" and verdict or {}
    local checks = type(verdict.checks) == "table" and verdict.checks or {}
    local level = COLORS[verdict.level] and verdict.level or "RED" -- a verdict nobody can read is the worst
    local color = COLORS[level]
    f.border:SetColor(color[1], color[2], color[3])
    W.say(f.title, L["GUARD_TITLE_" .. level], color)
    local height = 10 + heightOf(f.title)
    for i, line in ipairs(f.lines) do
      local check = checks[i]
      if type(check) == "table" then
        local tint = check.ok and COLORS.GREEN or COLORS[check.level] or COLORS.RED
        W.say(line, (check.ok and W.CHECK or W.CROSS) .. " " .. tostring(check.text), tint)
        line:Show()
        height = height + heightOf(line) + 4
      else
        W.setText(line, "")
        line:Hide()
      end
    end
    f.decline:SetShown(level == "RED")
    f:SetHeight(height + (level == "RED" and 44 or 12))
    self.anchored = false
    self:Anchor()
    f:Show()
  end

  return view
end

-- Gives `engine` its guard panel. Returns { Refresh(), Detach() }.
function M.attach(engine, opts)
  local link = W.link(engine, opts)
  local view = newView(link)
  link:on("GUARD_VERDICT", function(verdict)
    view:Show(verdict)
  end)
  link:on("SUMMON_GONE", function()
    view:Hide()
  end)
  link:on("ARRIVED", function()
    view:Hide()
  end)
  return {
    Refresh = function()
      if not link:live() then
        view:Hide()
      end
    end,
    Detach = function()
      link:detach()
      view:Hide()
    end,
  }
end
