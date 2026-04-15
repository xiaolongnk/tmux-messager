#!/usr/bin/env bash
# Smart cursor dispatcher — find an idle cursor and send it a task.
#
# Usage:
#   cursor-dispatch.sh [--wait N] [--target N] [--status] <message...>
#
# Options:
#   --wait N       Wait up to N seconds for a cursor to become idle (default: 30)
#   --target N     Force target to pane index N (skip busy check)
#   --status       Show all cursor statuses without sending
#   --json         Output status as JSON (for programmatic use)
#
# Behavior:
#   1. Find all cursor panes (title starts with "cursor-" or "Cursor Agent")
#   2. Check each for idle/busy state
#   3. Pick the first idle one (LRU order: least recently used first)
#   4. Send the task via tmux-target-send.sh
#   5. Record the assignment for LRU tracking
#
# Exit codes:
#   0  = task dispatched successfully
#   1  = all cursors busy (and --wait expired or not set)
#   2  = no cursor panes found
#   3  = invalid usage
#
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$_SCRIPT_DIR/tmux-pane-helper.sh"
SEND="$_SCRIPT_DIR/tmux-target-send.sh"
BUSY_CHECK="$_SCRIPT_DIR/cursor-busy-check.sh"
DUAL_SETUP="$_SCRIPT_DIR/tmux-cursor-dual-setup.sh"
SESSION_CONFIG="$_SCRIPT_DIR/tmux-session-config.sh"
STATE_FILE="/tmp/claude-tmux-cursor-dispatch-state.json"

[[ -n "${TMUX:-}" ]] || { echo "error: run inside tmux" >&2; exit 2; }

S=$(tmux display-message -p '#{session_name}' 2>/dev/null) || exit 2
W=$(tmux display-message -p '#I' 2>/dev/null) || exit 2

WAIT_SECONDS=30
FORCE_TARGET=""
DO_STATUS=0
DO_JSON=0
MESSAGE=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --wait)
      [[ $# -ge 2 ]] || { echo "usage: --wait N" >&2; exit 3; }
      WAIT_SECONDS="$2"; shift 2 ;;
    --target)
      [[ $# -ge 2 ]] || { echo "usage: --target PANE" >&2; exit 3; }
      FORCE_TARGET="$2"; shift 2 ;;
    --status)
      DO_STATUS=1; shift ;;
    --json)
      DO_JSON=1; shift ;;
    -h|--help|help)
      sed -n '2,20p' "$0" | sed 's/^# //' >&2; exit 0 ;;
    *)
      MESSAGE+=("$1"); shift ;;
  esac
done

# Initialize state file if missing.
init_state() {
  if [[ ! -f "$STATE_FILE" ]] || [[ ! -s "$STATE_FILE" ]]; then
    echo '{}' > "$STATE_FILE"
  fi
}

# Get last-used timestamp for a pane. Returns 0 if never used.
get_last_used() {
  local pane="$1"
  init_state
  # Simple key=value in JSON-like format — avoid jq dependency.
  grep -o "\"${pane}\":[0-9]*" "$STATE_FILE" 2>/dev/null | head -1 | cut -d: -f2 || echo "0"
}

# Record that we dispatched to this pane.
record_dispatch() {
  local pane="$1"
  local now
  now=$(date +%s)
  init_state
  # Replace or append the entry.
  local tmp
  tmp=$(mktemp)
  if grep -q "\"${pane}\":" "$STATE_FILE" 2>/dev/null; then
    sed "s/\"${pane}\":[0-9]*/\"${pane}\":${now}/" "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  else
    # Remove closing brace, add entry, close again.
    sed '$ s/}/, "'"$pane"'":'"$now"'}/' "$STATE_FILE" > "$tmp" && mv "$tmp" "$STATE_FILE"
  fi
}

