-- Difficulty guarantees of the Nine Men's Morris computer opponent: the
-- level table is ordered, every level plays legal turns, closes a winning
-- mill and stops the opponent's, plays the same game under the same seed,
-- and stays within its think time at Kobo speed. No full matches.
local DIR = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
package.path = DIR .. "?.lua;" .. package.path

describe("Morris difficulty", function()
    local Board

    setup(function()
        Board = require("board")
    end)

    local IDS = { "easy", "medium", "hard" }
    local KOBO = 25     -- a Kobo Aura runs this Lua about 25x slower

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

    local function quick(id)
        local L = Board.LEVELS[id]
        return { depth = L.depth, budget = 0.01, noise = L.noise }
    end

    -- A clock that only moves when read (one read per 512 nodes, so hard stops after ~10k): the
    -- search stops after a bounded node count, the same on every machine.
    local function countClock()
        local t = 0
        return function() t = t + 0.05; return t end
    end

    local function lcg(seed)
        local x = seed
        return function()
            x = (x * 1103515245 + 12345) % 2147483648
            return x / 2147483648
        end
    end

    local function key(mv) return mv.from .. ">" .. mv.to .. "x" .. tostring(mv.rem) end

    -- Turns of the side to move that win the game at once.
    local function winningTurns(b)
        local p, out = b.turn, {}
        for _, mv in ipairs(b:legalMoves()) do
            if b:play(mv) == "over" and b.winner == p then out[#out + 1] = mv end
            b:undo()
        end
        return out
    end

    -- Positions from seeded random games where the side to move cannot win
    -- at once, some of its turns let the opponent win at once and at least
    -- one does not.
    local function threatPositions(want, seed)
        math.randomseed(seed)
        local out = {}
        for _ = 1, 300 do
            local b = Board:new()
            local plies = 0
            while b.status == "playing" and plies < 150 and #out < want do
                if #winningTurns(b) == 0 then
                    local safe, unsafe = {}, 0
                    for _, mv in ipairs(b:legalMoves()) do
                        local r = b:play(mv)
                        if r ~= "over" and #winningTurns(b) > 0 then
                            unsafe = unsafe + 1
                        else
                            safe[key(mv)] = true
                        end
                        b:undo()
                    end
                    if unsafe > 0 and next(safe) then
                        local snap = Board:new()
                        snap:load(b:serialize())
                        out[#out + 1] = { board = snap, safe = safe }
                    end
                end
                local all = b:legalMoves()
                b:play(all[math.random(#all)])
                plies = plies + 1
            end
            if #out >= want then break end
        end
        return out
    end

    it("orders the level table: deeper, longer and less noisy from Easy to Hard", function()
        local L = Board.LEVELS
        for i = 2, #IDS do
            local a, b = L[IDS[i - 1]], L[IDS[i]]
            assert.is_true(a.depth < b.depth)
            assert.is_true(a.budget <= b.budget)
            assert.is_true(a.noise > b.noise)
        end
        assert.are.equal(0, L.hard.noise)
        for _, id in ipairs(IDS) do assert.is_true(L[id].budget <= 2.5) end
    end)

    it("closes a mill and takes a piece when it can", function()
        local b = at({ 1, 2, 10 }, { 4, 21, 24 }, 1, { 5, 5 })
        local mv = Board.chooseMove(b, 1, { level = { depth = 1, budget = 1, noise = 0 } })
        assert.is_true(mv.to == 3 or mv.to == 22)
        assert.is_not_nil(mv.rem)
    end)

    it("blocks a threat first when its own two threats can wait", function()
        -- White threatens 3 and 22, Black threatens 5. Taking now lets
        -- Black take back; blocking 5 keeps White's double threat alive.
        local b = at({ 1, 2, 10 }, { 4, 6, 24 }, 1, { 5, 5 })
        local mv = Board.chooseMove(b, 1, { level = { depth = 4, budget = 5, noise = 0 } })
        assert.are.equal(5, mv.to)
    end)

    it("blocks an opponent mill while placing", function()
        local b = Board:new()
        b:step(0, 24); b:step(0, 1); b:step(0, 16); b:step(0, 2)
        local mv = Board.chooseMove(b, 1, { level = quick("hard") })
        assert.are.equal(3, mv.to)
    end)

    it("every level wins at once when it can, in random positions", function()
        math.randomseed(31)
        local checked = 0
        for _ = 1, 300 do
            if checked >= 10 then break end
            local b = Board:new()
            local plies = 0
            while b.status == "playing" and plies < 150 do
                if #winningTurns(b) > 0 then
                    local p = b.turn
                    for seed, lvl in ipairs(IDS) do
                        local mv = b:getAIMove(lvl, lcg(seed), countClock())
                        assert.are.equal("over", b:play(mv))
                        assert.are.equal(p, b.winner, lvl .. " missed a win")
                        b:undo()
                    end
                    checked = checked + 1
                    break
                end
                local all = b:legalMoves()
                b:play(all[math.random(#all)])
                plies = plies + 1
            end
        end
        assert.is_true(checked >= 5, "only " .. checked .. " positions found")
    end)

    it("every level stops the opponent from winning at once", function()
        local positions = threatPositions(5, 37)
        assert.is_true(#positions >= 3, "only " .. #positions .. " positions found")
        for _, pos in ipairs(positions) do
            for seed, lvl in ipairs(IDS) do
                local mv = pos.board:getAIMove(lvl, lcg(seed), countClock())
                assert.is_true(pos.safe[key(mv)] ~= nil,
                    lvl .. " let the opponent win (" .. key(mv) .. ")")
            end
        end
    end)

    it("always plays a legal turn, at every level, over random games", function()
        math.randomseed(7)
        for g = 1, 10 do
            local b = Board:new()
            local plies = 0
            while b.status == "playing" and plies < 150 do
                local mv
                if plies % 2 == 0 then
                    mv = Board.chooseMove(b, b.turn, { level = quick(IDS[g % 3 + 1]) })
                else
                    local all = b:legalMoves()
                    mv = all[math.random(#all)]
                end
                assert.is_not_nil(mv)
                assert.are_not.equal("invalid", b:play(mv))
                plies = plies + 1
            end
        end
    end)

    it("plays the same turns under the same seed, and Easy varies with it", function()
        local function line(lvl, seed)
            local b = Board:new()
            local rng = lcg(seed)
            local seq = {}
            for _ = 1, 12 do
                if b.status ~= "playing" then break end
                local mv = b:getAIMove(lvl, rng, countClock())
                seq[#seq + 1] = key(mv)
                b:play(mv)
            end
            return table.concat(seq, ",")
        end
        for _, lvl in ipairs(IDS) do
            assert.are.equal(line(lvl, 5), line(lvl, 5))
        end
        local seen, distinct = {}, 0
        for seed = 1, 5 do
            local s = line("easy", seed)
            if not seen[s] then seen[s] = true; distinct = distinct + 1 end
        end
        assert.is_true(distinct >= 2, "Easy played the same line for every seed")
    end)

    it("stays within its time budget", function()
        local b = at({ 1, 5, 9 }, { 3, 15, 24 }, 1)    -- both flying: widest tree
        local t0 = os.clock()
        local mv = Board.chooseMove(b, 1, { level = { depth = 30, budget = 0.05, noise = 0 } })
        assert.is_not_nil(mv)
        assert.is_true(os.clock() - t0 < 0.5)
    end)

    it("keeps every level within its budget at Kobo speed", function()
        -- A clock running 25x fast stops the search where a Kobo's would;
        -- the real time spent, scaled back, is the Kobo's wait.
        local kobo_clock = function() return os.clock() * KOBO end
        local positions = {
            Board:new(),
            at({ 1, 5, 9 }, { 3, 15, 24 }, 1),                       -- flying
            at({ 1, 2, 10, 13, 20 }, { 4, 6, 24, 17, 9 }, 1),        -- moving
        }
        local worst = 0
        for _, b in ipairs(positions) do
            for _, lvl in ipairs(IDS) do
                local t0 = os.clock()
                local mv = b:getAIMove(lvl, nil, kobo_clock)
                local dt = (os.clock() - t0) * KOBO
                assert.is_not_nil(mv)
                if dt > worst then worst = dt end
            end
        end
        assert.is_true(worst <= 2.5, string.format("slowest Kobo move %.2f s", worst))
    end)
end)
