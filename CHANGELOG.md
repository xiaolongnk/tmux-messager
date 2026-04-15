# Changelog

All notable changes to tmux-messager are documented here.

## [Unreleased]

### Added — Fish shell support (2026-04-16)

`tmux-target-send.sh` now correctly submits messages in Fish shell environments.

**Problem**: Fish shell + Ghostty/kitty terminals use the kitty keyboard protocol,
where `C-m` (carriage return) no longer triggers submission in agent TUI processes
(Claude Code, Cursor Agent). Messages were typed but never sent.

**Fix**: Added `_is_fish_target()` detection function that checks (in order):
1. `pane_current_command == fish` — pane is at a Fish prompt
2. macOS `dscl . -read /Users/<user> UserShell` — user's true login shell
3. `/etc/passwd` via `getent passwd` — Linux fallback
4. `$SHELL` environment variable — last resort (can be stale in subprocess chains)

When Fish is detected, both `claude` and `shell` modes send `ESC[13u`
(kitty keyboard protocol Enter) instead of `C-m`.

**Affected modes**:
- `claude` — submits to Claude Code TUI
- `shell` — submits commands to Fish prompt
- `cursor` / `gemini` — already used `ESC[13u`; unchanged

**No behavior change** for zsh/bash environments — `C-m` continues to be used there.

---

## [0.1.0] — 2026-04 (initial release)

- `tmux-target-send.sh`: multi-mode message dispatch (`claude`, `cursor`, `gemini`, `shell`)
- Pane registration and session config helpers
- Cursor busy-check and submit-resolve scripts
- README with SVG demos
