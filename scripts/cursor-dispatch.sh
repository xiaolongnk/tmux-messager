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
# Use $TMUX_PANE (calling process's pane ID) to anchor window resolution to the manager's
# window — not the attached client's focused window, which changes when user switches tabs.
if [[ -n "${TMUX_PANE:-}" ]]; then
  W=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}' 2>/dev/null) || exit 2
else
  W=$(tmux display-message -p '#I' 2>/dev/null) || exit 2
fi

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

# Find all cursor panes session-wide. Returns "window_idx:pane_idx:pane_id:title" per line.
# Priority: pane_id from session config (cross-window stable) → title scan across all windows.
find_cursor_panes() {
  # 1. pane_id from session config — window-agnostic, always preferred.
  if [[ -x "$SESSION_CONFIG" ]]; then
    local cpid
    cpid=$("$SESSION_CONFIG" get-pane-id cursor 2>/dev/null) || cpid=""
    if [[ "$cpid" =~ ^%[0-9]+$ ]]; then
      local cw cp ctitle
      cw=$(tmux display-message -t "$cpid" -p '#{window_index}' 2>/dev/null) || cw=""
      cp=$(tmux display-message -t "$cpid" -p '#{pane_index}' 2>/dev/null) || cp=""
      ctitle=$(tmux display-message -t "$cpid" -p '#{pane_title}' 2>/dev/null) || ctitle="config"
      [[ -n "$cw" && -n "$cp" ]] && echo "${cw}:${cp}:${cpid}:${ctitle}" && return
    fi
  fi

  # 2. Fallback: title scan across all windows in session.
  while IFS= read -r raw; do
    local fidx fwidx fpid ftitle fcmd
    fwidx=$(echo "$raw" | cut -d'|' -f1)
    fidx=$(echo "$raw"  | cut -d'|' -f2)
    fpid=$(echo "$raw"  | cut -d'|' -f3)
    ftitle=$(echo "$raw"| cut -d'|' -f4)
    fcmd=$(echo "$raw"  | cut -d'|' -f5)
    if [[ "$ftitle" =~ ^[Cc]ursor[\ \-] || "$ftitle" == "Cursor Agent" || "$fcmd" == "cursor" ]]; then
      echo "${fwidx}:${fidx}:${fpid}:${ftitle}"
    fi
  done < <(tmux list-panes -s -t "$S" \
    -F '#{window_index}|#{pane_index}|#{pane_id}|#{pane_title}|#{pane_current_command}' \
    2>/dev/null)
}

# Check status of all cursors and print.
do_status() {
  local found=0
  while IFS=: read -r cw cidx cpid ctitle; do
    [[ -n "$cidx" ]] || continue
    local state
    state=$("$BUSY_CHECK" "$S" "$cw" "$cidx" 2>/dev/null || echo "unknown")
    local last_used
    last_used=$(get_last_used "$cpid")
    local last_str=""
    if [[ "$last_used" != "0" && -n "$last_used" ]]; then
      local now
      now=$(date +%s)
      local ago=$(( now - last_used ))
      last_str=" (last used ${ago}s ago)"
    fi
    if [[ "$DO_JSON" -eq 1 ]]; then
      echo "{\"pane\":$cidx,\"window\":$cw,\"pane_id\":\"$cpid\",\"title\":\"$ctitle\",\"state\":\"$state\",\"last_used\":${last_used:-0}}"
    else
      printf "  pane %s (win %s, %s): %-12s  state=%-8s%s\n" "$cidx" "$cw" "$cpid" "$ctitle" "$state" "$last_str"
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

# Find the best idle cursor pane. Returns "window_idx:pane_idx:pane_id" or empty.
find_idle_cursor() {
  local best_key="" best_time=""
  while IFS=: read -r cw cidx cpid ctitle; do
    [[ -n "$cidx" ]] || continue
    local state
    state=$("$BUSY_CHECK" "$S" "$cw" "$cidx" 2>/dev/null || echo "unknown")
    if [[ "$state" == "idle" ]]; then
      local last_used
      last_used=$(get_last_used "$cpid")
      last_used="${last_used:-0}"
      # Pick least recently used.
      if [[ -z "$best_time" || "$last_used" -lt "$best_time" ]]; then
        best_key="${cw}:${cidx}:${cpid}"
        best_time="$last_used"
      fi
    fi
  done < <(find_cursor_panes)
  echo "$best_key"
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

# Force target mode — skip busy check. Resolve window from pane_id if it's a pane_id.
if [[ -n "$FORCE_TARGET" ]]; then
  echo "dispatching to forced target pane $FORCE_TARGET" >&2
  if [[ "$FORCE_TARGET" =~ ^%[0-9]+$ ]]; then
    _ft_w=$(tmux display-message -t "$FORCE_TARGET" -p '#{window_index}' 2>/dev/null) || _ft_w="$W"
    _ft_p=$(tmux display-message -t "$FORCE_TARGET" -p '#{pane_index}' 2>/dev/null) || _ft_p=""
    [[ -n "$_ft_p" ]] && "$SEND" "$_ft_w" "$_ft_p" cursor "${MESSAGE[*]}" || \
      { echo "error: could not resolve forced pane_id $FORCE_TARGET" >&2; exit 1; }
  else
    "$SEND" "$W" "$FORCE_TARGET" cursor "${MESSAGE[*]}"
  fi
  record_dispatch "$FORCE_TARGET"
  exit 0
fi

# Find an idle cursor, optionally waiting.
deadline=$(( $(date +%s) + WAIT_SECONDS ))
while true; do
  result=$(find_idle_cursor)
  if [[ -n "$result" ]]; then
    IFS=: read -r _cw _cidx _cpid <<< "$result"
    echo "dispatching to pane ${_cidx} (win=${_cw}, id=${_cpid}, idle)" >&2
    "$SEND" "$_cw" "$_cidx" cursor "${MESSAGE[*]}"
    record_dispatch "$_cpid"
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
