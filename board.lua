-- ---------------------------------------------------------------------------
-- MorrisBoard — game logic and AI for Nine Men's Morris (jeu du moulin)
--
-- The 24 points, numbered row by row on a 7x7 grid (r, c):
--
--    1 ----------- 2 ----------- 3        row 1
--    |             |             |
--    |    4 ------ 5 ------ 6    |        row 2
--    |    |        |        |    |
--    |    |    7 - 8 - 9    |    |        row 3
--    |    |    |       |    |    |
--   10 - 11 - 12      13 - 14 - 15        row 4
--    |    |    |       |    |    |
--    |    |   16 -17 - 18   |    |        row 5
--    |    |        |        |    |
--    |   19 ----- 20 ----- 21    |        row 6
--    |             |             |
--   22 ---------- 23 ---------- 24        row 7
--
-- cells[i]: 0 empty, 1 White, 2 Black. White moves first.
--
-- Rules:
--   * Placing: each player has 9 pieces in hand and places one per turn.
--   * Moving: once a player's hand is empty they slide a piece along a line
--     to an adjacent empty point.
--   * Flying: a player down to 3 pieces may move a piece to any empty point.
--   * Closing a mill (three in a row on a line) removes an opponent piece —
--     not one standing in a mill, unless every opponent piece is in one.
--   * A player reduced to 2 pieces, or with no legal move, loses.
--   * Draw: a position seen for the third time, or 100 plies without a piece
--     being removed.
--
-- A turn is one move: { from, to, rem } — from 0 for a placement, rem the
-- removed opponent point (nil when the move closes no mill).
-- ---------------------------------------------------------------------------

local MorrisBoard = {}
MorrisBoard.__index = MorrisBoard

local NPOINTS       = 24
local PIECES        = 9
local REPEAT_LIMIT  = 3
local NO_MILL_LIMIT = 100

MorrisBoard.NPOINTS       = NPOINTS
MorrisBoard.NO_MILL_LIMIT = NO_MILL_LIMIT

-- Point coordinates on the 7x7 drawing grid.
local COORDS = {
    {1,1}, {1,4}, {1,7},
    {2,2}, {2,4}, {2,6},
    {3,3}, {3,4}, {3,5},
    {4,1}, {4,2}, {4,3}, {4,5}, {4,6}, {4,7},
    {5,3}, {5,4}, {5,5},
    {6,2}, {6,4}, {6,6},
    {7,1}, {7,4}, {7,7},
}
MorrisBoard.COORDS = COORDS

local POINT_AT = {}     -- [r * 10 + c] -> point
for i, rc in ipairs(COORDS) do POINT_AT[rc[1] * 10 + rc[2]] = i end

function MorrisBoard.pointAt(r, c)
    return POINT_AT[r * 10 + c]
end

-- The 16 mills: 8 horizontal, 8 vertical. Consecutive points of a mill are
-- exactly the board's lines, so the adjacency is derived from them.
local MILLS = {
    {1,2,3}, {4,5,6}, {7,8,9}, {10,11,12}, {13,14,15}, {16,17,18}, {19,20,21}, {22,23,24},
    {1,10,22}, {4,11,19}, {7,12,16}, {2,5,8}, {17,20,23}, {9,13,18}, {6,14,21}, {3,15,24},
}
MorrisBoard.MILLS = MILLS

