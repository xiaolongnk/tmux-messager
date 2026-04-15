#!/usr/bin/env bash
# Ensure the current Claude session's pane is registered for reply-to detection.
# Run automatically at the start of any tmux-send skill invocation.
#
# Steps:
#   1. Auto-clean stale /tmp/claude-pane-* files:
#        - PID files  (/tmp/claude-pane-<NUMBER>)     → remove if PID no longer alive
#        - tmux files (/tmp/claude-pane-tmux-<key>)   → remove if tmux pane no longer exists
#   2. If /tmp/claude-pane-tmux-<TMUX_PANE_KEY> exists → already registered, skip.
#      Otherwise → auto-register by running tmux-register-pane.sh.
#
# Usage:
#   bash ./.claude/skills/tmux/scripts/tmux-ensure-registered.sh
#
# Exit codes:
#   0 — already registered or newly registered successfully
#   1 — not inside tmux (TMUX unset)
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Must be inside tmux.
if [[ -z "${TMUX:-}" ]]; then
  echo "error: not inside tmux (TMUX unset) — tmux skill requires tmux" >&2
  exit 1
fi

# ── Step 1: auto-clean stale files ──────────────────────────────────────────
cleaned=0

for f in $(ls /tmp/claude-pane-* 2>/dev/null); do
  [[ -f "$f" ]] || continue
  fname="$(basename "$f")"

  if [[ "$fname" =~ ^claude-pane-tmux-(.+)$ ]]; then
    # tmux-keyed file: /tmp/claude-pane-tmux-p35
    # Key "p35" → tmux pane "%35". Check if the pane still exists.
    key="${BASH_REMATCH[1]}"
    pane_id="%${key#p}"   # "p35" → "%35"
    if ! tmux display-message -t "$pane_id" -p '#{pane_id}' &>/dev/null; then
      rm -f "$f"
      echo "cleaned stale tmux-pane file: ${f} (pane ${pane_id} no longer exists)"
      ((cleaned++)) || true
    fi

  elif [[ "$fname" =~ ^claude-pane-([0-9]+)$ ]]; then
    # PID file: /tmp/claude-pane-98990
    pid="${BASH_REMATCH[1]}"
    if ! kill -0 "$pid" 2>/dev/null; then
      rm -f "$f"
      echo "cleaned stale PID file: ${f} (pid ${pid} not alive)"
      ((cleaned++)) || true
    fi
  fi
done

[[ "$cleaned" -gt 0 ]] && echo "auto-cleaned ${cleaned} stale file(s)."

# ── Step 2: ensure this session is registered ───────────────────────────────
TMUX_KEY="${TMUX_PANE//\%/p}"
TMUX_FILE="/tmp/claude-pane-tmux-${TMUX_KEY}"

if [[ -f "$TMUX_FILE" ]]; then
  VAL="$(cat "$TMUX_FILE" 2>/dev/null)" || VAL=""
  if [[ "$VAL" =~ ^%[0-9]+$ ]]; then
    echo "pane already registered: \$TMUX_PANE=${TMUX_PANE} → pane_id=${VAL}"
  else
    # Legacy format (session:window:pane_index) or malformed — re-register to get stable pane_id.
    echo "registration stale (legacy format '${VAL}') — re-registering with pane_id ..."
    bash "${_SCRIPT_DIR}/tmux-register-pane.sh"
  fi
else
  echo "pane not registered — running tmux-register-pane.sh ..."
  bash "${_SCRIPT_DIR}/tmux-register-pane.sh"
fi
