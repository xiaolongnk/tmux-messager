#!/usr/bin/env bash
# Register ALL agent panes across ALL windows in the current session.
# Safe to run from any pane (Claude, shell, anywhere). bash 3 compatible.
# Writes pane_id for each detected role into the session config so
# tmux-target-send.sh can reach them regardless of which window they live in.
#
# Usage:
#   bash ./.claude/skills/tmux/scripts/tmux-register-all-panes.sh [OPTIONS]
#
# Options:
#   --session <name>   Target session (default: current)
#   --dry-run          Print what would be registered without writing
#   --layout <spec>    User-declared pane roles, e.g. "cursor:2,claude-glm:3,claude-glm2:4"
#                      Declared panes skip auto-detection. Layout is saved to
#                      /tmp/claude-tmux-layout-<session> and auto-loaded on future runs.
#   --clear-layout     Delete the saved layout file and run pure auto-detection.
#
# Detection strategy (hybrid):
#   Phase 1 — layout-declared panes (from --layout or saved layout file)
#              Pre-assigned by role name; any role string accepted (cursor, claude-glm, etc.)
#   Phase 2 — auto-detect remaining panes
#              Content fingerprinting: Cursor TUI > Gemini CLI > Claude Code
#              Binary name fallback: cmd == "cursor" (reliable, not user-settable)
#              Duplicates auto-numbered: claude-2, claude-3, cursor-2, etc.
#              Title-based sub-classification removed (titles change; unreliable).
#
# After running, send to any pane from any window:
#   bash .claude/skills/tmux/scripts/tmux-target-send.sh . cursor "hello"
#   bash .claude/skills/tmux/scripts/tmux-target-send.sh . claude "hello"
#   bash .claude/skills/tmux/scripts/tmux-target-send.sh . claude-glm "hello"
set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SESSION_CONFIG="${_SCRIPT_DIR}/tmux-session-config.sh"

DRY_RUN=0
SESSION=""
LAYOUT_SPEC=""
CLEAR_LAYOUT=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --dry-run)      DRY_RUN=1; shift ;;
    --session)      SESSION="$2"; shift 2 ;;
    --layout)       LAYOUT_SPEC="$2"; shift 2 ;;
    --clear-layout) CLEAR_LAYOUT=1; shift ;;
    -h|--help)
      sed -n '4,32p' "$0" | sed 's/^# //'
      exit 0 ;;
    *) echo "unknown arg: $1" >&2; exit 1 ;;
  esac
done

[[ -n "${TMUX:-}" ]] || { echo "error: run inside tmux (TMUX unset)" >&2; exit 1; }

if [[ -z "$SESSION" ]]; then
  SESSION=$(tmux display-message -p '#{session_name}' 2>/dev/null) \
    || { echo "error: could not determine session name" >&2; exit 1; }
fi

LAYOUT_FILE="/tmp/claude-tmux-layout-${SESSION}"

# ── Layout file management ────────────────────────────────────────────────────

if [[ "$CLEAR_LAYOUT" -eq 1 ]]; then
  if [[ -f "$LAYOUT_FILE" ]]; then
    rm -f "$LAYOUT_FILE"
    echo "Cleared layout file: ${LAYOUT_FILE}"
  else
    echo "No saved layout to clear."
  fi
  # Fall through to pure auto-detect
fi

# Persist --layout spec to file (for future tmux-init.sh auto-runs)
if [[ -n "$LAYOUT_SPEC" && "$DRY_RUN" -eq 0 ]]; then
  printf '%s' "$LAYOUT_SPEC" > "$LAYOUT_FILE"
fi

# Auto-load saved layout if no --layout arg given
if [[ -z "$LAYOUT_SPEC" && -f "$LAYOUT_FILE" && "$CLEAR_LAYOUT" -eq 0 ]]; then
  LAYOUT_SPEC=$(cat "$LAYOUT_FILE")
  echo "(loaded saved layout: ${LAYOUT_SPEC})"
fi

echo "=== tmux-register-all-panes: session='${SESSION}' dry_run=${DRY_RUN} ==="
[[ -n "$LAYOUT_SPEC" ]] && echo "    layout hints: ${LAYOUT_SPEC}"
echo ""

# ── Role tracking (bash 3 compatible: space-separated strings) ───────────────

registered_roles=""
registered_pane_ids=""
registered_count=0

_role_registered() {
  echo " $registered_roles " | grep -qF " $1 "
}

