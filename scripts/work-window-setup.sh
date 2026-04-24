#!/usr/bin/env bash
# work-window-setup.sh — Create a named tmux work window with N worker panes.
#
# Usage:
#   work-window-setup.sh <window-name> [--panes N] [--type claude|shell|cursor|gemini]
#
# Creates a new tmux window named <window-name> in the current session, splits it
# into N equally-sized panes, and writes a shared state file so work-dispatch.sh
# can address workers by name. Multiple Claude instances share the same state file.
#
# State file: /tmp/claude-work-window-<name>.state
#
# Options:
#   --panes N        Number of worker panes (default: 4, max: 8)
#   --type TYPE      Worker type sent by work-dispatch.sh:
#                      claude   Claude Code pane (default)
#                      shell    Plain shell (send-keys + Enter)
#                      cursor   Cursor Agent pane
#                      gemini   Gemini TUI pane
#   --force          Overwrite existing state file if window already gone
#
# Exit codes: 0=ok, 1=error
set -euo pipefail

usage() {
  grep '^#' "$0" | grep -v '^#!/' | head -18 | sed 's/^# \{0,1\}//'
  exit 1
}

[[ -n "${TMUX:-}" ]] || { echo "error: run inside tmux (TMUX unset)" >&2; exit 1; }
[[ $# -ge 1 ]] || usage

WINDOW_NAME="$1"; shift
NUM_PANES=4
WORKER_TYPE="claude"
FORCE=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --panes)  [[ $# -ge 2 ]] || usage; NUM_PANES="$2"; shift 2 ;;
    --type)   [[ $# -ge 2 ]] || usage; WORKER_TYPE="$2"; shift 2 ;;
    --force)  FORCE=1; shift ;;
    -h|--help|help) usage ;;
    *) echo "error: unknown arg: $1" >&2; usage ;;
  esac
done

[[ "$NUM_PANES" =~ ^[1-9]$|^[1-8]$ ]] || [[ "$NUM_PANES" =~ ^[1-8]$ ]] || {
  echo "error: --panes must be 1–8" >&2; exit 1
}

case "$WORKER_TYPE" in
  claude|shell|cursor|gemini) ;;
  *) echo "error: --type must be claude|shell|cursor|gemini" >&2; exit 1 ;;
esac

S=$(tmux display-message -p '#{session_name}')
STATE_FILE="/tmp/claude-work-window-${WINDOW_NAME}.state"

# Guard: window already exists?
existing_widx=$(tmux list-windows -t "$S" -F '#{window_index} #{window_name}' 2>/dev/null \
  | awk -v n="$WINDOW_NAME" '$2==n{print $1; exit}') || existing_widx=""
if [[ -n "$existing_widx" ]]; then
  if [[ "$FORCE" -eq 0 ]]; then
    echo "error: window '${WINDOW_NAME}' already exists in session '${S}' (index ${existing_widx})" >&2
    echo "hint: use --force to overwrite the state file, or: work-dispatch.sh ${WINDOW_NAME} --status" >&2
    exit 1
  else
    echo "warning: window '${WINDOW_NAME}' exists — overwriting state file only" >&2
  fi
fi

echo "creating work window '${WINDOW_NAME}' (${NUM_PANES} panes, type=${WORKER_TYPE}) in session '${S}'..." >&2

# Create a new detached window.
tmux new-window -t "$S" -n "$WINDOW_NAME" -d
W_IDX=$(tmux list-windows -t "$S" -F '#{window_index} #{window_name}' \
  | awk -v n="$WINDOW_NAME" '$2==n{print $1; exit}')
[[ -n "$W_IDX" ]] || { echo "error: failed to create window '${WINDOW_NAME}'" >&2; exit 1; }

PANE_IDS=()

# First pane already exists when window is created.
first_pid=$(tmux list-panes -t "${S}:${W_IDX}" -F '#{pane_id}')
PANE_IDS+=("$first_pid")

# Add N-1 more panes via vertical splits, then tile.
for (( i=1; i<NUM_PANES; i++ )); do
  tmux split-window -t "${S}:${W_IDX}" -v 2>/dev/null || {
    echo "warning: could not split pane $i — stopping at ${#PANE_IDS[@]} panes" >&2
    break
  }
  new_pid=$(tmux list-panes -t "${S}:${W_IDX}" -F '#{pane_id}' | tail -1)
  PANE_IDS+=("$new_pid")
done

# Apply tiled layout so all panes are equally visible.
tmux select-layout -t "${S}:${W_IDX}" tiled 2>/dev/null || true

PANE_IDS_CSV=$(IFS=,; echo "${PANE_IDS[*]}")
NOW=$(date +%s)

# Write state file (readable by work-dispatch.sh from any pane/instance).
{
  echo "# work window state — managed by work-window-setup.sh / work-dispatch.sh"
  echo "# DO NOT edit manually while a dispatch is in progress."
  echo "window_name=${WINDOW_NAME}"
  echo "session=${S}"
  echo "window_index=${W_IDX}"
  echo "worker_type=${WORKER_TYPE}"
  echo "pane_count=${#PANE_IDS[@]}"
  echo "pane_ids=${PANE_IDS_CSV}"
  echo "pointer=0"
  echo "created_at=${NOW}"
  for pid in "${PANE_IDS[@]}"; do
    safe="${pid//\%/p}"
    echo "last_dispatch_${safe}=0"
    echo "dispatch_count_${safe}=0"
  done
} > "$STATE_FILE"

echo "" >&2
echo "  work window '${WINDOW_NAME}' ready" >&2
echo "  ────────────────────────────────────────" >&2
echo "  session    : ${S}" >&2
echo "  window     : ${W_IDX} (name: ${WINDOW_NAME})" >&2
printf "  pane ids   : %s\n" "${PANE_IDS[@]}" >&2
echo "  worker type: ${WORKER_TYPE}" >&2
echo "  state file : ${STATE_FILE}" >&2
echo "" >&2
echo "  next steps:" >&2
echo "    # check status:" >&2
echo "    work-dispatch.sh ${WINDOW_NAME} --status" >&2
echo "" >&2
echo "    # send a task (round-robin by default):" >&2
echo "    work-dispatch.sh ${WINDOW_NAME} \"implement feature X\"" >&2
echo "" >&2
echo "    # send with LRU or idle mode:" >&2
echo "    work-dispatch.sh ${WINDOW_NAME} --mode lru \"task\"" >&2
echo "    work-dispatch.sh ${WINDOW_NAME} --mode idle \"task\"" >&2
