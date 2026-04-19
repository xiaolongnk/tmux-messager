#!/usr/bin/env bash
# Register this Claude process's pane location so subprocesses can find it via PID tree.
# Run once per Claude Code session.
#
# Usage: bash ./.claude/skills/tmux/scripts/tmux-register-pane.sh
#
# Writes TWO kinds of files:
#   /tmp/claude-pane-<PID>        for every ancestor PID up 15 levels (PID-tree lookup)
#   /tmp/claude-pane-tmux-<ID>    keyed by $TMUX_PANE id (e.g. tmux-%33 → p33) — instant lookup
#
# Both contain "session:window_index:pane_index" (e.g. "main:3:2") — the full unique triplet.
# tmux-target-send.sh checks the TMUX_PANE-keyed file first (priority 1), then walks PID tree.
set -euo pipefail

[[ -n "${TMUX:-}" ]] || { echo "error: run inside tmux (TMUX unset)" >&2; exit 1; }
[[ -n "${TMUX_PANE:-}" ]] || { echo "error: TMUX_PANE not set" >&2; exit 1; }

SESS=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}' 2>/dev/null) \
  || { echo "error: could not read session_name from TMUX_PANE=${TMUX_PANE}" >&2; exit 1; }
WIN=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}' 2>/dev/null) \
  || { echo "error: could not read window_index from TMUX_PANE=${TMUX_PANE}" >&2; exit 1; }
PANE=$(tmux display-message -t "${TMUX_PANE}" -p '#{pane_index}' 2>/dev/null) \
  || { echo "error: could not read pane_index from TMUX_PANE=${TMUX_PANE}" >&2; exit 1; }

# Store pane_id (e.g. %33) — layout-stable, never needs re-registration.
# tmux-target-send.sh resolves session:window:pane_index live at send time via
# "tmux display-message -t %33", so pane layout changes are automatically reflected.
VAL="${TMUX_PANE}"

# Write TMUX_PANE-keyed file (instant lookup — always correct, survives process churn).
TMUX_KEY="${TMUX_PANE//\%/p}"
TMUX_FILE="/tmp/claude-pane-tmux-${TMUX_KEY}"
echo "$VAL" > "$TMUX_FILE"
echo "registered: \$TMUX_PANE=${TMUX_PANE} → pane_id=${TMUX_PANE} (session=${SESS} window=${WIN} pane=${PANE} at registration time)"
echo "tmux-key file: ${TMUX_FILE}"

# Walk ancestor PIDs and register each one (PID-tree lookup).
echo ""
echo "registering ancestor PIDs:"
pid="$$"
count=0
while [[ "$pid" -gt 1 && "$count" -lt 15 ]]; do
  FILE="/tmp/claude-pane-${pid}"
  echo "$TMUX_PANE" > "$FILE"   # store pane_id, not positional index
  echo "  pid=${pid} → ${FILE}"
  pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ') || break
  [[ -z "$pid" ]] && break
  count=$(( count + 1 ))
done

echo ""
echo "Done. tmux-target-send.sh will use these files for stable reply-to detection."
echo "Re-run if you restart Claude or move it to a different pane."

# ── Register Claude's own addr in session config ────────────────────────────
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_CONFIG="${_SCRIPT_DIR}/tmux-session-config.sh"

bash "$SESSION_CONFIG" set-addr claude "${SESS}:${WIN}:${PANE}" 2>/dev/null \
  && echo "claude_addr=${SESS}:${WIN}:${PANE} → session config" \
  || echo "warning: could not write claude_addr to session config"

bash "$SESSION_CONFIG" set-pane-id claude "${TMUX_PANE}" 2>/dev/null \
  && echo "claude pane_id=${TMUX_PANE} → session config (layout-stable)" \
  || echo "warning: could not write claude pane_id to session config"