# Find all cursor panes in current window. Returns "idx:title" per line.
# Priority: session config file → title matching fallback.
find_cursor_panes() {
  # 1. Check session config (sessions/<session-name>.conf → cursor_panes=3,4)
  if [[ -x "$SESSION_CONFIG" ]]; then
    local config_panes
    config_panes=$("$SESSION_CONFIG" get cursor 2>/dev/null) || config_panes=""
    if [[ -n "$config_panes" ]]; then
      IFS=',' read -ra _panes <<< "$config_panes"
      for idx in "${_panes[@]}"; do
        idx="${idx// /}"  # trim spaces
        [[ -n "$idx" ]] || continue
        echo "${idx}:config"
      done
      return
    fi
  fi

  # 2. Fallback: title matching (Cursor Agent, cursor-*, Cursor <topic>).
  while IFS= read -r idx; do
    local title
    title=$(tmux display-message -t "${S}:${W}.${idx}" -p '#{pane_title}' 2>/dev/null) || continue
    if [[ "$title" =~ ^[Cc]ursor[\ \-] || "$title" == "Cursor Agent" || "$title" == "cursor" ]]; then
      echo "${idx}:${title}"
    fi
  done < <(tmux list-panes -t "${S}:${W}" -F '#{pane_index}' 2>/dev/null)
}

# Check status of all cursors and print.
do_status() {
  local found=0
  while IFS=: read -r idx title; do
    [[ -n "$idx" ]] || continue
    local state
    state=$("$BUSY_CHECK" . . "$idx" 2>/dev/null || echo "unknown")
    local last_used
    last_used=$(get_last_used "$idx")
    local last_str=""
    if [[ "$last_used" != "0" && -n "$last_used" ]]; then
      local now
      now=$(date +%s)
      local ago=$(( now - last_used ))
      last_str=" (last used ${ago}s ago)"
    fi
    if [[ "$DO_JSON" -eq 1 ]]; then
      echo "{\"pane\":$idx,\"title\":\"$title\",\"state\":\"$state\",\"last_used\":${last_used:-0}}"
    else
      printf "  pane %s: %-12s  state=%-8s%s\n" "$idx" "$title" "$state" "$last_str"
    fi
    found=1
  done < <(find_cursor_panes)
  if [[ "$found" -eq 0 ]]; then
    if [[ "$DO_JSON" -eq 1 ]]; then
      echo "{\"error\":\"no cursor panes found\"}"
    else
      echo "  No cursor panes found."
    fi
    return 2
  fi
}

# Find the best idle cursor pane. Returns pane index or empty.
find_idle_cursor() {
  local best_pane="" best_time=""
  while IFS=: read -r idx title; do
    [[ -n "$idx" ]] || continue
    local state
    state=$("$BUSY_CHECK" . . "$idx" 2>/dev/null || echo "unknown")
    if [[ "$state" == "idle" ]]; then
      local last_used
      last_used=$(get_last_used "$idx")
      last_used="${last_used:-0}"
      # Pick least recently used.
      if [[ -z "$best_time" || "$last_used" -lt "$best_time" ]]; then
        best_pane="$idx"
        best_time="$last_used"
      fi
    fi
  done < <(find_cursor_panes)
  echo "$best_pane"
}

# Main dispatch logic.
if [[ "$DO_STATUS" -eq 1 ]]; then
  do_status
  exit 0
fi

if [[ ${#MESSAGE[@]} -eq 0 && -z "$FORCE_TARGET" ]]; then
  echo "error: no message to dispatch. Use --status to check cursor states." >&2
  exit 3
fi

# Force target mode — skip busy check.
if [[ -n "$FORCE_TARGET" ]]; then
  echo "dispatching to forced target pane $FORCE_TARGET" >&2
  "$SEND" "$W" "$FORCE_TARGET" cursor "${MESSAGE[*]}"
  record_dispatch "$FORCE_TARGET"
  exit 0
fi

# Find an idle cursor, optionally waiting.
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while true; do
  pane=$(find_idle_cursor)
  if [[ -n "$pane" ]]; then
    echo "dispatching to pane $pane (idle)" >&2
    "$SEND" "$W" "$pane" cursor "${MESSAGE[*]}"
    record_dispatch "$pane"
    exit 0
  fi

  now=$(date +%s)
  if [[ "$now" -ge "$deadline" ]]; then
    echo "error: all cursors busy after ${WAIT_SECONDS}s wait" >&2
    echo "hint: use --status to check, or --wait 60 to wait longer" >&2
    exit 1
  fi
  sleep 2
done