_pane_registered() {
  echo " $registered_pane_ids " | grep -qF " $1 "
}

_mark_registered() {
  registered_roles="${registered_roles} $1"
  registered_pane_ids="${registered_pane_ids} $2"
  registered_count=$(( registered_count + 1 ))
}

# Pick a unique role name for a detected type that may already be registered.
# "claude" taken → "claude-2" → "claude-3", etc.
_unique_role() {
  local base="$1"
  local candidate="$base"
  local n=2
  while _role_registered "$candidate"; do
    candidate="${base}-${n}"
    n=$(( n + 1 ))
  done
  echo "$candidate"
}

# ── Layout hint parsing ───────────────────────────────────────────────────────
# Parses "cursor:2,claude-glm:3,claude-glm2:4" into an internal lookup.
# layout_hints = newline-separated "pane_index:role" entries.

layout_hints=""

# Current window index at parse time — used to scope bare pane specs (e.g. "cursor:4").
# Use $TMUX_PANE to anchor to the calling process's window, not the client's focused window.
if [[ -n "${TMUX_PANE:-}" ]]; then
  _CURRENT_WINDOW_IDX=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}' 2>/dev/null) || _CURRENT_WINDOW_IDX="0"
else
  _CURRENT_WINDOW_IDX=$(tmux display-message -p '#{window_index}' 2>/dev/null) || _CURRENT_WINDOW_IDX="0"
fi

_parse_layout() {
  local spec="$1"
  local entry role pidx win_part pane_part
  while IFS= read -r entry; do
    [[ -z "$entry" ]] && continue
    role=$(printf '%s' "$entry" | cut -d: -f1 | tr -d ' ')
    pidx=$(printf '%s' "$entry" | cut -d: -f2- | tr -d ' ')
    if [[ -z "$role" || -z "$pidx" ]]; then
      echo "  [warn] invalid layout entry '${entry}' — expected role:pane_index" >&2
      continue
    fi
    # Support optional window-qualified form: role:window.pane (e.g. cursor:1.4)
    # Bare role:pane (e.g. cursor:4) defaults to current window.
    if [[ "$pidx" == *.* ]]; then
      win_part="${pidx%%.*}"
      pane_part="${pidx#*.}"
    else
      win_part="$_CURRENT_WINDOW_IDX"
      pane_part="$pidx"
    fi
    layout_hints="${layout_hints}${win_part}.${pane_part}:${role}"$'\n'
    echo "  [layout] pre-assign role=${role} → window=${win_part} pane_index=${pane_part}"
  done <<< "$(printf '%s' "$spec" | tr ',' '\n')"
}

# Return the layout-declared role for a given window_idx+pane_idx pair, or empty string.
_layout_role_for_index() {
  local target_win="$1"
  local target_pane="$2"
  local line key
  while IFS= read -r line; do
    [[ -z "$line" ]] && continue
    key=$(printf '%s' "$line" | cut -d: -f1)
    if [[ "$key" == "${target_win}.${target_pane}" ]]; then
      printf '%s' "$line" | cut -d: -f2-
      return
    fi
  done <<< "$layout_hints"
  echo ""
}

if [[ -n "$LAYOUT_SPEC" ]]; then
  _parse_layout "$LAYOUT_SPEC"
  echo ""
fi

# ── Submit-key detection (runs at registration — never at send time) ──────────
# Returns the tmux send-keys token that submits in this pane's TUI/shell.
# Cursor always needs kitty-enter; Gemini always needs c-m.
# For claude/shell roles, check the pane's current command: fish → kitty-enter, else c-m.
_detect_submit_key() {
  local role="$1" pane_id="$2"
  case "$role" in
    cursor|cursor-*) echo "kitty-enter"; return ;;
    gemini)          echo "c-m";         return ;;
  esac
  local cmd
  cmd=$(tmux display-message -t "$pane_id" -p '#{pane_current_command}' 2>/dev/null) || cmd=""
  if [[ "$cmd" == "fish" ]]; then
    echo "kitty-enter"
  else
    echo "c-m"
  fi
}

# ── Registration helper ───────────────────────────────────────────────────────

