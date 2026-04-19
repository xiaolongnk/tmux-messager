#!/usr/bin/env bash
# Check if a Claude Code pane is idle or busy.
#
# Usage:
#   claude-busy-check.sh <session> <window> <pane_index>
#   claude-busy-check.sh . . <pane_index>    (use current session/window)
#
# Output (stdout): "idle" or "busy" or "unknown"
# Exit code: 0 = idle, 1 = busy, 2 = unknown/error
#
# Detection heuristics:
#   BUSY indicators:
#     - Spinner characters (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏)
#     - Tool use keywords: Running / Reading / Editing / Searching / Writing / Executing
#     - "Thinking..." text
#     - Esc-to-interrupt hint
#
#   IDLE indicators:
#     - "> " prompt at start of a line (Claude Code input prompt)
#     - "Type a message" placeholder
#     - "Human:" turn marker at bottom (waiting for reply)
#
set -euo pipefail

[[ -n "${TMUX:-}" ]] || { echo "error: run inside tmux" >&2; echo "unknown"; exit 2; }

_expand_session_window() {
  local session="$1" window="$2"
  if [[ "$session" == "." ]]; then
    session=$(tmux display-message -p '#{session_name}' 2>/dev/null) || { echo "unknown"; exit 2; }
  fi
  if [[ "$window" == "." ]]; then
    window=$(tmux display-message -p '#I' 2>/dev/null) || { echo "unknown"; exit 2; }
  fi
  echo "$session $window"
}

[[ $# -ge 3 ]] || { echo "usage: $(basename "$0") <session> <window> <pane_index>" >&2; echo "unknown"; exit 2; }

SESSION="$1"
WINDOW="$2"
PANE="$3"

_sw=$(_expand_session_window "$SESSION" "$WINDOW") || { echo "unknown"; exit 2; }
read -r SESSION WINDOW <<< "$_sw"
TARGET="${SESSION}:${WINDOW}.${PANE}"

# Capture last 30 lines — enough to see bottom prompt + recent output.
OUTPUT=$(tmux capture-pane -t "$TARGET" -p -S -30 2>/dev/null) || {
  echo "unknown"; exit 2;
}

# --- Busy detection (check first — more important to not interrupt a busy agent) ---

# Spinner characters (Claude Code thinking indicator).
if echo "$OUTPUT" | grep -qE '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'; then
  echo "busy"; exit 1
fi

# Tool use in progress.
if echo "$OUTPUT" | grep -qE '(Running|Reading|Editing|Searching|Analyzing|Writing|Executing)\.\.\.'; then
  echo "busy"; exit 1
fi

# "Thinking..." text.
if echo "$OUTPUT" | grep -qF 'Thinking...'; then
  echo "busy"; exit 1
fi

# Interrupt/cancel hints.
if echo "$OUTPUT" | grep -qE '(Esc to interrupt|esc to interrupt|ctrl\+c to cancel|to interrupt)'; then
  echo "busy"; exit 1
fi

# --- Idle detection ---

# Claude Code input prompt: "> " or "❯ " at start of line (last 3 lines only to avoid false-idle).
if tail -3 <<< "$OUTPUT" | grep -qE '^[❯>] ?$'; then
  echo "idle"; exit 0
fi

# "Type a message" placeholder shown in empty input area.
if echo "$OUTPUT" | grep -qiF 'type a message'; then
  echo "idle"; exit 0
fi

# Fallback: if nothing matched, we can't tell.
echo "unknown"; exit 2
