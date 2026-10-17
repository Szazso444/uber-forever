describe("Names", function()
  local N = Taxi.load().Names

  it("full names only", function()
    assert.is_false(N.same("Ana Smith", "Ana Jones"))   -- Review Focus 1
    assert.is_true(N.same(" Ana  Smith ", "Ana Smith"))
    assert.is_false(N.same("Ana", "Ana Smith"))
    assert.is_false(N.same(nil, "Ana Smith"))
  end)

  it("same is false when the other side is nil, and when both are", function()
    assert.is_false(N.same("Ana Smith", nil))
    assert.is_false(N.same(nil, nil))
  end)

  it("same is false for non-strings", function()
    assert.is_false(N.same(42, 42))
    assert.is_false(N.same({}, {}))
  end)

  it("two blank names never match each other", function()
    assert.is_false(N.same("", ""))
    assert.is_false(N.same("   ", "\t"))
    assert.is_false(N.same("", "Ana Smith"))
  end)

  it("same shares the first name or the surname but still differs", function()
    assert.is_false(N.same("Ana Smith", "Bob Smith"))
    assert.is_false(N.same("Smith Ana", "Ana Smith"))
  end)

  it("same does not lowercase or strip a realm", function()
    assert.is_false(N.same("ana smith", "Ana Smith"))
    assert.is_false(N.same("Ana Smith-Realm", "Ana Smith"))
    assert.is_true(N.same("Ana Smith-Realm", "Ana Smith-Realm"))
  end)

  describe("normalize", function()
    it("trims and collapses inner whitespace runs to one space", function()
      assert.are.equal("Ana Smith", N.normalize("  Ana   Smith  "))
      assert.are.equal("Ana Smith", N.normalize("Ana Smith"))
      assert.are.equal("Ana Smith", N.normalize("\tAna \t\n Smith\n"))
    end)

    it("changes nothing else: case and realm suffix stay", function()
      assert.are.equal("aNa SmItH", N.normalize("aNa SmItH"))
      assert.are.equal("Ana Smith-Realm", N.normalize(" Ana Smith-Realm "))
    end)

    it("returns an empty string for a blank string and nil for non-strings", function()
      assert.are.equal("", N.normalize("   "))
      assert.is_nil(N.normalize(nil))
      assert.is_nil(N.normalize(42))
      assert.is_nil(N.normalize({}))
    end)
  end)
end)
