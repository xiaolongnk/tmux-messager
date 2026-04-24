#!/usr/bin/env bash
# work-dispatch.sh — Dispatch a task to a named work window (multi-instance safe).
#
# Usage:
#   work-dispatch.sh <window-name> [options] <message...>
#
# Sends <message> to the next available pane in the named work window.
# Uses mkdir-based atomic lock so concurrent Claude instances never collide on
# the pointer. The reply-to address is auto-injected (from $TMUX_PANE) so
# workers can call back with results.
#
# Options:
#   --mode round-robin   Strict round-robin pointer, ignores busy state (default)
#   --mode lru           Least recently dispatched pane first
#   --mode idle          First pane that passes claude-busy-check (waits up to --wait)
#   --wait N             Idle mode: wait up to N seconds for a free pane (default: 30)
#   --no-reply           Skip reply-to instruction injection
#   --status             Show window/pane state without sending anything
#   --list               List all registered work windows in /tmp/
#
# State file: /tmp/claude-work-window-<name>.state  (created by work-window-setup.sh)
# Lock dir:   /tmp/claude-work-lock-<name>/          (auto-cleaned on exit)
#
# Exit codes:
#   0 = task dispatched
#   1 = error (bad args, missing state, stale pane)
#   2 = no panes registered
#   3 = all panes busy (idle mode only, after --wait timeout)
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SEND="$_SCRIPT_DIR/tmux-target-send.sh"
BUSY_CHECK="$_SCRIPT_DIR/claude-busy-check.sh"

usage() {
  grep '^#' "$0" | grep -v '^#!/' | head -28 | sed 's/^# \{0,1\}//'
  exit 1
}

[[ -n "${TMUX:-}" ]] || { echo "error: run inside tmux (TMUX unset)" >&2; exit 1; }
[[ $# -ge 1 ]] || usage

WINDOW_NAME="$1"; shift

# --list: show all registered work windows.
if [[ "$WINDOW_NAME" == "--list" || "$WINDOW_NAME" == "list" ]]; then
  echo "registered work windows:"
  found=0
  for f in /tmp/claude-work-window-*.state; do
    [[ -f "$f" ]] || continue
    name="${f#/tmp/claude-work-window-}"; name="${name%.state}"
    s=$(grep "^session=" "$f" | cut -d= -f2 | head -1)
    w=$(grep "^window_index=" "$f" | cut -d= -f2 | head -1)
    pc=$(grep "^pane_count=" "$f" | cut -d= -f2 | head -1)
    wt=$(grep "^worker_type=" "$f" | cut -d= -f2 | head -1)
    ptr=$(grep "^pointer=" "$f" | cut -d= -f2 | head -1)
    printf "  %-20s  session=%s  window=%s  panes=%s  type=%-8s  next=%s\n" \
      "$name" "${s:--}" "${w:--}" "${pc:--}" "${wt:--}" "${ptr:-0}"
    found=1
  done
  [[ "$found" -eq 1 ]] || echo "  (none — run work-window-setup.sh to create one)"
  exit 0
fi

DISPATCH_MODE="round-robin"
WAIT_SECONDS=30
NO_REPLY_FLAG=""
DO_STATUS=0
MESSAGE=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    --mode)     [[ $# -ge 2 ]] || usage; DISPATCH_MODE="$2"; shift 2 ;;
    --wait)     [[ $# -ge 2 ]] || usage; WAIT_SECONDS="$2"; shift 2 ;;
    --no-reply) NO_REPLY_FLAG="--no-reply"; shift ;;
    --status)   DO_STATUS=1; shift ;;
    -h|--help|help) usage ;;
    *) MESSAGE+=("$1"); shift ;;
  esac
done

case "$DISPATCH_MODE" in
  round-robin|lru|idle) ;;
  *) echo "error: unknown mode '${DISPATCH_MODE}' (try round-robin|lru|idle)" >&2; exit 1 ;;
esac

STATE_FILE="/tmp/claude-work-window-${WINDOW_NAME}.state"
LOCK_DIR="/tmp/claude-work-lock-${WINDOW_NAME}"

[[ -f "$STATE_FILE" ]] || {
  echo "error: no state file for '${WINDOW_NAME}' (${STATE_FILE})" >&2
  echo "hint : run 'work-window-setup.sh ${WINDOW_NAME}' first" >&2
  echo "       or:  work-dispatch.sh --list" >&2
  exit 1
}

# ── Helpers ─────────────────────────────────────────────────────────────────

