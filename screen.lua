-- ---------------------------------------------------------------------------
-- MorrisScreen — Nine Men's Morris game screen (vs AI or two players)
-- ---------------------------------------------------------------------------

local _dir = debug.getinfo(1, "S").source:sub(2):match("(.*[/\\])") or "./"
local function lrequire(name)
    local key = _dir .. name
    if not package.loaded[key] then
        package.loaded[key] = assert(loadfile(_dir .. name .. ".lua"))()
    end
    return package.loaded[key]
end

local FrameContainer  = require("ui/widget/container/framecontainer")
local HorizontalGroup = require("ui/widget/horizontalgroup")
local HorizontalSpan  = require("ui/widget/horizontalspan")
local Size            = require("ui/size")
local UIManager       = require("ui/uimanager")
local VerticalGroup   = require("ui/widget/verticalgroup")
local VerticalSpan    = require("ui/widget/verticalspan")
local _               = require("i18n")
local T               = require("ffi/util").template

local MenuHelper  = require("menu_helper")
local ScreenBase  = require("screen_base")

local MorrisBoard       = lrequire("board")
local MorrisBoardWidget = lrequire("board_widget")

local GAME_RULES_EN = _([[
Nine Men's Morris — Rules

Each player has nine pieces. White plays first.

1. Placing: in turn, each player places a piece on any empty point.
2. Moving: once all pieces are placed, a turn slides one of your pieces along a line to the next point, if it is empty. Tap a piece, then where it goes.
3. Flying: a player left with only three pieces may move a piece to any empty point.

Three of your pieces in a row along a line form a mill. Forming one lets you remove an opponent piece: tap it. A piece standing in a mill can only be taken when every opponent piece is in a mill.

You lose when you are down to two pieces, or when you cannot move.

The game is drawn when the same position comes back a third time, or after 100 moves with no piece removed.
]])

local GAME_RULES_FR = [[
Jeu du moulin — Règles

Chaque joueur a neuf pions. Les Blancs commencent.

1. Pose : à tour de rôle, chaque joueur pose un pion sur un point libre.
2. Déplacement : une fois tous les pions posés, on fait glisser un de ses pions le long d'une ligne jusqu'au point voisin, s'il est libre. Touchez un pion, puis sa destination.
3. Vol : un joueur réduit à trois pions peut déplacer un pion sur n'importe quel point libre.

Trois de vos pions alignés sur une ligne forment un moulin. Former un moulin permet de retirer un pion adverse : touchez-le. Un pion qui fait partie d'un moulin ne peut être pris que si tous les pions adverses sont dans des moulins.

Vous perdez quand il ne vous reste que deux pions, ou quand vous ne pouvez plus bouger.

La partie est nulle quand une même position revient pour la troisième fois, ou après 100 coups sans prise.
]]

local MorrisScreen = ScreenBase:extend{}

-- ---------------------------------------------------------------------------
-- Lifecycle
-- ---------------------------------------------------------------------------

function MorrisScreen:init()
    local state = self.plugin:loadState()
    self.board  = MorrisBoard:new()
    if not self.board:load(state) then
        self.board:reset()
    end
    self.selected = nil
    ScreenBase.init(self)  -- calls buildLayout()
    if self:_isAITurn() then
        UIManager:scheduleIn(0.1, function() self:triggerAI() end)
    end
end

function MorrisScreen:isRoundOver()
    return self.board.status ~= "playing"
end

function MorrisScreen:serializeState()
    return self.board:serialize()
end

-- ---------------------------------------------------------------------------
-- Layout
-- ---------------------------------------------------------------------------