_register_pane() {
  local role="$1" pane_id="$2" window_idx="$3" pane_idx="$4" title="$5" source="$6"
  printf '  [%-6s]  %s pane_id=%s role=%s title='"'"'%s'"'"'\n' \
    "$source" "${SESSION}:${window_idx}.${pane_idx}" "$pane_id" "$role" "$title"
  local submit_key
  submit_key=$(_detect_submit_key "$role" "$pane_id")
  if [[ "$DRY_RUN" -eq 0 ]]; then
    bash "$SESSION_CONFIG" set-pane-id "$role" "$pane_id" 2>/dev/null \
      && echo "           → set-pane-id ${role}=${pane_id}" \
      || echo "           → WARNING: set-pane-id failed"
    bash "$SESSION_CONFIG" set-addr "$role" "${SESSION}:${window_idx}:${pane_idx}" 2>/dev/null || true
    bash "$SESSION_CONFIG" set-submit-key "$role" "$submit_key" 2>/dev/null \
      && echo "           → set-submit-key ${role}=${submit_key}" \
      || echo "           → WARNING: set-submit-key failed"
  else
    echo "           → [dry-run] would set-pane-id ${role}=${pane_id}"
    echo "           → [dry-run] would set-submit-key ${role}=${submit_key}"
  fi
  _mark_registered "$role" "$pane_id"
}

# ── Content fingerprint checks ───────────────────────────────────────────────

_is_cursor_content() {
  printf '%s' "$1" | grep -qE \
    '(Add a follow-up|Ask Agent|ctrl\+c to stop|Auto-run everything|ctrl\+r to review|files edited|Generating\.\.\.)'
}

_is_claude_content() {
  printf '%s' "$1" | grep -qE \
    '(Welcome to Claude Code|╭─|✻ Welcome|claude>|Human:|Assistant:|✓ |✗ |⏺|⠋|⠙|⠹|⠸|⠼|⠴|⠦|⠧|⠇|⠏)'
}

_is_gemini_content() {
  printf '%s' "$1" | grep -qE \
    '(Gemini CLI|gemini>|\[Gemini\]|Google Gemini|gemini-[0-9]|╔.*Gemini)'
}

# ── Phase 0: Pane-tag user-options (highest priority) ────────────────────────
# Reads @coworker-role set via tmux-pane-tag.sh. Stable across restarts and
# title changes. See tmux-pane-tag.sh for tagging details.

echo "--- Phase 0: Pane-tagged roles (@coworker-role) ---"
echo ""
phase0_count=0
while IFS= read -r raw_line; do
  window_idx=$(printf '%s' "$raw_line" | cut -d'|' -f1)
  pane_idx=$(printf '%s' "$raw_line"   | cut -d'|' -f2)
  pane_id=$(printf '%s' "$raw_line"    | cut -d'|' -f3)
  title=$(printf '%s' "$raw_line"      | cut -d'|' -f4)
  tag_role=$(printf '%s' "$raw_line"   | cut -d'|' -f5)

  [[ -z "$tag_role" ]] && continue

  if _role_registered "$tag_role"; then
    echo "  [dup]    ${SESSION}:${window_idx}.${pane_idx} role=${tag_role} — already registered"
    continue
  fi

  _register_pane "$tag_role" "$pane_id" "$window_idx" "$pane_idx" "$title" "tag"
  phase0_count=$(( phase0_count + 1 ))
done < <(tmux list-panes -s -t "$SESSION" \
  -F '#{window_index}|#{pane_index}|#{pane_id}|#{pane_title}|#{@coworker-role}' \
  2>/dev/null)

[[ "$phase0_count" -eq 0 ]] && echo "  (no panes carry @coworker-role)"
echo ""

# ── Phase 1: Layout-declared panes ───────────────────────────────────────────

if [[ -n "$LAYOUT_SPEC" ]]; then
  echo "--- Phase 1: Layout-declared panes ---"
  echo ""
  while IFS= read -r raw_line; do
    window_idx=$(printf '%s' "$raw_line" | cut -d'|' -f1)
    pane_idx=$(printf '%s' "$raw_line"   | cut -d'|' -f2)
    pane_id=$(printf '%s' "$raw_line"    | cut -d'|' -f3)
    title=$(printf '%s' "$raw_line"      | cut -d'|' -f4)

    declared_role=$(_layout_role_for_index "$window_idx" "$pane_idx")
    [[ -z "$declared_role" ]] && continue

    if _pane_registered "$pane_id"; then
      echo "  [skip]   ${SESSION}:${window_idx}.${pane_idx} pane_id=${pane_id} — already tagged in Phase 0"
      continue
    fi
    if _role_registered "$declared_role"; then
      echo "  [dup]    ${SESSION}:${window_idx}.${pane_idx} role=${declared_role} — already registered"
      continue
    fi

    _register_pane "$declared_role" "$pane_id" "$window_idx" "$pane_idx" "$title" "layout"
  done < <(tmux list-panes -s -t "$SESSION" \
    -F '#{window_index}|#{pane_index}|#{pane_id}|#{pane_title}' \
    2>/dev/null)
  echo ""