_read_key() {
  local file="$1" key="$2" default="${3:-}"
  local val
  val=$(grep -E "^${key}=" "$file" 2>/dev/null | head -1 | cut -d= -f2-) || true
  echo "${val:-$default}"
}

_write_key() {
  # Atomic in-place update via temp file (BSD+GNU sed compatible).
  local file="$1" key="$2" val="$3"
  local tmp
  tmp=$(mktemp)
  if grep -qE "^${key}=" "$file" 2>/dev/null; then
    sed "s|^${key}=.*|${key}=${val}|" "$file" > "$tmp" && mv "$tmp" "$file"
  else
    cp "$file" "$tmp"; echo "${key}=${val}" >> "$tmp"; mv "$tmp" "$file"
  fi
}

# Atomic lock (mkdir is POSIX-atomic; no flock/lockfile dependency).
_LOCK_HELD=0
_acquire_lock() {
  local deadline=$(( $(date +%s) + 5 ))
  while ! mkdir "$LOCK_DIR" 2>/dev/null; do
    [[ $(date +%s) -lt "$deadline" ]] || {
      echo "error: could not acquire lock after 5s — stale lock? run: rmdir ${LOCK_DIR}" >&2
      exit 1
    }
    sleep 0.05
  done
  _LOCK_HELD=1
}
_release_lock() {
  [[ "$_LOCK_HELD" -eq 1 ]] || return 0
  rmdir "$LOCK_DIR" 2>/dev/null || true
  _LOCK_HELD=0
}
trap '_release_lock' EXIT INT TERM

# ── Read static state ────────────────────────────────────────────────────────

S=$(_read_key "$STATE_FILE" "session")
W_IDX=$(_read_key "$STATE_FILE" "window_index")
PANE_IDS_CSV=$(_read_key "$STATE_FILE" "pane_ids")
WORKER_TYPE=$(_read_key "$STATE_FILE" "worker_type" "claude")

IFS=',' read -ra PANE_IDS <<< "$PANE_IDS_CSV"
NUM_PANES="${#PANE_IDS[@]}"
[[ "$NUM_PANES" -gt 0 ]] || { echo "error: no panes in state file for '${WINDOW_NAME}'" >&2; exit 2; }

# Verify window still alive.
_window_alive() {
  tmux list-windows -t "$S" -F '#{window_index}' 2>/dev/null | grep -qx "$W_IDX"
}
_window_alive || {
  echo "error: work window '${WINDOW_NAME}' (idx ${W_IDX}) no longer exists in session '${S}'" >&2
  echo "hint : re-run 'work-window-setup.sh ${WINDOW_NAME}' to recreate it" >&2
  exit 1
}

# Resolve live pane_index from pane_id (layout-stable).
_pane_index() {
  local pid="$1"
  tmux display-message -t "$pid" -p '#{pane_index}' 2>/dev/null || echo ""
}

_pane_alive() {
  local pid="$1"
  local idx
  idx=$(_pane_index "$pid")
  [[ -n "$idx" ]]
}

# ── Status mode ──────────────────────────────────────────────────────────────

if [[ "$DO_STATUS" -eq 1 ]]; then
  pointer=$(_read_key "$STATE_FILE" "pointer" "0")
  echo "work window: ${WINDOW_NAME}"
  echo "  session     : ${S}"
  echo "  window idx  : ${W_IDX}"
  echo "  worker type : ${WORKER_TYPE}"
  echo "  pointer     : ${pointer} → next pane index ${pointer} (of ${NUM_PANES})"
  echo ""
  local_now=$(date +%s)
  for i in "${!PANE_IDS[@]}"; do
    pid="${PANE_IDS[$i]}"
    safe="${pid//\%/p}"
    last=$(_read_key "$STATE_FILE" "last_dispatch_${safe}" "0")
    count=$(_read_key "$STATE_FILE" "dispatch_count_${safe}" "0")
    pane_idx=$(_pane_index "$pid") || pane_idx="DEAD"
    marker=""
    [[ "$i" -eq "$pointer" ]] && marker=" ← next"
    alive_tag="[alive]"
    [[ "$pane_idx" == "DEAD" ]] && alive_tag="[DEAD]"
    if [[ "$pane_idx" != "DEAD" && -x "$BUSY_CHECK" ]]; then
      state=$("$BUSY_CHECK" "$S" "$W_IDX" "$pane_idx" 2>/dev/null || echo "?")
    else
      state="-"
    fi
    age=$(( local_now - last ))
    [[ "$last" -eq 0 ]] && age_str="never" || age_str="${age}s ago"
    printf "  [%d] %-6s idx=%-3s  dispatched=%-3s  last=%-12s  state=%-8s%s\n" \
      "$i" "$pid" "$pane_idx" "$count" "$age_str" "$state" "${alive_tag}${marker}"
  done
  exit 0
