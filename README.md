# tmux-messager

Shell scripts that let AI agents send messages to each other across tmux panes — with correct submit-key handling for Cursor Agent, smart pane discovery, and automatic reply-to injection.

---

## Why this exists

Running multiple AI agents (Claude Code, Cursor Agent, Gemini) in different tmux panes is powerful, but wiring them together manually is painful:

- Plain `Enter` / `C-m` in Cursor Agent's TUI **inserts a newline**, not a submit — you need `ESC[13u` (kitty protocol)
- Pane indices shift when you resize or reorder splits — hard-coded numbers break constantly
- Agents need to know **where to reply**, but their own pane address changes across sessions

tmux-messager solves all three: it resolves the right submit key per terminal, finds panes by role rather than by index, and automatically injects reply-to addresses so agents can respond without any manual wiring.

---

## How it works

```
tmux-target-send.sh          ← main entry: send to a pane with the right submit key
tmux-pane-helper.sh          ← pane inventory + resolve by geometry / keyword / title
cursor-dispatch.sh           ← LRU dispatcher: find an idle Cursor pane and send a task
tmux-register-pane.sh        ← register this agent's pane ID for stable reply-to lookup
tmux-ensure-registered.sh    ← auto-clean stale registrations + register if missing
tmux-session-config.sh       ← read/write per-session role→pane mapping (sessions/*.conf)
tmux-cursor-submit-resolve.sh ← shared library: resolve Cursor's submit key
tmux-terminal-profile.sh     ← diagnostics: print terminal detection + resolved key
cursor-busy-check.sh         ← is a Cursor pane idle or busy?
claude-busy-check.sh         ← is a Claude Code pane idle or busy?
tmux-cursor-dual-setup.sh    ← create 2 Cursor Agent panes in the current window
```

### Submit key resolution

Cursor Agent's TUI treats `C-m` as a newline. The correct key depends on your terminal:

| Terminal | Submit key | Escape sequence |
|----------|-----------|----------------|
| Ghostty / kitty (default on macOS) | `kitty-enter` | `ESC [ 13 u` |
| Other terminals | `c-enter` | tmux `C-Enter` |

Resolution priority (first match wins):
1. `TMUX_TARGET_SEND_CURSOR` env var
2. `~/.config/claude-tmux/cursor-submit` config file
3. Ghostty detected (`TERM_PROGRAM=ghostty` or `GHOSTTY_RESOURCES_DIR`) → `kitty-enter`
4. Darwin → `kitty-enter`
5. Other → `c-enter`

### Pane registration & reply-to injection

When you call `tmux-register-pane.sh`, it writes the agent's tmux pane ID (`%33`) to `/tmp/claude-pane-tmux-p33`. When `tmux-target-send.sh` sends a message to another agent, it appends a `REQUIRED` instruction with the exact bash command to reply back — the receiver doesn't need to know your address.

```
REQUIRED: After completing the task above, run this bash command in your terminal to
send your reply back:
  bash ./scripts/tmux-target-send.sh --direct-target main:0:1 claude "your reply here"
```

Pane ID (`%33`) is layout-stable — it survives pane reordering and never needs re-registration unless you restart the agent.

---

## Quick start

```bash
# 1. Diagnose your terminal and resolved submit key
./scripts/tmux-terminal-profile.sh

# 2. Register your agent pane (run once per session)
bash ./scripts/tmux-ensure-registered.sh

# 3. Send a message to pane 2 (Cursor Agent)
./scripts/tmux-target-send.sh . 2 cursor "implement the login page"

# 4. Send to a Claude Code pane
./scripts/tmux-target-send.sh . 1 claude "task complete — see PR #42"

# 5. Run a shell command in pane 0
./scripts/tmux-target-send.sh . 0 shell "git status"

# 6. Find panes by description instead of number
S="$(tmux display-message -p '#S')"
./scripts/tmux-pane-helper.sh inventory "$S" .            # list all panes
./scripts/tmux-pane-helper.sh send "$S" . kw:cursor "go"  # send to pane whose title contains "cursor"

# 7. Smart dispatch: pick an idle Cursor pane automatically
./scripts/cursor-dispatch.sh "add unit tests for auth module"
```

---

## Configuration

### Persistent submit key

```bash
mkdir -p ~/.config/claude-tmux
echo "kitty-enter" > ~/.config/claude-tmux/cursor-submit
```

### Ghostty ⌘↩ shortcut (optional)

Add to `~/.config/ghostty/config` so Cmd+Enter sends the same CSI sequence:

```ini
keybind = cmd+enter=csi:13u
```

### Per-session pane roles (`sessions/*.conf`)

Optional role mapping — avoids title-scanning on every send:

```ini
session=myproject
window=0
claude_panes=1
cursor_panes=3,4
shell_panes=2
```

These files are user-specific and gitignored. Create your own after setting up panes.

---

## Pane selectors (discovery path)

When you don't know the pane index, use `tmux-pane-helper.sh resolve`:

| Selector | Matches |
|----------|---------|
| `active` / `focused` | keyboard-focused pane |
| `first` / `nth-1` | top-left in reading order |
| `second` / `nth-2` | second in reading order |
| `left` / `right` | leftmost / rightmost |
| `left-top` / `right-bottom` | corner panes |
| `title:Claude` | pane title contains "Claude" |
| `kw:cursor` | keyword in title, command, or visible text |
| `index-2` | explicit index, no self-exclusion |

---

## Roadmap

- [ ] **Gemini CLI support** — already partially wired; finalize submit key detection for `gemini` mode
- [ ] **Multi-window dispatch** — `cursor-dispatch.sh` currently targets the current window; extend to search all windows in a session
- [ ] **Broadcast mode** — send one message to all agents simultaneously (useful for "stop what you're doing" interrupts)
- [ ] **Status dashboard** — `tmux-pane-helper.sh status` showing each pane's role, idle/busy state, and last message
- [ ] **Fish shell helpers** — `abbr`-based shortcuts for common send patterns (`tsend`, `tdispatch`)
- [ ] **Auto-discovery on session start** — hook into tmux `session-created` to register all panes automatically
- [ ] **Message log** — optional append-only log of messages sent between agents (for debugging agent loops)

---

## Requirements

- tmux 3.2+
- bash 4+ (ships with macOS via Homebrew: `brew install bash`)
- No other dependencies — no jq, no Python

---

## Usage note

All scripts use `.` as the window argument to mean "current window" (`#{window_index}`). Never hard-code a window name — layouts change. Run scripts from the **repository root** (the directory containing `scripts/`):

```bash
./scripts/tmux-target-send.sh . 2 cursor "hello"
```