function MorrisScreen:buildLayout()
    local is_landscape = self:isLandscape()

    local title_bar = self:buildTitleBar(_("Nine Men's Morris"), function()
        local items = {
            { text = _("New game"),          callback = function() self:onNewGame() end },
            { text = self:_diffLabel(),      callback = function() self:openDifficultyMenu() end },
            { text = self:_playersLabel(),   callback = function() self:openPlayersMenu() end },
        }
        if self:_players() == 1 then
            items[#items + 1] = { text = self:_colorLabel(),
                                  callback = function() self:openColorMenu() end }
        end
        items[#items + 1] = self:makeRulesButtonConfig(GAME_RULES_EN, GAME_RULES_FR)
        return items
    end)

    local controls_w = self:getControlsWidth()
    self.status_text:setMaxWidth(controls_w)
    local controls = VerticalGroup:new{
        align = "center",
        self.status_text,
        VerticalSpan:new{ width = Size.span.vertical_large },
        self:buildActionBar({
            { text = _("Undo"), callback = function() self:onUndo() end },
        }),
    }

    local budget_w, budget_h = self:getBoardBudget(title_bar, controls)
    self.board_widget = MorrisBoardWidget:new{
        board         = self.board,
        max_size      = math.min(budget_w, budget_h),
        highlight     = function() return self:_highlight() end,
        onPointAction = function(pt) self:onPointTap(pt) end,
    }
    local board_frame = FrameContainer:new{
        padding    = 0,
        margin     = 0,
        bordersize = 0,
        self.board_widget,
    }

    if is_landscape then
        local content = HorizontalGroup:new{
            align = "center",
            board_frame,
            HorizontalSpan:new{ width = self:getGutter() },
            controls,
        }
        self:buildLandscapeLayout(title_bar, content)
    else
        self:buildPortraitLayout(title_bar, board_frame,
            VerticalGroup:new{ align = "center", controls, VerticalSpan:new{ width = self:getGutter() } })
    end
    self:updateStatus()
end

-- ---------------------------------------------------------------------------
-- Turn helpers
-- ---------------------------------------------------------------------------

function MorrisScreen:_players()
    return self.plugin:getSetting("players", 1)
end

-- Colour the human plays against the AI: 1 = White (first), 2 = Black.
function MorrisScreen:_humanColor()
    return self.plugin:getSetting("color", 1)
end

function MorrisScreen:_isAITurn()
    return self:_players() == 1 and self.board.status == "playing"
        and self.board.turn ~= self:_humanColor()
end

function MorrisScreen:_colorName(p)
    return (p == 1) and _("White") or _("Black")
end

local function toSet(list)
    local s = {}
    for _, v in ipairs(list) do s[v] = true end
    return s
end

-- What the widget marks: the selected piece and where it can go, or the
-- pieces that may be taken after a mill. Nothing during the AI's turn.
function MorrisScreen:_highlight()
    if self:_isAITurn() or self.ai_pending then return {} end
    local b = self.board
    if b.pending then return { removable = toSet(b:removablePoints()) } end
    if self.selected then
        return { selected = self.selected, targets = toSet(b:targetsFrom(self.selected)) }
    end
    return {}
end

-- ---------------------------------------------------------------------------
-- Taps
-- ---------------------------------------------------------------------------

function MorrisScreen:onPointTap(pt)
    local b = self.board
    if b.status ~= "playing" or self.ai_pending or self:_isAITurn() then return end
    local phase = b:phase()

    if phase == "remove" then
        local r = b:remove(pt)
        if r == "invalid" then
            self:updateStatus(b.cells[pt] == 3 - b.turn
                and _("That piece is in a mill: take another one.")
                or  _("Tap an opponent piece to remove it."))
            return
        end
        return self:_afterTurn(r)
    end

    if phase == "place" then
        return self:_afterStep(b:step(0, pt))
    end

    -- Moving or flying: first tap picks a piece, second tap where it goes.
    if b.cells[pt] == b.turn then
        self.selected = (self.selected ~= pt) and pt or nil
        if self.selected and #b:targetsFrom(pt) == 0 then
            self.selected = nil
            self:updateStatus(_("That piece cannot move."))
        else
            self:updateStatus()
        end
        self.board_widget:refresh()
        return
    end
    if self.selected and b.cells[pt] == 0 then
        local from = self.selected
        local r = b:step(from, pt)
        if r ~= "invalid" then
            self.selected = nil
            return self:_afterStep(r)
        end
    end
    self.selected = nil
    self.board_widget:refresh()
    self:updateStatus(_("Tap one of your pieces, then an empty point next to it."))
end

-- After the first half of a turn: a mill waits for its removal.
function MorrisScreen:_afterStep(r)
    if r == "invalid" then return end
    if r == "remove" then
        self.board_widget:refresh()
        self:updateStatus()
        return
    end
    self:_afterTurn(r)
end

function MorrisScreen:_afterTurn(r)
    self.board_widget:refresh()
    self.plugin:saveState(self:serializeState())
    self:updateStatus()
    if r == "over" then
        self:showMessage(self:_resultText(), 4)
    elseif self:_isAITurn() then
        self:triggerAI()
    end
end

function MorrisScreen:triggerAI()
    if not self:_isAITurn() or self.ai_pending then return end
    self.ai_pending = true
    self.board_widget:refresh()
    self:updateStatus(_("AI is thinking..."))
    local level = self.plugin:getSetting("difficulty", "medium")
    UIManager:scheduleIn(0.05, function()
        self.ai_pending = false
        if not self:_isAITurn() then return end
        local mv = self.board:getAIMove(level)
        if mv then self:_afterTurn(self.board:play(mv)) end
    end)
end

-- Against the AI, undo takes back the AI's reply too, so it is the player's
-- turn again. A mill awaiting its removal is undone as a whole.
function MorrisScreen:onUndo()
    if self.ai_pending then return end
    local b = self.board
    if not b:canUndo() then
        self:updateStatus(_("Nothing to undo."))
        return
    end
    b:undo()
    if self:_players() == 1 then
        while b.turn ~= self:_humanColor() and b:canUndo() do b:undo() end
    end
    self.selected = nil
    self.board_widget:refresh()
    self.plugin:saveState(self:serializeState())
    self:updateStatus()
    if self:_isAITurn() then self:triggerAI() end
end

function MorrisScreen:onNewGame()
    self.board:reset()
    self.selected = nil
    self.plugin:saveState(self:serializeState())
    self:buildLayout()
    UIManager:setDirty(self, function() return "ui", self.dimen end)
    if self:_isAITurn() then
        UIManager:scheduleIn(0.1, function() self:triggerAI() end)
    end
end

-- ---------------------------------------------------------------------------
-- Status
-- ---------------------------------------------------------------------------

function MorrisScreen:_resultText()
    local b = self.board
    if b.winner == 0 then
        return (b.end_reason == "repetition")
            and _("Draw: the position was repeated three times.")
            or  _("Draw: 100 moves without a mill.")
    end
    local head
    if self:_players() == 1 then
        head = (b.winner == self:_humanColor()) and _("You win!") or _("The AI wins.")
    else
        head = T(_("%1 wins the game!"), self:_colorName(b.winner))
    end
    local loser = self:_colorName(3 - b.winner)
    local why = (b.end_reason == "blocked")
        and T(_("%1 cannot move."), loser)
        or  T(_("%1 has only two pieces left."), loser)
    return head .. " " .. why
end

function MorrisScreen:_actionText()
    local b = self.board
    local who = self:_colorName(b.turn)
    local phase = b:phase()
    if self:_players() == 1 and b.turn ~= self:_humanColor() then
        return _("AI is thinking...")
    end
    if phase == "remove" then return T(_("Mill! %1 removes a piece"), who) end
    if phase == "place"  then return T(_("%1 to place"), who) end
    if phase == "fly"    then return T(_("%1 to move (flying)"), who) end
    return T(_("%1 to move"), who)
end

-- Pieces in hand while placing, then pieces on the board; White first.
function MorrisScreen:_countText()
    local b = self.board
    if b.hand[1] > 0 or b.hand[2] > 0 then
        return T(_("In hand: %1–%2"), b.hand[1], b.hand[2])
    end
    return T(_("Pieces: %1–%2"), b.count[1], b.count[2])
end

function MorrisScreen:updateStatus(msg)
    local status
    if msg then
        status = msg
    elseif self.board.status ~= "playing" then
        status = self:_resultText()
    else
        local dlabel
        if self:_players() == 1 then
            local diff = self.plugin:getSetting("difficulty", "medium")
            dlabel = MenuHelper.DIFFICULTY_LABELS[diff] or diff
        end
        status = self:joinStatus(dlabel, self:_actionText(), self:_countText())
    end
    ScreenBase.updateStatus(self, status)
    self:refreshActionBar()
end

-- ---------------------------------------------------------------------------
-- Menus
-- ---------------------------------------------------------------------------

function MorrisScreen:_playersLabel()
    return T(_("Players: %1"), self:_players())
end

function MorrisScreen:_diffLabel()
    local diff = self.plugin:getSetting("difficulty", "medium")
    return T(_("Difficulty: %1"), MenuHelper.DIFFICULTY_LABELS[diff] or diff)
end

function MorrisScreen:_colorLabel()
    return T(_("Play as: %1"), self:_colorName(self:_humanColor()))
end

function MorrisScreen:openPlayersMenu()
    MenuHelper.openPickerMenu{
        title      = _("Players"),
        items      = {
            { id = 1, text = _("1 player (vs AI)") },
            { id = 2, text = _("2 players") },
        },
        current_id = self:_players(),
        on_select  = function(id)
            self.plugin:saveSetting("players", id)
            self.selected = nil
            self.board_widget:refresh()
            self:updateStatus()
            if self:_isAITurn() then self:triggerAI() end
        end,
        parent = self,
    }
end

function MorrisScreen:openColorMenu()
    MenuHelper.openPickerMenu{
        title      = _("Play as"),
        items      = {
            { id = 1, text = _("White (plays first)") },
            { id = 2, text = _("Black (plays second)") },
        },
        current_id = self:_humanColor(),
        on_select  = function(id)
            self.plugin:saveSetting("color", id)
            self:onNewGame()
        end,
        parent = self,
    }
end

function MorrisScreen:openDifficultyMenu()
    MenuHelper.openDifficultyMenu{
        current   = self.plugin:getSetting("difficulty", "medium"),
        on_select = function(id)
            self.plugin:saveSetting("difficulty", id)
            self:updateStatus()
        end,
        parent = self,
    }
end

return MorrisScreen
