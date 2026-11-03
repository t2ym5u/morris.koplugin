# Changelog

All notable changes to this project will be documented in this file.

## [1.0.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.0.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

## [1.0.0] - 2026-10-30

### Added
- Nine Men's Morris: placing, moving and flying phases; a mill removes an
  opponent piece, never one in a mill unless all are; a player down to two
  pieces or unable to move loses.
- Draws by threefold repetition or 100 moves without a removal.
- AI opponent at three levels (negamax, alpha-beta, iterative deepening on a
  time budget), or two players on one device; play as White or Black.
- Undo (a mill awaiting its removal is undone as a whole), auto-save with
  undo history.
