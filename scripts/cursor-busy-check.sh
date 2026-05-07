#!/usr/bin/env bash
# Check if a Cursor Agent pane is idle or busy.
#
# Usage:
#   cursor-busy-check.sh <session> <window> <pane_index>
#   cursor-busy-check.sh . . <pane_index>    (use current session/window)
#
# Output (stdout): "idle" or "busy" or "unknown"
# Exit code: 0 = idle, 1 = busy, 2 = unknown/error
#
# Detection heuristics:
#   IDLE indicators:
#     - "→ Add a follow-up" + "INSERT" in input box
#     - Input box shows "INSERT" mode
#
#   BUSY indicators:
#     - "• Generating..." text
#     - "ctrl+c to stop" in input box
#     - Spinner characters (⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏)
#     - "Running" / "Reading" / "Editing" tool-use keywords
#
set -euo pipefail

[[ -n "${TMUX:-}" ]] || { echo "error: run inside tmux" >&2; echo "unknown"; exit 2; }

_expand_session_window() {
  local session="$1" window="$2"
  if [[ "$session" == "." ]]; then
    session=$(tmux display-message -p '#{session_name}' 2>/dev/null) || { echo "unknown"; exit 2; }
  fi
  if [[ "$window" == "." ]]; then
    if [[ -n "${TMUX_PANE:-}" ]]; then
      window=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}' 2>/dev/null) || { echo "unknown"; exit 2; }
    else
      window=$(tmux display-message -p '#I' 2>/dev/null) || { echo "unknown"; exit 2; }
    fi
  fi
  echo "$session $window"
}

[[ $# -ge 3 ]] || { echo "usage: $(basename "$0") <session> <window> <pane_index>" >&2; echo "unknown"; exit 2; }

SESSION="$1"
WINDOW="$2"
PANE="$3"

read -r SESSION WINDOW <<< "$(_expand_session_window "$SESSION" "$WINDOW")"
TARGET="${SESSION}:${WINDOW}.${PANE}"

# Capture last 20 lines of the pane (enough to see input box + last response).
OUTPUT=$(tmux capture-pane -t "$TARGET" -p -S -20 2>/dev/null) || {
  echo "unknown"; exit 2;
}

# --- Busy detection (check first — more important to not interrupt a busy agent) ---

# Check for "Generating..." text.
if echo "$OUTPUT" | grep -qF '• Generating'; then
  echo "busy"
  exit 1
fi

# Check for "ctrl+c to stop" in input box (means agent is running).
if echo "$OUTPUT" | grep -qF 'ctrl+c to stop'; then
  echo "busy"
  exit 1
fi

# Check for spinner characters (macOS grep doesn't support -P, use -E with literal unicode).
if echo "$OUTPUT" | grep -qE '[⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏]'; then
  echo "busy"
  exit 1
fi

# Check for common "working" keywords in last output lines.
if echo "$OUTPUT" | grep -qE '(Running|Reading|Editing|Searching|Analyzing)\.\.\.'; then
  echo "busy"
  exit 1
fi

# Check for token count indicator (e.g. "1,234 tokens" or "... 1234 tokens") — agent is generating.
if echo "$OUTPUT" | grep -qE '[0-9][0-9,]* tokens'; then
  echo "busy"
  exit 1
fi

# Check for "Esc to stop" or "Stop (" — Cursor stop button while running.
if echo "$OUTPUT" | grep -qE '(Esc to stop|Stop \()'; then
  echo "busy"
  exit 1
fi

# --- Idle detection ---

# Check for "Add a follow-up" — the idle prompt after a response.
if echo "$OUTPUT" | grep -qF 'Add a follow-up'; then
  echo "idle"
  exit 0
fi

# Check for "Ask Agent" — the empty-chat idle prompt.
if echo "$OUTPUT" | grep -qF 'Ask Agent'; then
  echo "idle"
  exit 0
fi

# Fallback: if none of the above matched, check if the pane seems to have an
# active cursor agent (node process) but we can't determine state.
echo "unknown"
exit 2
