describe("Callbacks", function()
  local ns = Taxi.load()
  local cb
  before_each(function() cb = ns.Callbacks.new() end)

  it("calls every handler for an event in registration order, with all arguments", function()
    local log = {}
    cb:on("E", function(a, b) log[#log + 1] = "first:" .. a .. b end)
    cb:on("E", function(a, b) log[#log + 1] = "second:" .. a .. b end)
    cb:emit("E", "x", "y")
    assert.are.same({ "first:xy", "second:xy" }, log)
  end)

  it("keeps events separate", function()
    local hits = 0
    cb:on("A", function() hits = hits + 1 end)
    cb:emit("B")
    assert.are.equal(0, hits)
  end)

  it("emit with no handlers is a no-op", function()
    assert.has_no.errors(function() cb:emit("NOBODY", 1, 2) end)
  end)

  it("off removes only the handler it was given", function()
    local a, b = 0, 0
    local tokA = cb:on("E", function() a = a + 1 end)
    cb:on("E", function() b = b + 1 end)
    cb:off(tokA)
    cb:emit("E")
    assert.are.equal(0, a)
    assert.are.equal(1, b)
  end)

  it("off ignores unknown and repeated tokens", function()
    local tok = cb:on("E", function() end)
    cb:off(tok)
    assert.has_no.errors(function() cb:off(tok); cb:off(99999); cb:off(nil) end)
  end)

  it("a handler removed during emit is skipped, one added during emit waits", function()
    local log = {}
    local tok2
    cb:on("E", function()
      log[#log + 1] = "one"
      cb:off(tok2)
      cb:on("E", function() log[#log + 1] = "late" end)
    end)
    tok2 = cb:on("E", function() log[#log + 1] = "two" end)
    cb:emit("E")
    assert.are.same({ "one" }, log)
    log = {}
    cb:emit("E")
    assert.are.same({ "one", "late" }, log)
  end)

  it("emitters do not share handlers", function()
    local other, hits = ns.Callbacks.new(), 0
    cb:on("E", function() hits = hits + 1 end)
    other:emit("E")
    assert.are.equal(0, hits)
  end)
end)
