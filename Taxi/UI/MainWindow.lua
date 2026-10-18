local _, ns = ...

-- The main window: Travel / My stand / Clicking / History tabs, a banner for a
-- dead Hardcore character and a status footer. It only calls Engine methods and
-- listens to Engine events; each tab is a module (ns.UI.StandList, MyStand,
-- Clicking, History) with new(parent, main) -> view and view:Refresh().
--
-- The window holds the secure Summon button, and the game treats the frames a
-- protected frame hangs from as protected too (the window, the open tab and the
-- stand header). In combat lockdown they can't be shown, hidden, moved or
-- switched from here, so in combat the window neither opens, closes, moves nor
-- changes tab (Esc is expected to still close it, that being the game's own
-- code; to verify in game); text and rows go on updating, and what was asked
-- for happens when combat ends.
--
-- Events and clicks only mark the window dirty; its OnUpdate repaints the open
-- tab once per frame at most, and anyway every REFRESH_SECONDS, since
-- Board.list ages stands out between the Engine's 30 s sweeps. A repaint that
-- raises is logged to the Engine's sink (/taxi debug), never repeated every
-- frame.
local L, Names = ns.L, ns.Names

local UI = ns.UI
local W = UI.Widgets

local Main = {}
UI.Main = Main

local WIDTH, HEIGHT = 600, 514
local CONTENT_W, CONTENT_H = 576, 398 -- below the tabs and the banner, above the two footer lines
local REFRESH_SECONDS = 5
local NOTICE_SECONDS = 10 -- how long an action's answer stays in the footer

local TABS = {
  { key = "travel", label = "TAB_TRAVEL", module = "StandList" },
  { key = "stand", label = "TAB_STAND", module = "MyStand" },
  { key = "clicking", label = "TAB_CLICKING", module = "Clicking" },
  { key = "history", label = "TAB_HISTORY", module = "History" },
}

-- Engine events after which what a tab shows may have changed.
local REPAINT_EVENTS = {
  "BOARD_CHANGED", "STAND_CHANGED", "REQUEST_RECEIVED", "RIDE_CHANGED", "CLICKER_APPLIED", "CLICK_OFFER",
  "CLICK_DECLINED", "SHIFT_STARTED", "SHIFT_ENDED", "PORTAL_UP",
}

Main.elapsed = 0
Main.dirty = false
Main.active = "travel"

-- Starting -----------------------------------------------------------------------------

-- Called once when the Engine exists (Core/Init): listens to its events, keeps
-- the History list, builds the minimap button and the (hidden) window. The
-- window is built here, out of combat, because its secure button can't be set
-- up during combat lockdown; a game that starts in combat gets it afterwards.
function Main:Start()
  local engine = ns.engine
  if self.started or engine == nil then
    return
  end
  self.started = true
  local function repaint()
    self:Invalidate()
  end
  for _, event in ipairs(REPAINT_EVENTS) do
    engine:on(event, repaint)
  end
  engine:on("STATUS", function(_, text)
    self:notify(text)
  end)
  engine:on("RIDE_CHANGED", function(ride)
    self:rideChanged(ride)
  end)
  engine:on("CLICK_DECLINED", function(neg)
    self:notify(L.fmt("NOTICE_APP_DECLINED", tostring(neg.owner)))
  end)
  UI.History.attach(engine, ns.db)
  UI.MinimapButton.create()
  self:Watch()
  self:Create()
end

-- What the Engine can't tell the window: the group changed (the secure
-- button's unit token) and combat started or ended. When it ends, what could
-- not be done in combat is: the window is built, a drag is let go of, and an
-- opening that was asked for happens.
function Main:Watch()
  local events = CreateFrame("Frame")
  events:RegisterEvent("GROUP_ROSTER_UPDATE")
  events:RegisterEvent("PLAYER_REGEN_ENABLED")
  events:RegisterEvent("PLAYER_REGEN_DISABLED")
  events:SetScript("OnEvent", function(_, event)
    self:Invalidate()
    if event ~= "PLAYER_REGEN_ENABLED" then
      return
    end
    local frame = self:Create()
    if frame and self.moving then
      frame:StopMovingOrSizing()
      self.moving = false
    end
    local key = self.pending
    if key then
      self.pending = nil
      self:Show(key ~= true and key or nil)
    end
  end)
  self.events = events
end

