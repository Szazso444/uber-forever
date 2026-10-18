describe("Board", function()
  local ns, B

  before_each(function()
    ns = Taxi.load()
    B = ns.Board
  end)

  it("expires and tracks changes", function()
    local b = B.new(); B.upsert(b, {standId="s", owner="A B", mapID=1, wx=0, wy=0, zone="Z", subzone="S", seenAt=0}, 0)
    B.upsert(b, {standId="s", owner="A B", mapID=1, wx=0, wy=0, zone="Z", subzone="S", seenAt=60}, 60); assert.are.equal(0, B.get(b, "s").changedAt)
    B.upsert(b, {standId="s", owner="A B", mapID=2, wx=0, wy=0, zone="Y", subzone="S", seenAt=90}, 90); assert.are.equal(90, B.get(b, "s").changedAt)
    B.expire(b, 271); assert.is_nil(B.get(b, "s"))
  end)

  it("sorts guild first then score then count", function()
    local b = B.new()
    for i, o in ipairs({"Ann A", "Bob B", "Cid C"}) do B.upsert(b, {standId="s"..i, owner=o, kind="lock", faction="Alliance", seenAt=0}, 0) end
    local rank = {["Ann A"]={4.0, 10}, ["Bob B"]={4.5, 2}, ["Cid C"]={3.0, 50}}
    local l = B.list(b, {kind="lock", faction="Alliance", isGuildmate=function(n) return n == "Cid C" end, rank=function(n) return rank[n][1], rank[n][2] end})
    assert.are.same({"Cid C", "Bob B", "Ann A"}, {l[1].owner, l[2].owner, l[3].owner})
  end)

  local function view(id, owner, extra)
    local v = {standId=id, owner=owner, kind="lock", faction="Alliance", mapID=1, wx=0, wy=0, zone="Z", subzone="S", seenAt=0}
    for k, val in pairs(extra or {}) do v[k] = val end
    return v
  end

  describe("upsert", function()
    it("stamps changedAt on the first insert", function()
      local b = B.new()
      B.upsert(b, view("s", "A B"), 30)
      assert.are.equal(30, B.get(b, "s").changedAt)
    end)

    it("keeps changedAt while the stand stays put, whatever else changes", function()
      local b = B.new()
      B.upsert(b, view("s", "A B", {seatsFree=3}), 0)
      B.upsert(b, view("s", "A B", {seatsFree=1, clickers=2, note="hi", seenAt=60}), 60)
      local got = B.get(b, "s")
      assert.are.equal(0, got.changedAt)
      assert.are.equal(1, got.seatsFree)
      assert.are.equal(60, got.seenAt)
    end)

    for _, change in ipairs({
      {"mapID", 2}, {"wx", 5}, {"wy", 5}, {"zone", "Other"}, {"subzone", "Elsewhere"},
    }) do
      it("moves changedAt when " .. change[1] .. " differs", function()
        local b = B.new()
        B.upsert(b, view("s", "A B"), 0)
        B.upsert(b, view("s", "A B", {[change[1]] = change[2], seenAt=60}), 60)
        assert.are.equal(60, B.get(b, "s").changedAt)
      end)
    end

    it("carries changedAt forward across later unchanged heartbeats", function()
      local b = B.new()
      B.upsert(b, view("s", "A B"), 0)
      B.upsert(b, view("s", "A B", {zone="Y"}), 60)
      B.upsert(b, view("s", "A B", {zone="Y", seenAt=120}), 120)
      assert.are.equal(60, B.get(b, "s").changedAt)
    end)

    it("keeps other stands apart", function()
      local b = B.new()
      B.upsert(b, view("s1", "A B"), 0)
      B.upsert(b, view("s2", "C D", {zone="Y"}), 10)
      assert.are.equal(0, B.get(b, "s1").changedAt)
      assert.are.equal(10, B.get(b, "s2").changedAt)
    end)

    it("stamps seenAt when the view has none", function()
      local b = B.new()
      B.upsert(b, view("s", "A B", {seenAt=false}), 12)
      assert.are.equal(12, B.get(b, "s").seenAt)
    end)
  end)

  describe("remove and get", function()
    it("removes a stand and tolerates an unknown id", function()
      local b = B.new()
      B.upsert(b, view("s", "A B"), 0)
      B.remove(b, "nope")
      assert.is_not_nil(B.get(b, "s"))
      B.remove(b, "s")
      assert.is_nil(B.get(b, "s"))
    end)

    it("a removed stand is a first insert again", function()
      local b = B.new()
      B.upsert(b, view("s", "A B"), 0)
      B.remove(b, "s")
      B.upsert(b, view("s", "A B"), 500)
      assert.are.equal(500, B.get(b, "s").changedAt)
    end)
  end)

  describe("expire", function()
    it("drops only stands silent for longer than the TTL", function()
      local b = B.new()
      B.upsert(b, view("old", "A B", {seenAt=0}), 0)
      B.upsert(b, view("edge", "C D", {seenAt=20}), 20)
      B.upsert(b, view("new", "E F", {seenAt=100}), 100)
      B.expire(b, 200)
      assert.is_nil(B.get(b, "old"))
      assert.is_not_nil(B.get(b, "edge"))   -- exactly STAND_TTL (180) old: kept
      assert.is_not_nil(B.get(b, "new"))
    end)

    it("is measured from the last heartbeat, not the first", function()
      local b = B.new()
      B.upsert(b, view("s", "A B", {seenAt=0}), 0)
      B.upsert(b, view("s", "A B", {seenAt=150}), 150)
      B.expire(b, 300)
      assert.is_not_nil(B.get(b, "s"))
      B.expire(b, 331)
      assert.is_nil(B.get(b, "s"))
    end)
  end)

  describe("list", function()
    local function owners(l)
      local out = {}
      for i, v in ipairs(l) do out[i] = v.owner end
      return out
    end

    it("filters by kind and faction", function()
      local b = B.new()
      B.upsert(b, view("s1", "Ann A"), 0)
      B.upsert(b, view("s2", "Bob B", {kind="mage"}), 0)
      B.upsert(b, view("s3", "Cid C", {faction="Horde"}), 0)
      assert.are.same({"Ann A"}, owners(B.list(b, {kind="lock", faction="Alliance"})))
      assert.are.same({"Bob B"}, owners(B.list(b, {kind="mage", faction="Alliance"})))
      assert.are.same({"Cid C"}, owners(B.list(b, {kind="lock", faction="Horde"})))
    end)

    it("filters by exact zone when asked", function()
      local b = B.new()
      B.upsert(b, view("s1", "Ann A", {zone="Tanaris"}), 0)
      B.upsert(b, view("s2", "Bob B", {zone="Tanaris Desert"}), 0)
      B.upsert(b, view("s3", "Cid C", {zone="Durotar"}), 0)
      assert.are.same({"Ann A"}, owners(B.list(b, {zone="Tanaris"})))
      assert.are.same({"Ann A", "Bob B", "Cid C"}, owners(B.list(b, {})))
    end)

    it("filters by status when asked (R69)", function()
      local b = B.new()
      B.upsert(b, view("s1", "Ann A", {status="live"}), 0)
      B.upsert(b, view("s2", "Bob B", {status="paused"}), 0)
      B.upsert(b, view("s3", "Cid C", {status="recruiting"}), 0)
      B.upsert(b, view("s4", "Dee D"), 0) -- no status
      assert.are.same({"Ann A", "Bob B"}, owners(B.list(b, {statuses={live=true, paused=true}})))
      assert.are.same({"Bob B", "Cid C"}, owners(B.list(b, {statuses={recruiting=true, paused=true}})))
      assert.are.same({"Ann A", "Bob B", "Cid C", "Dee D"}, owners(B.list(b, {})))
    end)

    it("breaks ties by score, then count, then owner name", function()
      local b = B.new()
      for i, o in ipairs({"Zed Z", "Amy A", "Max M", "Eve E", "Dan D"}) do B.upsert(b, view("s"..i, o), 0) end
      local rank = {
        ["Zed Z"] = {4, 10}, ["Amy A"] = {4, 10}, ["Max M"] = {4, 20}, ["Eve E"] = {5, 1}, ["Dan D"] = {3, 99},
      }
      local l = B.list(b, {rank=function(n) return rank[n][1], rank[n][2] end})
      assert.are.same({"Eve E", "Max M", "Amy A", "Zed Z", "Dan D"}, owners(l))
    end)

    it("puts every guildmate ahead of every other stand, ranked among themselves", function()
      local b = B.new()
      for i, o in ipairs({"Ann A", "Bob B", "Cid C", "Dee D"}) do B.upsert(b, view("s"..i, o), 0) end
      local rank = {["Ann A"]={5, 100}, ["Bob B"]={1, 1}, ["Cid C"]={2, 1}, ["Dee D"]={4.9, 1}}
      local l = B.list(b, {
        isGuildmate = function(n) return n == "Bob B" or n == "Cid C" end,
        rank = function(n) return rank[n][1], rank[n][2] end,
      })
      assert.are.same({"Cid C", "Bob B", "Ann A", "Dee D"}, owners(l))
    end)

    it("works without a rank or guild function", function()
      local b = B.new()
      B.upsert(b, view("s1", "Bob B"), 0)
      B.upsert(b, view("s2", "Ann A"), 0)
      assert.are.same({"Ann A", "Bob B"}, owners(B.list(b, {})))
      assert.are.same({"Ann A", "Bob B"}, owners(B.list(b)))
    end)

    it("keeps only an owner's newest stand: a new id replaces the older one (M6)", function()
      local b = B.new()
      assert.is_true(B.upsert(b, view("Ann A@100", "Ann A"), 0)) -- stored
      B.upsert(b, view("Bob B@100", "Bob B"), 0)
      assert.is_true(B.upsert(b, view("Ann A@200", "Ann A"), 10))
      assert.is_nil(B.get(b, "Ann A@100"))
      assert.are.same({"Ann A@200", "Bob B@100"}, {B.list(b, {})[1].standId, B.list(b, {})[2].standId})
      -- A late heartbeat of the old stand does not bring it back, nor push the new one out.
      assert.is_false(B.upsert(b, view("Ann A@100", "Ann A"), 20)) -- not stored
      assert.is_nil(B.get(b, "Ann A@100"))
      assert.is_not_nil(B.get(b, "Ann A@200"))
      -- Owners are compared as names; ids that carry no time go by the one heard last.
      B.upsert(b, view("s9", " Ann  A "), 30)
      assert.is_not_nil(B.get(b, "s9"))
      assert.is_nil(B.get(b, "Ann A@200"))
      assert.is_not_nil(B.get(b, "Bob B@100"))
    end)

    it("asks about each stand once, not once per comparison", function()
      local b = B.new()
      for i, o in ipairs({"Ann A", "Bob B", "Cid C"}) do B.upsert(b, view("s"..i, o), 0) end
      local calls = 0
      B.list(b, {
        isGuildmate = function() calls = calls + 1; return false end,
        rank = function() calls = calls + 1; return 3, 1 end,
      })
      assert.are.equal(6, calls)
    end)

    it("returns the stored views and an empty array for an empty board", function()
      local b = B.new()
      assert.are.same({}, B.list(b, {}))
      B.upsert(b, view("s", "A B"), 0)
      assert.are.equal(B.get(b, "s"), B.list(b, {})[1])
    end)
  end)

  -- R51: a stand past its TTL is gone when read, not only when the sweep runs.
  describe("reading at a time (R51)", function()
    local TTL = 180

    it("get hides a stand silent for longer than STAND_TTL, and keeps one exactly STAND_TTL old", function()
      assert.are.equal(TTL, Taxi.load().Config.STAND_TTL)
      local b = B.new()
      B.upsert(b, view("s", "A B", {seenAt=10}), 10)
      assert.is_not_nil(B.get(b, "s", 10 + TTL))
      assert.is_nil(B.get(b, "s", 10 + TTL + 0.5))
      assert.is_nil(B.get(b, "s", 10 + TTL + 3600))
    end)

    it("does not remove the entry: only expire does", function()
      local b = B.new()
      B.upsert(b, view("s", "A B", {seenAt=0}), 0)
      assert.is_nil(B.get(b, "s", TTL + 1))
      assert.is_not_nil(b.stands.s)
      B.expire(b, TTL + 1)
      assert.is_nil(b.stands.s)
    end)

    it("get without a time reads the board as it is", function()
      local b = B.new()
      B.upsert(b, view("s", "A B", {seenAt=0}), 0)
      assert.is_not_nil(B.get(b, "s"))
    end)

    it("is measured from the last heartbeat", function()
      local b = B.new()
      B.upsert(b, view("s", "A B", {seenAt=0}), 0)
      B.upsert(b, view("s", "A B", {seenAt=150}), 150)
      assert.is_not_nil(B.get(b, "s", 150 + TTL))
      assert.is_nil(B.get(b, "s", 150 + TTL + 1))
    end)

    it("list leaves out stands past the TTL when given now", function()
      local b = B.new()
      B.upsert(b, view("old", "Ann A", {seenAt=0}), 0)
      B.upsert(b, view("edge", "Bob B", {seenAt=20}), 20)
      B.upsert(b, view("new", "Cid C", {seenAt=100}), 100)
      local function ids(l)
        local out = {}
        for i, v in ipairs(l) do out[i] = v.standId end
        return out
      end
      assert.are.same({"edge", "new", "old"}, ids(B.list(b, {rank=function(n) return n == "Ann A" and 1 or 2, 0 end})))
      assert.are.same({"edge", "new"}, ids(B.list(b, {now=200})))
      assert.are.same({"new"}, ids(B.list(b, {now=201})))
      assert.are.same({}, ids(B.list(b, {now=281})))
    end)

    it("list never asks about a stand it leaves out", function()
      local b = B.new()
      B.upsert(b, view("old", "Ann A", {seenAt=0}), 0)
      B.upsert(b, view("new", "Bob B", {seenAt=100}), 100)
      local asked = {}
      B.list(b, {now=200, rank=function(n) asked[#asked + 1] = n; return 3, 1 end})
      assert.are.same({"Bob B"}, asked)
    end)
  end)
end)