# ── Auto-locate Cursor panes in the current window ─────────────────────────
# Scan all panes by title (cursor-*, Cursor *, Cursor Agent) and by command
# (node/cursor), then register them in the session config so cursor-dispatch.sh
# uses real pane indices rather than hardcoded values.
echo ""
echo "scanning current window for Cursor panes..."

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_CONFIG="${_SCRIPT_DIR}/tmux-session-config.sh"

_current_session=$(tmux display-message -p '#{session_name}' 2>/dev/null) || _current_session=""
_current_window=$(tmux display-message -p '#{window_index}' 2>/dev/null) || _current_window="$WIN"
_my_pane="$PANE"

_cursor_panes=()
_cursor_pane_ids=()
_cursor_windows=()
while IFS='|' read -r _win_idx _idx _pid; do
  # Skip Claude's own pane.
  [[ "$_pid" == "$TMUX_PANE" ]] && continue

  _target="${_current_session}:${_win_idx}.${_idx}"

  # Primary: capture pane content and look for Cursor Agent UI fingerprints.
  # These strings appear in the Cursor Agent terminal UI regardless of pane title.
  _content=$(tmux capture-pane -t "$_target" -p -S -30 2>/dev/null) || _content=""
  _is_cursor=0
  if echo "$_content" | grep -qE \
    '(Add a follow-up|Ask Agent|ctrl\+c to stop|Auto-run everything|ctrl\+r to review|files edited|Generating\.\.\.)'; then
    _is_cursor=1
  fi

  # Fallback: title or command match (for a freshly started pane with no content yet).
  if [[ "$_is_cursor" -eq 0 ]]; then
    _title=$(tmux display-message -t "$_target" -p '#{pane_title}' 2>/dev/null) || _title=""
    _cmd=$(tmux display-message -t "$_target" -p '#{pane_current_command}' 2>/dev/null) || _cmd=""
    if [[ "$_title" =~ ^[Cc]ursor[\ \-] || "$_title" == "Cursor Agent" \
       || "$_cmd" == "cursor" ]]; then
      _is_cursor=1
    fi
  fi

  if [[ "$_is_cursor" -eq 1 ]]; then
    _cursor_panes+=("$_idx")
    _cursor_pane_ids+=("$_pid")
    _cursor_windows+=("$_win_idx")
    echo "  found cursor pane: window=${_win_idx} index=${_idx} pane_id=${_pid}"
  fi
done < <(tmux list-panes -s -t "${_current_session}" -F '#{window_index}|#{pane_index}|#{pane_id}' 2>/dev/null)

if [[ "${#_cursor_panes[@]}" -gt 0 ]]; then
  _pane_list=$(IFS=,; echo "${_cursor_panes[*]}")
  _first_win="${_cursor_windows[0]}"
  _first_pane="${_cursor_panes[0]}"
  _first_pane_id="${_cursor_pane_ids[0]}"
  # Store pane indices (backward compat) and full session:window:pane addr for first cursor (canonical pair).
  bash "$SESSION_CONFIG" set cursor "${_cursor_panes[@]}" 2>/dev/null \
    && echo "registered cursor panes → ${_pane_list} in session config" \
    || echo "warning: could not write session config (tmux-session-config.sh)"
  bash "$SESSION_CONFIG" set-addr cursor "${_current_session}:${_first_win}:${_first_pane}" 2>/dev/null \
    && echo "cursor_addr=${_current_session}:${_first_win}:${_first_pane} → session config" \
    || echo "warning: could not write cursor_addr to session config"
  # Store pane_id for first cursor pane — layout-stable, live-resolved at send time (no content scan).
  if [[ -n "$_first_pane_id" ]]; then
    bash "$SESSION_CONFIG" set-pane-id cursor "${_first_pane_id}" 2>/dev/null \
      && echo "cursor pane_id=${_first_pane_id} → session config (layout-stable)" \
      || echo "warning: could not write cursor pane_id to session config"
  fi
else
  echo "  no cursor panes found in session ${_current_session} (config unchanged)"
  echo "  hint: run tmux-cursor-dual-setup.sh to create cursor panes, then re-run this script"
fi
