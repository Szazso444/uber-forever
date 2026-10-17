describe("Locale", function()
  local L
  before_each(function() L = Taxi.load().L end)

  it("reads strings by key", function()
    L.greeting = "Hello"
    assert.are.equal("Hello", L.greeting)
  end)

  it("fmt formats with string.format", function()
    L.arrived = "%s arrived with %d seats"
    assert.are.equal("Ana Smith arrived with 3 seats", L.fmt("arrived", "Ana Smith", 3))
  end)

  it("falls back to the key for a missing string", function()
    assert.are.equal("no_such_key", L.no_such_key)
    assert.are.equal("no_such_key", L.fmt("no_such_key"))
  end)
end)