fi

# ── Phase 2: Auto-detect remaining panes ─────────────────────────────────────

echo "--- Phase 2: Auto-detect remaining panes ---"
echo ""

_MY_PANE_ID="${TMUX_PANE:-}"

while IFS= read -r raw_line; do
  window_idx=$(printf '%s' "$raw_line" | cut -d'|' -f1)
  pane_idx=$(printf '%s' "$raw_line"   | cut -d'|' -f2)
  pane_id=$(printf '%s' "$raw_line"    | cut -d'|' -f3)
  title=$(printf '%s' "$raw_line"      | cut -d'|' -f4)
  cmd=$(printf '%s' "$raw_line"        | cut -d'|' -f5)

  # Skip the pane this script is running in to avoid false self-registration.
  [[ -n "$_MY_PANE_ID" && "$pane_id" == "$_MY_PANE_ID" ]] && continue

  target="${SESSION}:${window_idx}.${pane_idx}"

  # Skip panes already registered by Phase 0 (tag) or Phase 1 (layout)
  if _pane_registered "$pane_id"; then
    echo "  [skip]   ${target} pane_id=${pane_id} — already registered (tag/layout)"
    continue
  fi

  # Skip panes already handled by layout hints
  if [[ -n "$LAYOUT_SPEC" ]]; then
    declared_role=$(_layout_role_for_index "$window_idx" "$pane_idx")
    if [[ -n "$declared_role" ]]; then
      echo "  [skip]   ${target} — pre-assigned by layout (${declared_role})"
      continue
    fi
  fi

  # Capture last 40 lines of pane content for fingerprinting
  content=$(tmux capture-pane -t "$target" -p -S -40 2>/dev/null) || content=""

  detected_base=""

  # Content fingerprinting: order = cursor > gemini > claude (highest precision first)
  if _is_cursor_content "$content"; then
    detected_base="cursor"
  elif _is_gemini_content "$content"; then
    detected_base="gemini"
  elif _is_claude_content "$content"; then
    detected_base="claude"
  # Binary name fallback — only "cursor" binary is reliably named
  elif [[ "$cmd" == "cursor" ]]; then
    detected_base="cursor"
  fi

  if [[ -z "$detected_base" ]]; then
    echo "  [skip]   ${target} pane_id=${pane_id} title='${title}' cmd=${cmd} — no fingerprint match"
    continue
  fi

  # Auto-number if this base type is already registered (first is canonical, rest get suffix)
  detected_role=$(_unique_role "$detected_base")

  _register_pane "$detected_role" "$pane_id" "$window_idx" "$pane_idx" "$title" "auto"
done < <(tmux list-panes -s -t "$SESSION" \
  -F '#{window_index}|#{pane_index}|#{pane_id}|#{pane_title}|#{pane_current_command}' \
  2>/dev/null)

echo ""
echo "=== Summary ==="
if [[ "$registered_count" -eq 0 ]]; then
  echo "No agent panes detected. Hints:"
  echo "  • Ensure Cursor / Claude agents are running (have TUI content visible in the pane)"
  echo "  • Freshly started panes may need a moment before content fingerprints appear"
  echo "  • Use --layout to declare known panes explicitly:"
  echo "      --layout 'cursor:2,claude-glm:3,claude-glm2:4'"
  echo "  • Run with --dry-run to inspect without writing"
else
  echo "Registered ${registered_count} role(s):${registered_roles}"
fi

echo ""
if [[ "$DRY_RUN" -eq 0 && "$registered_count" -gt 0 ]]; then
  echo "Done. All detected agent panes are now registered."
  echo "Communication is stable across windows — pane_id lookup is window-agnostic."
  echo ""
  if [[ -n "$LAYOUT_SPEC" ]]; then
    echo "Layout saved to: ${LAYOUT_FILE}"
    echo "Future auto-init runs will reuse this layout."
    echo "To clear: bash $0 --clear-layout"
    echo ""
  fi
  echo "Verify:"
  echo "  bash .claude/skills/tmux/scripts/tmux-session-config.sh show"
fi
