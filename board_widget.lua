-- ---------------------------------------------------------------------------
-- MorrisBoardWidget — draws the three nested squares and the pieces
--
-- The 24 points sit on a 7x7 grid, so GridWidgetBase's square cells give the
-- sizing and the tap-to-cell mapping for free; a tap on a cell with no point
-- is ignored.
-- ---------------------------------------------------------------------------

local Blitbuffer = require("ffi/blitbuffer")
local Geom       = require("ui/geometry")

local gwb              = require("grid_widget_base")
local GridWidgetBase   = gwb.GridWidgetBase
local drawLine         = gwb.drawLine
local drawDiagonalLine = gwb.drawDiagonalLine

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end
local MorrisBoard = lrequire("board")

local C_BG     = Blitbuffer.COLOR_WHITE
local C_INK    = Blitbuffer.COLOR_BLACK
local C_LINE   = Blitbuffer.COLOR_GRAY_4
local C_WHITE  = Blitbuffer.COLOR_WHITE
local C_SHADE  = Blitbuffer.COLOR_GRAY_9

local MorrisBoardWidget = GridWidgetBase:extend{
    board         = nil,
    size_ratio    = 0.82,
    highlight     = nil,    -- function() -> { selected = pt, targets = set, removable = set }
    onPointAction = nil,    -- function(pt)
}

function MorrisBoardWidget:init()
    self.cols = 7
    self.rows = 7
    GridWidgetBase.init(self)
end

function MorrisBoardWidget:onCellTap(row, col)
    local pt = MorrisBoard.pointAt(row, col)
    if pt and self.onPointAction then self.onPointAction(pt) end
end

function MorrisBoardWidget:_centre(x, y, pt)
    local rc = MorrisBoard.COORDS[pt]
    return x + math.floor((rc[2] - 0.5) * self.cell_w),
           y + math.floor((rc[1] - 0.5) * self.cell_h)
end

local function drawCross(bb, cx, cy, half, color, t)
    drawDiagonalLine(bb, cx - half, cy - half, 2 * half, 1, 1, color, t)
    drawDiagonalLine(bb, cx - half, cy + half, 2 * half, 1, -1, color, t)
end

function MorrisBoardWidget:paintTo(bb, x, y)
    self.paint_rect = Geom:new{ x = x, y = y, w = self.dimen.w, h = self.dimen.h }
    local board = self.board
    local cell  = math.min(self.cell_w, self.cell_h)
    local hl    = self.highlight and self.highlight() or {}
    local targets, removable = hl.targets or {}, hl.removable or {}

    bb:paintRect(x, y, self.dimen.w, self.dimen.h, C_BG)

    -- Lines: every mill is a straight segment from its first to last point.
    local lw = math.max(2, math.floor(cell * 0.04))
    local half = math.floor(lw / 2)
    for _, m in ipairs(MorrisBoard.MILLS) do
        local x1, y1 = self:_centre(x, y, m[1])
        local x3, y3 = self:_centre(x, y, m[3])
        if y1 == y3 then
            drawLine(bb, x1 - half, y1 - half, x3 - x1 + lw, lw, C_LINE)
        else
            drawLine(bb, x1 - half, y1 - half, lw, y3 - y1 + lw, C_LINE)
        end
    end

    local piece_r = math.floor(cell * 0.36)
    local ring    = math.max(2, math.floor(cell * 0.06))
    local last    = board.last

    for pt = 1, MorrisBoard.NPOINTS do
        local cx, cy = self:_centre(x, y, pt)
        local v = board.cells[pt]
        if v == 0 then
            bb:paintCircle(cx, cy, math.max(3, math.floor(cell * 0.09)), C_INK)
            if targets[pt] then
                bb:paintCircle(cx, cy, math.floor(cell * 0.22), C_INK, ring)
            end
            if last and last.rem == pt then
                drawCross(bb, cx, cy, math.floor(cell * 0.2), C_SHADE, ring)
            end
        else
            if hl.selected == pt then
                bb:paintCircle(cx, cy, piece_r + 2 * ring, C_INK, ring)
            end
            if v == 1 then
                bb:paintCircle(cx, cy, piece_r, C_WHITE)
                bb:paintCircle(cx, cy, piece_r, C_INK, ring)
            else
                bb:paintCircle(cx, cy, piece_r, C_INK)
            end
            local contrast = (v == 1) and C_INK or C_WHITE
            if removable[pt] then
                drawCross(bb, cx, cy, math.floor(piece_r * 0.55), contrast, ring)
            elseif last and last.to == pt then
                bb:paintCircle(cx, cy, math.max(3, math.floor(cell * 0.08)), contrast)
            end
        end
    end
end

return MorrisBoardWidget