-- A request of mine that the stand's owner turned down, or that went unanswered.
function Main:rideChanged(ride)
  local engine = ns.engine
  if engine == nil or not Names.same(ride.traveler, engine.me) then
    return
  end
  if ride.state == "declined" then
    self:notify(L.fmt("NOTICE_DECLINED", tostring(ride.driver)))
  elseif ride.state == "cancelled" then
    self:notify(L.fmt("NOTICE_RIDE_ENDED", tostring(ride.driver)))
  end
end

-- State the tabs share -------------------------------------------------------------------

-- True while the player's Hardcore character is dead (R35): the window says so
-- and every action is off.
function Main.dead()
  local engine = ns.engine
  local game = engine and engine.game
  return game ~= nil and game:isHardcore() == true and game:isDead() == true
end

function Main.actionsEnabled()
  return ns.engine ~= nil and not Main.dead()
end

-- Why an action was refused, as text (reason codes are the Engine's).
function Main.explain(_, why)
  return rawget(L, "ERR_" .. tostring(why)) or L.fmt("ERR_UNKNOWN", tostring(why))
end

-- Shows text in the footer for a while.
function Main:notify(text)
  local engine = ns.engine
  self.notice = text
  self.noticeUntil = (engine and engine.clock:now() or 0) + NOTICE_SECONDS
  self:Invalidate()
end

-- Reports the outcome of an Engine call (ok, why) in the footer: the reason
-- when it was refused, `done` (text) when it worked, and repaints at once, so
-- the player sees what the click did. Returns ok.
function Main:report(ok, why, done)
  if not ok then
    self:notify(self:explain(why))
  elseif done then
    self:notify(done)
  end
  self:Refresh()
  return ok
end

-- The footer's first line: an action's answer, else what is wrong with Taxi
-- itself (read live, so it clears when it is fixed), else nothing.
function Main:statusText()
  local engine = ns.engine
  if engine == nil then
    return L.UI_NOT_RUNNING
  end
  if self.notice and engine.clock:now() < self.noticeUntil then
    return self.notice
  end
  if Main.dead() then
    return L.STATUS_HC_DEAD
  elseif engine.disabled then
    return L.STATUS_CHANNEL_FULL
  elseif engine.inInstance then
    return L.STATUS_LOCKDOWN
  elseif engine.updateShown then
    return L.STATUS_UPDATE
  end
  return ""
end

-- The footer's second line (spec 8.4): new ratings are only on disk after a
-- /reload or logout, and the player is told whenever that is so, whatever the
-- first line says, except in combat.
function Main.reminderText()
  local engine = ns.engine
  if engine ~= nil and engine.dirty and not UnitAffectingCombat("player") then
    return L.FOOTER_DIRTY
  end
  return ""
end

-- Showing and hiding ----------------------------------------------------------------------------

function Main:IsShown()
  return self.frame ~= nil and self.frame:IsShown()
end

function Main:Invalidate()
  self.dirty = true
end

function Main:Toggle()
  if ns.engine == nil then
    print(L.CHAT_PREFIX .. L.UI_NOT_RUNNING)
    return
  end
  if not self:IsShown() then
    self:Show()
  elseif InCombatLockdown() then
    print(L.CHAT_PREFIX .. L.UI_CLOSE_COMBAT)
  else
    self.frame:Hide()
  end
end

-- Opens the window, on tab `key` when given. In combat it is asked for, and
-- done when combat ends.
function Main:Show(key)
  if ns.engine == nil then
    return
  end
  if InCombatLockdown() then
    self.pending = key or true
    print(L.CHAT_PREFIX .. L.UI_AFTER_COMBAT)
    return
  end
  if self:Create() == nil then
    print(L.CHAT_PREFIX .. L.UI_BUILD_FAILED)
    return
  end
  self:ShowTab(key or self.active)
  self.frame:Show() -- its OnShow paints
end

function Main:Hide()
  if self.frame and not InCombatLockdown() then
    self.frame:Hide()
  end
end

-- Makes `key` ("travel", "stand", "clicking" or "history") the open tab.
function Main:ShowTab(key)
  if self.frame == nil then
    self.active = key
    return
  end
  if InCombatLockdown() then
    self:notify(L.UI_TABS_COMBAT)
    return
  end
  W.closeMenu()
  self.active = key
  for _, tab in ipairs(TABS) do
    local shown = tab.key == key
    self.views[tab.key].frame:SetShown(shown)
    self.tabButtons[tab.key]:SetEnabled(not shown)
  end
  self:Refresh()
end

-- Painting -------------------------------------------------------------------------------------

function Main:paint()
  W.setText(self.banner, Main.dead() and L.STATUS_HC_DEAD or "")
  self.views[self.active]:Refresh()
  W.setText(self.footer, self:statusText())
  W.setText(self.reminder, self:reminderText())
end

-- Repaints the open tab, the banner and the footer, if the window is open.
function Main:Refresh()
  self.dirty, self.elapsed = false, 0
  if not self:IsShown() or ns.engine == nil then
    return
  end
  ns.engine:safely("window refresh", self.paint, self)
end

-- Building the window --------------------------------------------------------------------------------

-- Fills the new frame `f`: its scripts and the four tabs, banner and footer. It
-- only publishes the window (self.frame, self.views ...) and registers it for
-- Esc when everything has been built, so a failure partway leaves no half
-- window behind in the module.
local function build(self, f)
  f:SetSize(WIDTH, HEIGHT)
  f:SetPoint("CENTER", UIParent, "CENTER", 0, 20)
  f:SetToplevel(true)
  f:SetClampedToScreen(true)
  f:SetMovable(true)
  f:EnableMouse(true)
  f:RegisterForDrag("LeftButton")
  f:SetScript("OnDragStart", function(frame)
    if not InCombatLockdown() then
      frame:StartMoving()
      self.moving = true
    end
  end)
  f:SetScript("OnDragStop", function(frame)
    if not InCombatLockdown() then -- in combat it is let go of when combat ends (Watch)
      frame:StopMovingOrSizing()
      self.moving = false
    end
  end)
  if f.TitleText then
    f.TitleText:SetText(L.UI_TITLE)
  end

  local tabButtons, views = {}, {}
  for i, tab in ipairs(TABS) do
    local button = W.button(f, L[tab.label], 130, function()
      self:ShowTab(tab.key)
    end)
    button:SetPoint("TOPLEFT", f, "TOPLEFT", 12 + (i - 1) * 134, -30)
    tabButtons[tab.key] = button

    local holder = CreateFrame("Frame", nil, f)
    holder:SetSize(CONTENT_W, CONTENT_H)
    holder:SetPoint("TOPLEFT", f, "TOPLEFT", 12, -72)
    holder:Hide()
    local view = UI[tab.module].new(holder, self)
    view.frame = holder
    views[tab.key] = view
  end

  local banner = W.text(f, "GameFontNormal")
  banner:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -56)
  banner:SetWidth(CONTENT_W - 8)
  W.paint(banner, W.COLOR.red)

  -- Two footer lines: what Taxi says (above), and the reminder to save (below).
  local footer = W.text(f, "GameFontNormalSmall")
  footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 27)
  footer:SetWidth(CONTENT_W - 8)
  local reminder = W.text(f, "GameFontNormalSmall")
  reminder:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 12)
  reminder:SetWidth(CONTENT_W - 8)

  f:SetScript("OnShow", function()
    self:Refresh()
  end)
  f:SetScript("OnHide", function()
    W.closeMenu()
  end)
  f:SetScript("OnUpdate", function(_, elapsed)
    self.elapsed = self.elapsed + elapsed
    if self.dirty or self.elapsed >= REFRESH_SECONDS then
      self:Refresh()
    end
  end)

  self.tabButtons, self.views, self.banner, self.footer, self.reminder = tabButtons, views, banner, footer, reminder
  self.frame = f
  if UISpecialFrames then
    table.insert(UISpecialFrames, "TaxiMainFrame") -- Esc closes it (expected; checked in game)
  end
end

-- Builds the window once and returns it. Nil during combat lockdown, when its
-- protected button can't be set up (it is built when combat ends), and nil for
-- good if the build failed: the frame is hidden at once, so a failure leaves
-- nothing on screen, the error goes to the Engine's log (/taxi debug), and the
-- window is not built a second time (R58).
function Main:Create()
  if self.frame then
    return self.frame
  end
  if self.failed or InCombatLockdown() then
    return nil
  end
  local f = CreateFrame("Frame", "TaxiMainFrame", UIParent, "BasicFrameTemplateWithInset")
  f:Hide()
  local built, err = pcall(build, self, f)
  if not built then
    self.failed = true
    f:Hide()
    if ns.engine then
      pcall(ns.engine.log, "window build: " .. tostring(err))
    end
    return nil
  end
  return f
end