fi

# ── Dispatch ─────────────────────────────────────────────────────────────────

[[ "${#MESSAGE[@]}" -gt 0 ]] || {
  echo "error: no message to dispatch. Use --status to inspect." >&2; exit 1
}
TEXT="${MESSAGE[*]}"

# For idle mode: scan outside the lock (potentially wait), then re-acquire for write.
_find_idle_pane() {
  local deadline=$(( $(date +%s) + WAIT_SECONDS ))
  while true; do
    for i in "${!PANE_IDS[@]}"; do
      local pid="${PANE_IDS[$i]}"
      local pane_idx
      pane_idx=$(_pane_index "$pid") || continue
      if [[ -x "$BUSY_CHECK" ]]; then
        local state
        state=$("$BUSY_CHECK" "$S" "$W_IDX" "$pane_idx" 2>/dev/null || echo "unknown")
        [[ "$state" == "idle" ]] && echo "$i" && return 0
      else
        # No busy check — fall back to first alive pane.
        echo "$i" && return 0
      fi
    done
    local now
    now=$(date +%s)
    [[ "$now" -lt "$deadline" ]] || return 1
    echo "work-dispatch: all panes busy, waiting (${DISPATCH_MODE})..." >&2
    sleep 1
  done
}

# Resolve target index (WITHOUT lock for idle scan).
if [[ "$DISPATCH_MODE" == "idle" ]]; then
  idle_result=$(_find_idle_pane) || {
    echo "error: all ${NUM_PANES} panes busy after ${WAIT_SECONDS}s" >&2; exit 3
  }
fi

# Acquire lock, pick pane, advance pointer.
_acquire_lock

pointer=$(_read_key "$STATE_FILE" "pointer" "0")

case "$DISPATCH_MODE" in
  round-robin)
    TARGET_IDX="$pointer"
    ;;
  lru)
    best_idx=0
    best_time=9999999999
    for i in "${!PANE_IDS[@]}"; do
      pid="${PANE_IDS[$i]}"
      safe="${pid//\%/p}"
      last=$(_read_key "$STATE_FILE" "last_dispatch_${safe}" "0")
      if [[ "$last" -lt "$best_time" ]]; then
        best_time="$last"
        best_idx="$i"
      fi
    done
    TARGET_IDX="$best_idx"
    ;;
  idle)
    TARGET_IDX="${idle_result}"
    ;;
esac

# Advance pointer (always wrap round-robin regardless of mode, for consistency).
NEW_POINTER=$(( (TARGET_IDX + 1) % NUM_PANES ))

TARGET_PID="${PANE_IDS[$TARGET_IDX]}"
TARGET_PANE_IDX=$(_pane_index "$TARGET_PID") || {
  _release_lock
  echo "error: target pane ${TARGET_PID} (index ${TARGET_IDX}) is no longer alive" >&2
  exit 1
}

# Update state file atomically (still holding lock).
NOW=$(date +%s)
safe_pid="${TARGET_PID//\%/p}"
_write_key "$STATE_FILE" "pointer" "$NEW_POINTER"
_write_key "$STATE_FILE" "last_dispatch_${safe_pid}" "$NOW"
old_count=$(_read_key "$STATE_FILE" "dispatch_count_${safe_pid}" "0")
_write_key "$STATE_FILE" "dispatch_count_${safe_pid}" "$(( old_count + 1 ))"

_release_lock

# Send (after lock released — send itself is idempotent).
echo "work-dispatch → pane ${TARGET_IDX} (${TARGET_PID}, tmux-idx=${TARGET_PANE_IDX}, mode=${DISPATCH_MODE}, pointer→${NEW_POINTER}/${NUM_PANES})" >&2

# Build send command. WORKER_TYPE maps to tmux-target-send.sh mode names.
# Use --direct-target so we cross-window to the work window regardless of current window.
SEND_CMD=("$SEND")
[[ -n "$NO_REPLY_FLAG" ]] && SEND_CMD+=("$NO_REPLY_FLAG")
SEND_CMD+=("--direct-target" "${S}:${W_IDX}:${TARGET_PANE_IDX}" "$WORKER_TYPE" "$TEXT")

"${SEND_CMD[@]}"
