-- UI/Widgets.lua on the strict fake frame API (tests/ui/fake_ui.lua).
local FakeUI = dofile("tests/ui/fake_ui.lua")

describe("Widgets", function()
  local ns, ui, W, parent

  before_each(function()
    ns = Taxi.load()
    ui = FakeUI.new()
    ui.load(ns)
    W = ns.UI.Widgets
    parent = ui.env.CreateFrame("Frame")
  end)

  describe("text", function()
    it("escapes | as || so text from the wire can't start a colour or link code", function()
      assert.are.equal("a||cffff0000b||r", W.escape("a|cffff0000b|r"))
      assert.are.equal("", W.escape(nil))
      assert.are.equal("12", W.escape(12))
    end)

    it("turns every control character into a space, so text from the wire is one line", function()
      assert.are.equal("a b  c d e||f", W.escape("a\nb\r\tc\0d\127e|f"))
      assert.are.equal("Tanaris ★ 5.0", W.escape("Tanaris\n★ 5.0")) -- other bytes, UTF-8 included, stay
    end)

    it("keeps the glyphs the windows draw (R59): only ASCII controls are replaced, never UTF-8 bytes", function()
      -- %c can match bytes 0x80-0x9F in a Latin-1 locale, and the glyphs below are
      -- made of such bytes (★ is E2 98 85, ⚠ is E2 9A A0); a class of explicit
      -- ASCII ranges cannot. The Latin-1 locale is tried where the machine has one
      -- (this one may not, then the test pins the behaviour in the C locale).
      local before = os.setlocale(nil, "ctype")
      local latin1 = os.setlocale("en_US.ISO-8859-1", "ctype") or os.setlocale("C.ISO-8859-1", "ctype")
      local ok, err = pcall(function()
        assert.are.equal("★ ⚠ → ✓ ✗", W.escape("★ ⚠ → ✓ ✗"))
        assert.are.equal("★ 4.8 ⚠ 2", W.escape("★\n4.8\0⚠\127" .. "2"))
        assert.are.equal("    ", W.escape("\0\1\31\127"))
        assert.are.equal("\128\145\159", W.escape("\128\145\159"))
      end)
      os.setlocale(before, "ctype")
      assert.is_true(ok, tostring(err) .. (latin1 and "" or " (C locale)"))
    end)

    it("setText escapes for font strings and buttons alike", function()
      local fs = parent:CreateFontString()
      W.setText(fs, "Evil|Name")
      assert.are.equal("Evil||Name", fs:GetText())
      local button = W.button(parent, "Go|", 50)
      assert.are.equal("Go||", button:GetText())
    end)

    it("names a portal, falling back to its key", function()
      assert.are.equal("Thunder Bluff", W.portalName("thunderbluff"))
      assert.are.equal("shattrath", W.portalName("shattrath"))
      assert.are.equal("Stormwind, Ironforge", W.portalNames({ "stormwind", "ironforge" }))
      assert.are.equal("", W.portalNames(nil))
    end)

    it("says where a stand is, with or without a subzone", function()
      assert.are.equal("Tanaris - Gadgetzan", W.place({ zone = "Tanaris", subzone = "Gadgetzan" }))
      assert.are.equal("Tanaris", W.place({ zone = "Tanaris", subzone = "" }))
      assert.are.equal("Tanaris", W.place({ zone = "Tanaris" }))
    end)
  end)

  describe("trust and share lines", function()
    it("shows the stars, the summons and New, and reported deaths apart", function()
      assert.are.same({ "★ 4.8 · 137 summons" },
        { W.trustLine({ stars = 4.8, count = 137, isNew = false, deathsReported = 0 }) })
      assert.are.same({ "★ 4.2 · 1 summon · New", "⚠ 1 reported death" },
        { W.trustLine({ stars = 4.2, count = 1, isNew = true, deathsReported = 1 }) })
      assert.are.same({ "New · no ratings yet", "⚠ 3 reported deaths" },
        { W.trustLine({ stars = nil, count = 0, isNew = true, deathsReported = 3 }) })
    end)

    it("shows a Share rating with its shifts", function()
      assert.are.equal("Share ★ 4.0 · 12 shifts", W.shareLine({ stars = 4, count = 12, isNew = false }))
      assert.are.equal("Share ★ 5.0 · 1 shift · New", W.shareLine({ stars = 5, count = 1, isNew = true }))
      assert.are.equal("Share: no ratings yet", W.shareLine({ stars = nil, count = 0, isNew = true }))
    end)
  end)

  describe("stars", function()
    it("picks 1 to 5 and tells the caller", function()
      local picked = {}
      local stars = W.stars(parent, function(n) picked[#picked + 1] = n end)
      assert.are.equal(0, stars:GetValue())
      ui:click(stars.buttons[4])
      assert.are.same({ 4 }, picked)
      assert.are.equal(4, stars:GetValue())
      assert.are.same(W.COLOR.gold, stars.buttons[4].label.color)
      assert.are.same(W.COLOR.gray, stars.buttons[5].label.color)
    end)

    it("shows a suggested value without calling the caller, and can be made display only", function()
      local picked = {}
      local stars = W.stars(parent, function(n) picked[#picked + 1] = n end)
      stars:SetValue(3)
      assert.are.equal(3, stars:GetValue())
      assert.are.same({}, picked)
      assert.are.same(W.COLOR.gold, stars.buttons[3].label.color)
      stars:SetPickable(false)
      ui:click(stars.buttons[5])
      assert.are.equal(3, stars:GetValue())
      assert.are.same({}, picked)
    end)

    it("previews a star under the mouse and goes back when it leaves", function()
      local stars = W.stars(parent, function() end)
      stars:SetValue(1)
      ui:fire(stars.buttons[4], "OnEnter")
      assert.are.same(W.COLOR.gold, stars.buttons[4].label.color)
      ui:fire(stars.buttons[4], "OnLeave")
      assert.are.same(W.COLOR.gray, stars.buttons[4].label.color)
      assert.are.same(W.COLOR.gold, stars.buttons[1].label.color)
    end)
  end)

  describe("money input", function()
    it("reads gold and silver as copper, and nothing as nil", function()
      local input = W.moneyInput(parent)
      assert.is_nil(input:GetCopper())
      input.gold:SetText("2")
      input.silver:SetText("50")
      assert.are.equal(25000, input:GetCopper())
      input.gold:SetText("")
      assert.are.equal(5000, input:GetCopper())
      input:Clear()
      assert.is_nil(input:GetCopper())
    end)

    it("fills the boxes from copper", function()
      local input = W.moneyInput(parent)
      input:SetCopper(10000)
      assert.are.same({ "1", "" }, { input.gold:GetText(), input.silver:GetText() })
      input:SetCopper(5000)
      assert.are.same({ "", "50" }, { input.gold:GetText(), input.silver:GetText() })
      input:SetCopper(123400)
      assert.are.same({ "12", "34" }, { input.gold:GetText(), input.silver:GetText() })
    end)
  end)

  describe("menu and dropdown", function()
    local function catcherOf()
      for _, f in ipairs(ui.frames) do
        if f.scripts and f.scripts.OnClick == W.closeMenu then
          return f
        end
      end
    end

    it("opens under the anchor, hands back the raw value and closes", function()
      local anchor = ui.env.CreateFrame("Button")
      anchor.width = 100
      local picked
      W.popupMenu(anchor, { { value = 1, text = "One" }, { value = "b|c", text = "Two|" } }, function(v, t)
        picked = { v, t }
      end)
      assert.is_true(ui:visible(ui:one{ kind = "FontString", text = "One" }))
      local two = ui:one{ kind = "FontString", text = "Two||" } -- shown escaped
      ui:click(two.parent)
      assert.are.same({ "b|c", "Two|" }, picked)
      assert.are.same({}, ui:find{ kind = "FontString", text = "One" })
    end)

    it("closes on a second click on its anchor and on a click elsewhere", function()
      local anchor = ui.env.CreateFrame("Button")
      anchor.width = 100
      local items = { { value = 1, text = "One" } }
      W.popupMenu(anchor, items, function() end)
      W.popupMenu(anchor, items, function() end)
      assert.are.same({}, ui:find{ kind = "FontString", text = "One" })
      W.popupMenu(anchor, items, function() end)
      assert.is_true(ui:click(catcherOf()))
      assert.are.same({}, ui:find{ kind = "FontString", text = "One" })
    end)

    it("shows nothing for an empty menu", function()
      local anchor = ui.env.CreateFrame("Button")
      anchor.width = 100
      W.popupMenu(anchor, {}, function() end)
      assert.is_nil(catcherOf() and ui:visible(catcherOf()) and true or nil)
    end)

    it("a dropdown shows the chosen item and also picks the first, which has no value", function()
      local picks = {}
      local dd = W.dropdown(parent, 120, function(v) picks[#picks + 1] = v == nil and "nil" or v end)
      dd:SetItems({ { value = nil, text = "All zones" }, { value = "Tanaris", text = "Tanaris" } })
      dd:Select("Tanaris")
      assert.are.equal("Tanaris", dd:GetText())
      ui:click(dd)
      ui:click(ui:one{ kind = "FontString", text = "All zones" }.parent)
      assert.are.same({ "nil" }, picks)
      assert.are.equal("All zones", dd:GetText())
    end)
  end)

  describe("list", function()
    local function rows(n)
      local specs = {}
      for i = 1, n do
        specs[i] = {
          title = "Row " .. i, sub = "sub|" .. i, right = "r" .. i,
          edit = { key = "k" .. i, text = "25" },
          buttons = { { text = "Go", onClick = function(spec) specs.clicked = spec.title end } },
        }
      end
      return specs
    end

    it("binds the first rows, escapes every text, and hides the rest", function()
      local list = W.list(parent, { width = 500, rows = 3, buttons = 2, edit = true })
      local specs = rows(2)
      specs[1].titleColor = W.COLOR.green
      list:SetRows(specs)
      assert.are.equal("Row 1", list.rows[1].title:GetText())
      assert.are.same(W.COLOR.green, list.rows[1].title.color)
      assert.are.equal("sub||1", list.rows[1].sub:GetText())
      assert.are.equal("r1", list.rows[1].right:GetText())
      assert.is_true(ui:visible(list.rows[2]))
      assert.is_false(ui:visible(list.rows[3]))
      assert.is_true(ui:visible(list.rows[1].buttons[1]))
      assert.is_false(ui:visible(list.rows[1].buttons[2])) -- the spec has one button
    end)

    it("runs a button's and a row's click with the spec", function()
      local list = W.list(parent, { width = 500, rows = 3, buttons = 1 })
      local specs = rows(2)
      specs[2].onClick = function(spec) specs.rowClicked = spec.title end
      list:SetRows(specs)
      ui:click(list.rows[1].buttons[1])
      assert.are.equal("Row 1", specs.clicked)
      ui:click(list.rows[2])
      assert.are.equal("Row 2", specs.rowClicked)
    end)

    it("greys a disabled button, and lays buttons out from the right", function()
      local list = W.list(parent, { width = 500, rows = 1, buttons = 2 })
      local calls = 0
      list:SetRows({ {
        title = "x",
        buttons = {
          { text = "B", width = 70, enabled = false, onClick = function() calls = calls + 1 end },
          { text = "A", width = 90, onClick = function() calls = calls + 1 end },
        },
      } })
      local row = list.rows[1]
      assert.is_false(ui:click(row.buttons[1]))
      assert.is_true(ui:click(row.buttons[2]))
      assert.are.equal(1, calls)
      assert.are.equal(-6, row.buttons[1].points[#row.buttons[1].points][4])
      assert.are.equal(-6 - 70 - 4, row.buttons[2].points[#row.buttons[2].points][4])
    end)

    it("scrolls by rows, within range, with the wheel and the arrows", function()
      local list = W.list(parent, { width = 500, rows = 3, buttons = 1 })
      list:SetRows(rows(5))
      assert.are.same({ false, true }, { list.up.enabled, list.down.enabled })
      list:Scroll(1)
      assert.are.equal("Row 2", list.rows[1].title:GetText())
      list:Scroll(10)
      assert.are.equal("Row 3", list.rows[1].title:GetText())
      assert.are.same({ true, false }, { list.up.enabled, list.down.enabled })
      ui:fire(list.frame, "OnMouseWheel", 1) -- wheel up
      assert.are.equal("Row 2", list.rows[1].title:GetText())
      ui:click(list.down)
      assert.are.equal("Row 3", list.rows[1].title:GetText())
      ui:click(list.up)
      assert.are.equal("Row 2", list.rows[1].title:GetText())
    end)

    it("keeps the scroll place when rows are set again, unless the list got shorter", function()
      local list = W.list(parent, { width = 500, rows = 3, buttons = 1 })
      list:SetRows(rows(8))
      list:Scroll(4)
      list:SetRows(rows(8))
      assert.are.equal("Row 5", list.rows[1].title:GetText())
      list:SetRows(rows(4))
      assert.are.equal("Row 2", list.rows[1].title:GetText())
      list:SetRows({})
      assert.is_false(ui:visible(list.rows[1]))
    end)

    it("keeps a number the player typed while its row shows the same thing", function()
      local list = W.list(parent, { width = 500, rows = 2, buttons = 1, edit = true })
      list:SetRows(rows(4))
      list.rows[1].edit:SetText("30")
      list:SetRows(rows(4)) -- a refresh
      assert.are.equal("30", list.rows[1].edit:GetText())
      list:Scroll(1) -- row 1 now shows another stand
      assert.are.equal("25", list.rows[1].edit:GetText())
    end)

    it("draws a header row without a highlight", function()
      local list = W.list(parent, { width = 500, rows = 2, buttons = 1 })
      list:SetRows({ { header = true, title = "Crew" }, { title = "Ana" } })
      assert.are.same(W.COLOR.gold, list.rows[1].title.color)
      assert.are.same(W.COLOR.white, list.rows[2].title.color)
    end)
  end)
end)
