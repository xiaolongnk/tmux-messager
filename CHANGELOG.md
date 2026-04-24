# Changelog

All notable changes to tmux-messager are documented here.

## [Unreleased]

### Added — Cached submit keys + adaptive send delay + work-window dispatch (2026-04-24)

**Submit-key caching at registration time** (`tmux-register-pane.sh`, `tmux-session-config.sh`):
- When a Claude pane registers, its submit key (`kitty-enter` for Fish, `c-m` otherwise) is detected once and stored in the session config via a new `set-submit-key` / `get-submit-key` API.
- Send scripts look up the stored key per role instead of re-detecting at runtime — eliminates per-send terminal probes and removes a class of races when the pane's current command isn't `fish` (e.g. inside a long-running TUI).

**Adaptive send delay** (`tmux-target-send.sh`):
- New `_adaptive_sleep` between text send and submit key: 0.1 s for short messages, **0.3 s for >200 chars**.
- Long prompts no longer race the TUI's render loop — fixes intermittent dropped submits on large pasted briefs.

**Bulk pane registration** (`tmux-register-all-panes.sh`):
- Iterates over every pane in the current session and registers each with detected role + submit key — one-shot setup after splitting a window.

**New: work-window scripts** (`work-window-setup.sh`, `work-dispatch.sh`):
- `work-window-setup.sh`: create a named tmux work window with N worker panes (each running a chosen agent CLI).
- `work-dispatch.sh`: multi-instance-safe LRU dispatcher — picks an idle worker pane in a named work window and sends the task with the correct submit key. Safe under concurrent dispatchers via a pointer file with `flock`.

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
