#!/usr/bin/env bash
# Lightweight session-level init for the tmux skill.
# Called automatically by tmux-target-send.sh on every invocation.
#
# Fast path  (~5ms):  sentinel file exists for current pane fingerprint → exit 0 immediately.
# Slow path (~200ms): fingerprint changed or first run → register all panes + write sentinel.
#
# Sentinel file: /tmp/claude-tmux-init-<session>-<cksum(sorted-pane-ids)>
# Fingerprint = sorted list of ALL pane_ids in the session (e.g. "%9,%11,%23,%31,%33,%35,%45").
# Any pane add/remove → fingerprint changes → next invocation auto-reinits.
#
# Usage:
#   bash ./.claude/skills/tmux/scripts/tmux-init.sh [--force] [--session <name>]
#   --force   Bypass sentinel and always re-register (useful after manual layout changes).
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FORCE=0
SESSION=""

while [[ $# -gt 0 ]]; do
  case "$1" in
    --force)   FORCE=1; shift ;;
    --session) SESSION="$2"; shift 2 ;;
    -h|--help) sed -n '2,14p' "$0" | sed 's/^# //'; exit 0 ;;
    *)         echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${TMUX:-}" ]] || { echo "tmux-init: not inside tmux, skipping" >&2; exit 0; }

if [[ -z "$SESSION" ]]; then
  SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null) || {
    echo "tmux-init: could not get session name, skipping" >&2; exit 0
  }
fi

# ── Compute fingerprint ──────────────────────────────────────────────────────
# Sorted pane_id list across all windows in this session.
_fingerprint() {
  tmux list-panes -s -t "$SESSION" -F '#{pane_id}' 2>/dev/null \
    | sort | tr '\n' ',' | sed 's/,$//' || echo "unknown"
}

# Sentinel path for a given fingerprint.
_sentinel() {
  local fp="$1"
  local hash
  hash=$(printf '%s' "$fp" | cksum | awk '{print $1}')
  echo "/tmp/claude-tmux-init-${SESSION}-${hash}"
}

FP=$(_fingerprint)
SENTINEL=$(_sentinel "$FP")

# ── Fast path ────────────────────────────────────────────────────────────────
if [[ "$FORCE" -eq 0 && -f "$SENTINEL" ]]; then
  # Already initialized for this exact pane layout — done.
  exit 0
fi

# ── Slow path: register all panes ───────────────────────────────────────────
echo "tmux-init: registering session '${SESSION}' (fingerprint changed or first run)..." >&2

REGISTER="${_SCRIPT_DIR}/tmux-register-all-panes.sh"
ENSURE="${_SCRIPT_DIR}/tmux-ensure-registered.sh"

if [[ -x "$REGISTER" ]]; then
  bash "$REGISTER" --session "$SESSION" >&2 || {
    echo "tmux-init: register-all-panes failed, falling back to ensure-registered" >&2
    [[ -x "$ENSURE" ]] && bash "$ENSURE" >&2 || true
  }
elif [[ -x "$ENSURE" ]]; then
  bash "$ENSURE" >&2
fi

# ── Write sentinel ───────────────────────────────────────────────────────────
# Re-fingerprint after registration in case panes changed during the run.
FP_AFTER=$(_fingerprint)
SENTINEL_AFTER=$(_sentinel "$FP_AFTER")
touch "$SENTINEL_AFTER"

# Clean up sentinels from previous fingerprints for this session
# (avoid stale files accumulating when layout changes frequently).
for old in /tmp/claude-tmux-init-"${SESSION}"-*; do
  [[ -f "$old" ]] || continue
  [[ "$old" == "$SENTINEL_AFTER" ]] && continue
  rm -f "$old" || true
done

echo "tmux-init: done (sentinel=${SENTINEL_AFTER})" >&2
exit 0
