local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("MorrisBoard", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    -- A board after placement: whites and blacks are lists of points.
    local function at(whites, blacks, turn, hand)
        local b = Board:new()
        for _, pt in ipairs(whites) do b.cells[pt] = 1 end
        for _, pt in ipairs(blacks) do b.cells[pt] = 2 end
        b.count = { #whites, #blacks }
        b.hand  = hand or { 0, 0 }
        b.turn  = turn or 1
        return b
    end

    local function contains(list, v)
        for _, x in ipairs(list) do if x == v then return true end end
        return false
    end

    describe("geometry", function()
        it("has 24 points, 16 mills and 32 symmetric lines", function()
            assert.are.equal(24, #Board.COORDS)
            assert.are.equal(16, #Board.MILLS)
            local edges = 0
            for a = 1, 24 do
                local n = #Board.ADJ[a]
                assert.is_true(n >= 2 and n <= 4)
                for _, b in ipairs(Board.ADJ[a]) do
                    assert.is_true(contains(Board.ADJ[b], a))
                    edges = edges + 1
                end
            end
            assert.are.equal(64, edges)     -- each line counted from both ends
        end)

        it("maps grid cells to points and back", function()
            for pt, rc in ipairs(Board.COORDS) do
                assert.are.equal(pt, Board.pointAt(rc[1], rc[2]))
            end
            assert.is_nil(Board.pointAt(4, 4))  -- the empty centre
            assert.is_nil(Board.pointAt(1, 2))
        end)
    end)

    describe("placing", function()
        it("starts with 9 pieces in hand each, White to place", function()
            local b = Board:new()
            assert.are.same({ 9, 9 }, b.hand)
            assert.are.equal("place", b:phase())
            assert.are.equal(24, #b:legalMoves())
        end)

        it("places on empty points only and alternates", function()
            local b = Board:new()
            assert.are.equal("ok", b:step(0, 1))
            assert.are.equal(2, b.turn)
            assert.are.equal("invalid", b:step(0, 1))
            assert.are.equal("invalid", b:step(3, 2))   -- no moving while placing
            assert.are.same({ 8, 9 }, b.hand)
        end)

        it("a mill asks for a removal, then the turn passes", function()
            local b = Board:new()
            for _, pt in ipairs({ 1, 10, 2, 11 }) do b:step(0, pt) end
            assert.are.equal("remove", b:step(0, 3))
            assert.are.equal("remove", b:phase())
            assert.are.equal(1, b.turn)
            assert.are.equal("invalid", b:remove(1))    -- own piece
            assert.are.equal("ok", b:remove(10))
            assert.are.equal(0, b.cells[10])
            assert.are.equal(1, b.count[2])
            assert.are.equal(2, b.turn)
            assert.are.equal(10, b.last.rem)
        end)
    end)

    describe("removal", function()
        it("protects pieces in a mill while others are free", function()
            local b = at({ 1, 10, 23 }, { 4, 5, 6, 24 }, 1)
            assert.are.equal("remove", b:step(23, 22))  -- 1-10-22 closes
            local rem = b:removablePoints()
            assert.are.same({ 24 }, rem)
            assert.are.equal("invalid", b:remove(5))
        end)

        it("allows any piece when every opponent piece is in a mill", function()
            local b = at({ 1, 10, 23 }, { 4, 5, 6 }, 1)
            b:step(23, 22)
            assert.are.equal(3, #b:removablePoints())
        end)
    end)

    describe("moving and flying", function()
        it("slides only along a line to an adjacent empty point", function()
            local b = at({ 1, 5, 9, 13 }, { 3, 15, 24, 23 }, 1)
            assert.are.equal("move", b:phase())
            assert.are.equal("invalid", b:step(1, 24))      -- not adjacent
            assert.are.same({ 2, 10 }, (function()
                local t = b:targetsFrom(1); table.sort(t); return t
            end)())
            assert.are.equal("ok", b:step(1, 2))
        end)

        it("flies anywhere with three pieces left", function()
            local b = at({ 1, 5, 9 }, { 3, 15, 24, 23 }, 1)
            assert.are.equal("fly", b:phase())
            assert.are.equal(17, #b:targetsFrom(1))
            assert.are.equal("ok", b:step(1, 20))
        end)
    end)

    describe("game end", function()
        it("a player down to two pieces loses", function()
            local b = at({ 1, 10, 23 }, { 4, 6, 24 }, 1)
            assert.are.equal("remove", b:step(23, 22))
            assert.are.equal("over", b:remove(24))
            assert.are.equal(1, b.winner)
            assert.are.equal("pieces", b.end_reason)
        end)

        it("a player with no legal move loses", function()
            -- Black's 4 pieces on the outer ring corners are all hemmed in.
            local b = at({ 2, 10, 15, 23, 5, 11, 14 }, { 1, 3, 22, 24 }, 1)
            b:step(5, 4)                -- any quiet White move hands Black the turn
            assert.are.equal("over", b.status)
            assert.are.equal(1, b.winner)
            assert.are.equal("blocked", b.end_reason)
        end)

        it("draws on the third occurrence of a position", function()
            local b = at({ 1, 5, 9, 13 }, { 3, 15, 24, 23 }, 1)
            local shuffle = { { 1, 2 }, { 23, 22 }, { 2, 1 }, { 22, 23 } }
            local r
            for i = 1, 8 do r = b:step(shuffle[(i - 1) % 4 + 1][1], shuffle[(i - 1) % 4 + 1][2]) end
            assert.are.equal("over", r)
            assert.are.equal(0, b.winner)
            assert.are.equal("repetition", b.end_reason)
        end)

        it("draws after 100 plies without a removal", function()
            local b = at({ 1, 5, 9, 13 }, { 3, 15, 24, 23 }, 1)
            b.no_mill = Board.NO_MILL_LIMIT - 1
            assert.are.equal("over", b:step(1, 2))
            assert.are.equal("limit", b.end_reason)
        end)
    end)

    describe("undo", function()
        it("takes back a whole turn, or a mill still awaiting its removal", function()
            local b = Board:new()
            for _, pt in ipairs({ 1, 10, 2, 11 }) do b:step(0, pt) end
            b:step(0, 3)
            assert.is_true(b:undo())            -- mid-turn: back before the mill
            assert.are.equal(0, b.cells[3])
            assert.is_nil(b.pending)
            assert.are.same({ 7, 7 }, b.hand)
            assert.are.equal(1, b.turn)
            b:undo()
            assert.are.equal(0, b.cells[11])
            assert.are.equal(2, b.turn)
        end)
    end)

    describe("serialize / load", function()
        it("round-trips cells, hands, turn and history", function()
            local b = Board:new()
            for _, pt in ipairs({ 1, 10, 2, 11 }) do b:step(0, pt) end
            b:step(0, 3); b:remove(10)
            local b2 = Board:new()
            assert.is_true(b2:load(b:serialize()))
            assert.are.same(b.cells, b2.cells)
            assert.are.same(b.hand, b2.hand)
            assert.are.same(b.count, b2.count)
            assert.are.equal(b.turn, b2.turn)
            assert.are.equal(#b.history, #b2.history)
            assert.are.equal(10, b2.last.rem)
        end)

        it("rejects malformed data", function()
            local b = Board:new()
            assert.is_false(b:load(nil))
            assert.is_false(b:load({}))
            local data = Board:new():serialize()
            data.count[1] = 3                   -- no white piece on the board
            assert.is_false(b:load(data))
        end)
    end)
end)