local MILLS_OF = {}     -- point -> the two mills through it
local ADJ      = {}     -- point -> adjacent points
for i = 1, NPOINTS do MILLS_OF[i] = {}; ADJ[i] = {} end
for _, m in ipairs(MILLS) do
    for _, pt in ipairs(m) do
        local list = MILLS_OF[pt]
        list[#list + 1] = m
    end
    for k = 1, 2 do
        local a, b = m[k], m[k + 1]
        ADJ[a][#ADJ[a] + 1] = b
        ADJ[b][#ADJ[b] + 1] = a
    end
end
MorrisBoard.ADJ = ADJ

-- ---------------------------------------------------------------------------
-- Pure rule helpers on a bare state { cells, hand = {w, b}, count = {w, b} },
-- shared by the board and the search (which mutates it in place).
-- ---------------------------------------------------------------------------

local function inMill(cells, pt)
    local p = cells[pt]
    if p == 0 then return false end
    for _, m in ipairs(MILLS_OF[pt]) do
        if cells[m[1]] == p and cells[m[2]] == p and cells[m[3]] == p then
            return true
        end
    end
    return false
end

-- Would a piece of player p arriving at `to` (leaving `from`, 0 if placed)
-- close a mill?
local function closesMill(cells, p, from, to)
    for _, m in ipairs(MILLS_OF[to]) do
        local ok = true
        for k = 1, 3 do
            local q = m[k]
            if q ~= to and (q == from or cells[q] ~= p) then ok = false; break end
        end
        if ok then return true end
    end
    return false
end

-- Opponent points player p may remove after closing a mill.
local function removable(cells, p)
    local o = 3 - p
    local free, all = {}, {}
    for i = 1, NPOINTS do
        if cells[i] == o then
            all[#all + 1] = i
            if not inMill(cells, i) then free[#free + 1] = i end
        end
    end
    return (#free > 0) and free or all
end

local function phaseOf(st, p)
    if st.hand[p] > 0 then return "place" end
    if st.count[p] == 3 then return "fly" end
    return "move"
end

-- Every legal turn for player p, removals expanded. Mill-closing turns come
-- first: they are what alpha-beta wants to look at first.
local function genMoves(st, p)
    local cells = st.cells
    local steps = {}
    local phase = phaseOf(st, p)
    if phase == "place" then
        for i = 1, NPOINTS do
            if cells[i] == 0 then steps[#steps + 1] = { 0, i } end
        end
    else
        for i = 1, NPOINTS do
            if cells[i] == p then
                if phase == "fly" then
                    for j = 1, NPOINTS do
                        if cells[j] == 0 then steps[#steps + 1] = { i, j } end
                    end
                else
                    for _, j in ipairs(ADJ[i]) do
                        if cells[j] == 0 then steps[#steps + 1] = { i, j } end
                    end
                end
            end
        end
    end

    local mills, quiet = {}, {}
    for _, s in ipairs(steps) do
        local from, to = s[1], s[2]
        if closesMill(cells, p, from, to) then
            -- Removal is judged on the board after the piece has moved.
            if from > 0 then cells[from] = 0 end
            cells[to] = p
            local rem = removable(cells, p)
            cells[to] = 0
            if from > 0 then cells[from] = p end
            if #rem == 0 then
                mills[#mills + 1] = { from = from, to = to }
            else
                for _, r in ipairs(rem) do
                    mills[#mills + 1] = { from = from, to = to, rem = r }
                end
            end
        else
            quiet[#quiet + 1] = { from = from, to = to }
        end
    end
    for _, mv in ipairs(quiet) do mills[#mills + 1] = mv end
    return mills
end

local function applyMove(st, p, mv)
    if mv.from == 0 then
        st.hand[p]  = st.hand[p] - 1
        st.count[p] = st.count[p] + 1
    else
        st.cells[mv.from] = 0
    end
    st.cells[mv.to] = p
    if mv.rem then
        st.cells[mv.rem] = 0
        st.count[3 - p] = st.count[3 - p] - 1
    end
end

local function unapplyMove(st, p, mv)
    if mv.rem then
        st.cells[mv.rem] = 3 - p
        st.count[3 - p] = st.count[3 - p] + 1
    end
    st.cells[mv.to] = 0
    if mv.from == 0 then
        st.hand[p]  = st.hand[p] + 1
        st.count[p] = st.count[p] - 1
    else
        st.cells[mv.from] = p
    end
end

-- Has player p lost before moving? (fewer than 3 pieces, or blocked)
local function material(st, p)
    return st.hand[p] + st.count[p]
end

MorrisBoard.genMoves    = genMoves
MorrisBoard.applyMove   = applyMove
MorrisBoard.unapplyMove = unapplyMove
MorrisBoard.inMill      = inMill
MorrisBoard.closesMill  = closesMill
MorrisBoard.removable   = removable

-- ---------------------------------------------------------------------------
-- Constructor / reset
-- ---------------------------------------------------------------------------

function MorrisBoard:new()
    local o = setmetatable({}, self)
    o:reset()
    return o
end

function MorrisBoard:reset()
    self.cells = {}
    for i = 1, NPOINTS do self.cells[i] = 0 end
    self.hand        = { PIECES, PIECES }
    self.count       = { 0, 0 }
    self.turn        = 1
    self.status      = "playing"    -- "playing" | "over"
    self.winner      = nil          -- 1, 2, or 0 for a draw
    self.end_reason  = nil          -- "pieces" | "blocked" | "repetition" | "limit"
    self.pending     = nil          -- { from, to } awaiting a removal
    self.last        = nil          -- last full turn { from, to, rem }
    self.no_mill     = 0
    self.history     = {}           -- snapshots before each turn (undo + repetition)
end

-- ---------------------------------------------------------------------------
-- Queries (for the screen)
-- ---------------------------------------------------------------------------

-- "place" | "move" | "fly" | "remove" for the side to play.
function MorrisBoard:phase()
    if self.pending then return "remove" end
    return phaseOf(self, self.turn)
end

function MorrisBoard:legalMoves()
    if self.status ~= "playing" or self.pending then return {} end
    return genMoves(self, self.turn)
end

-- Points the piece on `from` can go to (for a highlight).
function MorrisBoard:targetsFrom(from)
    local t = {}
    if self.status ~= "playing" or self.pending or self.cells[from] ~= self.turn then
        return t
    end
    local phase = phaseOf(self, self.turn)
    if phase == "fly" then
        for j = 1, NPOINTS do if self.cells[j] == 0 then t[#t + 1] = j end end
    elseif phase == "move" then
        for _, j in ipairs(ADJ[from]) do if self.cells[j] == 0 then t[#t + 1] = j end end
    end
    return t
end

function MorrisBoard:removablePoints()
    if not self.pending then return {} end
    return removable(self.cells, self.turn)
end

function MorrisBoard:inMill(pt)
    return inMill(self.cells, pt)
end

local function positionKey(st, turn)
    return table.concat(st.cells) .. "/" .. st.hand[1] .. "/" .. st.hand[2] .. "/" .. turn
end

function MorrisBoard:_repetitions()
    local key = positionKey(self, self.turn)
    local n = 1
    for _, snap in ipairs(self.history) do
        if positionKey(snap, snap.turn) == key then n = n + 1 end
    end
    return n
end

-- ---------------------------------------------------------------------------
-- Playing
-- ---------------------------------------------------------------------------

local function copyArr(t)
    local c = {}
    for i = 1, #t do c[i] = t[i] end
    return c
end

function MorrisBoard:_snapshot()
    local last = self.last and { from = self.last.from, to = self.last.to, rem = self.last.rem }
    return {
        cells = copyArr(self.cells), hand = copyArr(self.hand), count = copyArr(self.count),
        turn = self.turn, last = last, no_mill = self.no_mill,
    }
end

function MorrisBoard:_restore(snap)
    self.cells   = copyArr(snap.cells)
    self.hand    = copyArr(snap.hand)
    self.count   = copyArr(snap.count)
    self.turn    = snap.turn
    self.last    = snap.last
    self.no_mill = snap.no_mill
    self.pending = nil
    self.status, self.winner, self.end_reason = "playing", nil, nil
end

-- Called with the next player to move already set.
function MorrisBoard:_checkEnd()
    local p = self.turn
    if material(self, p) < 3 then
        self.status, self.winner, self.end_reason = "over", 3 - p, "pieces"
    elseif #genMoves(self, p) == 0 then
        self.status, self.winner, self.end_reason = "over", 3 - p, "blocked"
    elseif self:_repetitions() >= REPEAT_LIMIT then
        self.status, self.winner, self.end_reason = "over", 0, "repetition"
    elseif self.no_mill >= NO_MILL_LIMIT then
        self.status, self.winner, self.end_reason = "over", 0, "limit"
    end
end

function MorrisBoard:_endTurn(rem)
    self.last    = { from = self.pending.from, to = self.pending.to, rem = rem }
    self.pending = nil
    self.no_mill = rem and 0 or (self.no_mill + 1)
    self.turn    = 3 - self.turn
    self:_checkEnd()
end

-- First half of a turn: place (from = 0) or move a piece.
-- Returns "invalid", "remove" (a mill closed: call remove next), "ok" or "over".
function MorrisBoard:step(from, to)
    if self.status ~= "playing" or self.pending then return "invalid" end
    local p = self.turn
    local phase = phaseOf(self, p)
    if self.cells[to] ~= 0 then return "invalid" end
    if phase == "place" then
        if from ~= 0 then return "invalid" end
    else
        if from == 0 or self.cells[from] ~= p then return "invalid" end
        if phase == "move" then
            local adjacent = false
            for _, j in ipairs(ADJ[from]) do if j == to then adjacent = true end end
            if not adjacent then return "invalid" end
        end
    end

    self.history[#self.history + 1] = self:_snapshot()
    local mill = closesMill(self.cells, p, from, to)
    if from == 0 then
        self.hand[p]  = self.hand[p] - 1
        self.count[p] = self.count[p] + 1
    else
        self.cells[from] = 0
    end
    self.cells[to] = p
    self.pending = { from = from, to = to }
    -- A mill with no opponent piece on the board removes nothing.
    if mill and self.count[3 - p] > 0 then return "remove" end
    self:_endTurn(nil)
    return self.status == "over" and "over" or "ok"
end

-- Second half of a turn after a mill. Returns "invalid", "ok" or "over".
function MorrisBoard:remove(pt)
    if self.status ~= "playing" or not self.pending then return "invalid" end
    local ok = false
    for _, r in ipairs(removable(self.cells, self.turn)) do
        if r == pt then ok = true end
    end
    if not ok then return "invalid" end
    self.cells[pt] = 0
    self.count[3 - self.turn] = self.count[3 - self.turn] - 1
    self:_endTurn(pt)
    return self.status == "over" and "over" or "ok"
end

-- A whole turn at once ({ from, to, rem }), as the AI produces them.
function MorrisBoard:play(mv)
    local r = self:step(mv.from, mv.to)
    if r == "remove" then
        r = self:remove(mv.rem)
        if r == "invalid" then self:undo() end
    end
    return r
end

-- Take back one turn (or the first half of one awaiting its removal).
function MorrisBoard:undo()
    local snap = table.remove(self.history)
    if not snap then return false end
    self:_restore(snap)
    return true
end

function MorrisBoard:canUndo()
    return #self.history > 0
end

-- ---------------------------------------------------------------------------
-- AI — negamax with alpha-beta, iterative deepening and a time budget
-- ---------------------------------------------------------------------------

local WIN_SCORE = 100000
local INF       = 1e9

-- depth: deepest iteration; budget: think time in seconds (CPU time, so a
-- slower device searches less deep instead of taking longer); noise: a random
-- bonus added to each root move's score before choosing (one piece = 100).
MorrisBoard.LEVELS = {
    easy   = { depth = 2,  budget = 0.3, noise = 120 },
    medium = { depth = 3,  budget = 0.6, noise = 20 },
    hard   = { depth = 30, budget = 1.0, noise = 0 },
}

-- Count, for player p, lines holding two of p's pieces and an empty point
-- (a mill one move away), and the number of p's slides available.
local function lineFeatures(cells, p)
    local twos = 0
    for _, m in ipairs(MILLS) do
        local mine, empty = 0, 0
        for k = 1, 3 do
            local v = cells[m[k]]
            if v == p then mine = mine + 1 elseif v == 0 then empty = empty + 1 end
        end
        if mine == 2 and empty == 1 then twos = twos + 1 end
    end
    return twos
end

local function mobility(cells, p)
    local n = 0
    for i = 1, NPOINTS do
        if cells[i] == p then
            for _, j in ipairs(ADJ[i]) do
                if cells[j] == 0 then n = n + 1 end
            end
        end
    end
    return n
end

-- Static evaluation from p's point of view.
local function evaluate(st, p)
    local o = 3 - p
    local cells = st.cells
    local score = 100 * (material(st, p) - material(st, o))
    score = score + 12 * (lineFeatures(cells, p) - lineFeatures(cells, o))
    -- Mobility only matters to a side that slides; one that places or flies
    -- can always move.
    if phaseOf(st, p) == "move" then score = score + 4 * mobility(cells, p) end
    if phaseOf(st, o) == "move" then score = score - 4 * mobility(cells, o) end
    return score
end

local function search(ctx, st, p, depth, alpha, beta, ply)
    ctx.nodes = ctx.nodes + 1
    if ctx.abortable and ctx.nodes % 256 == 0 and ctx.clock() > ctx.deadline then
        ctx.aborted = true
    end
    if ctx.aborted then return 0 end

    if material(st, p) < 3 then return -(WIN_SCORE - ply) end
    local moves = genMoves(st, p)
    if #moves == 0 then return -(WIN_SCORE - ply) end
    if depth <= 0 then return evaluate(st, p) end

    local best = -INF
    for k = 1, #moves do
        local mv = moves[k]
        applyMove(st, p, mv)
        local v = -search(ctx, st, 3 - p, depth - 1, -beta, -alpha, ply + 1)
        unapplyMove(st, p, mv)
        if ctx.aborted then return 0 end
        if v > best then best = v end
        if v > alpha then alpha = v end
        if alpha >= beta then break end
    end
    return best
end

local function searchRoot(ctx, st, p, order, depth, exact)
    local scores = {}
    local alpha, best = -INF, nil
    for k = 1, #order do
        local mv = order[k]
        applyMove(st, p, mv)
        local a = exact and -INF or alpha
        local v = -search(ctx, st, 3 - p, depth - 1, -INF, -a, 1)
        unapplyMove(st, p, mv)
        if ctx.aborted then return nil end
        scores[k] = v
        -- Strictly better only: a sibling that failed low returns a bound
        -- that may equal alpha, and must not displace the move that set it.
        if v > alpha then alpha, best = v, k end
    end
    return scores, best
end

-- Pure entry point. st: { cells, hand, count } (copied, never mutated).
-- opts: level ({depth, budget, noise}), rng, clock. Returns move, info.
function MorrisBoard.chooseMove(st0, p, opts)
    local st = { cells = copyArr(st0.cells), hand = copyArr(st0.hand), count = copyArr(st0.count) }
    local moves = genMoves(st, p)
    if #moves == 0 then return nil end
    local level = opts.level or MorrisBoard.LEVELS.medium
    local rng   = opts.rng or math.random
    local clock = opts.clock or os.clock
    if #moves == 1 then return moves[1], { depth = 0, nodes = 0 } end

    local start = clock()
    local ctx = {
        nodes = 0, clock = clock, deadline = start + level.budget,
        aborted = false, abortable = false,
    }
    local exact = (level.noise or 0) > 0
    local order = moves
    local scores, reached

    for d = 1, level.depth do
        ctx.abortable = d > 1           -- depth 1 always completes
        local s, bi = searchRoot(ctx, st, p, order, d, exact)
        if not s then break end
        reached = d
        -- Reorder best first for the next iteration (stable on ties so the
        -- move that set alpha stays ahead of siblings that only matched it).
        local idx = {}
        for k = 1, #order do idx[k] = k end
        table.sort(idx, function(a, b)
            if a == bi or b == bi then return a == bi end
            if s[a] ~= s[b] then return s[a] > s[b] end
            return a < b
        end)
        local new_order, new_scores = {}, {}
        for k, i in ipairs(idx) do new_order[k] = order[i]; new_scores[k] = s[i] end
        order, scores = new_order, new_scores
        if scores[1] >= WIN_SCORE - 1000 then break end         -- forced win found
        if clock() - start > level.budget * 0.4 then break end  -- next one won't fit
    end

    local best = 1
    if exact then
        local best_v = -INF
        for k = 1, #order do
            local v = scores[k] + rng() * level.noise
            if v > best_v then best, best_v = k, v end
        end
    end
    return order[best], { depth = reached, nodes = ctx.nodes, score = scores[1] }
end

-- AI turn for the side to play. level_id: "easy" | "medium" | "hard".
function MorrisBoard:getAIMove(level_id, rng, clock)
    if self.status ~= "playing" or self.pending then return nil end
    return MorrisBoard.chooseMove(self, self.turn, {
        level = MorrisBoard.LEVELS[level_id] or MorrisBoard.LEVELS.medium,
        rng = rng, clock = clock,
    })
end

-- ---------------------------------------------------------------------------
-- Serialization
-- ---------------------------------------------------------------------------

local function validState(t)
    if type(t) ~= "table" or type(t.cells) ~= "table"
            or type(t.hand) ~= "table" or type(t.count) ~= "table" then
        return false
    end
    for i = 1, NPOINTS do
        local v = t.cells[i]
        if v ~= 0 and v ~= 1 and v ~= 2 then return false end
    end
    for p = 1, 2 do
        if type(t.hand[p]) ~= "number" or type(t.count[p]) ~= "number" then return false end
    end
    return true
end

local function copyMove(mv)
    return mv and { from = mv.from, to = mv.to, rem = mv.rem } or nil
end

function MorrisBoard:serialize()
    local hist = {}
    for i, snap in ipairs(self.history) do
        hist[i] = {
            cells = copyArr(snap.cells), hand = copyArr(snap.hand), count = copyArr(snap.count),
            turn = snap.turn, last = copyMove(snap.last), no_mill = snap.no_mill,
        }
    end
    return {
        cells = copyArr(self.cells), hand = copyArr(self.hand), count = copyArr(self.count),
        turn = self.turn, status = self.status, winner = self.winner,
        end_reason = self.end_reason, pending = copyMove(self.pending),
        last = copyMove(self.last), no_mill = self.no_mill, history = hist,
    }
end

function MorrisBoard:load(data)
    if not validState(data) then return false end
    -- The piece count must match the cells, or the rules would misfire.
    for p = 1, 2 do
        local n = 0
        for i = 1, NPOINTS do if data.cells[i] == p then n = n + 1 end end
        if n ~= data.count[p] then return false end
    end
    self:reset()
    self.cells      = copyArr(data.cells)
    self.hand       = copyArr(data.hand)
    self.count      = copyArr(data.count)
    self.turn       = (data.turn == 2) and 2 or 1
    self.status     = (data.status == "over") and "over" or "playing"
    self.winner     = data.winner
    self.end_reason = data.end_reason
    self.pending    = copyMove(data.pending)
    self.last       = copyMove(data.last)
    self.no_mill    = data.no_mill or 0
    if type(data.history) == "table" then
        for i, snap in ipairs(data.history) do
            if not validState(snap) then break end
            self.history[i] = {
                cells = copyArr(snap.cells), hand = copyArr(snap.hand), count = copyArr(snap.count),
                turn = snap.turn, last = copyMove(snap.last), no_mill = snap.no_mill or 0,
            }
        end
    end
    return true
end

return MorrisBoard
