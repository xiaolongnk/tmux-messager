#!/usr/bin/env bash
# Send text to a tmux window (tab) in the current session; optional pane index.
# Cursor Agent (macOS terminal): Shift+Enter often does NOT submit; default is Ctrl+Enter.
set -euo pipefail

usage() {
  cat <<'EOF'
Usage:
  tmux-target-send.sh [options] <window> <shell|claude|cursor|gemini> <message...>
  tmux-target-send.sh [options] <window> <pane_index> <shell|claude|cursor|gemini> <message...>
  tmux-target-send.sh [options] . <shell|claude|cursor|gemini> <message...>
  tmux-target-send.sh [options] . <pane_index> <shell|claude|cursor|gemini> <message...>

  <window>     tmux window name, status-bar window index (e.g. 5), or **.** = current window
               (#{window_index} of the attached client — do not assume a fixed tab name).
  <pane_index> numeric pane index inside that window (tmux #{pane_index}).
  shell|claude After the message: C-m (Enter). Use shell for generic "type + Enter".
  cursor       After the message: submit key (see defaults below).

Options (cursor submit only; shell always uses C-m; claude supports --wait):
  --no-reply            Omit the REQUIRED reply-back instruction (use for ack/notification messages
                        to avoid infinite ack loops between agents).
  --wait N              Before sending to a claude pane: poll up to N seconds for idle state.
                        Uses claude-busy-check.sh heuristics. Default: 0 (send immediately).
                        Do NOT use --wait for reply-to injections — Claude is already idle when Cursor replies.
  --cursor-submit KEY   KEY = c-enter | kitty-c-enter | kitty-enter | kitty-enter1 |
                              kitty-ctrl4 | kitty-alt2 | s-enter | m-enter | cs-enter | cm-enter | enter
                        Default resolution (first match):
                          TMUX_TARGET_SEND_CURSOR, or
                          config file (CLAUDE_TMUX_CURSOR_SUBMIT_FILE or
                          ~/.config/claude-tmux/cursor-submit), or
                          Ghostty (TERM_PROGRAM=ghostty / GHOSTTY_RESOURCES_DIR) → kitty-enter, or
                          Darwin → kitty-enter, else c-enter.
                        In Cursor Agent TUI: use kitty-enter (ESC[13u) to submit; C-m and kitty-c-enter (13;5u) both insert a newline and must NOT be used.
  --c-enter             Ctrl+Enter via tmux named key
  --kitty-enter         ESC [ 13 u  (Cursor Agent submit in Ghostty+tmux — default when resolved)
  --kitty-c-enter       ESC [ 13 ; 5 u  (often newline in Cursor; kept for non-Cursor targets)
  --kitty-ctrl4         ESC [ 13 ; 4 u  (control modifier only — try if 5 u fails)
  --kitty-alt2          ESC [ 13 ; 2 u  (alt modifier — try for "Option+Enter")
  --s-enter             Shift+Enter
  --m-enter             Meta/Alt+Enter (often Option+Enter on Mac)
  --cs-enter            Ctrl+Shift+Enter
  --cm-enter            Ctrl+Meta+Enter
  --enter               plain Enter / C-m (last resort; often newline only)

  tmux has no "Command" key; map Cmd+Enter in Ghostty / iTerm / Terminal if needed.

Uses current session (#{session_name}). Omit pane_index to target the active pane in <window>.
Requires TMUX and tmux-pane-helper.sh in the same directory (tmux skill bundle scripts/).

**Recommended for agents:** use **.** as <window> so scripts never hard-code a tab name.
EOF
  exit 1
}

[[ -n "${TMUX:-}" ]] || { echo "error: run inside tmux (TMUX unset)" >&2; exit 1; }

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tmux-cursor-submit-resolve.sh
source "${_SCRIPT_DIR}/tmux-cursor-submit-resolve.sh"

CURSOR_SUBMIT="$(resolve_tmux_cursor_submit)"
CLAUDE_WAIT_SECONDS=0
_COLLAB_SESSION=""
_DIRECT_TARGET=""
_NO_REPLY=0

while [[ $# -gt 0 ]]; do
  case "$1" in
    --no-reply) _NO_REPLY=1; shift ;;
    --direct-target)
      # Direct full address: session:window:pane — bypasses all positional W/P resolution.
      [[ $# -ge 2 ]] || usage
      _DIRECT_TARGET="$2"; shift 2 ;;
    --session)
      [[ $# -ge 2 ]] || usage
      _COLLAB_SESSION="$2"; shift 2 ;;
    --cursor-submit)
      [[ $# -ge 2 ]] || usage
      CURSOR_SUBMIT="$2"
      shift 2
      ;;
    --c-enter) CURSOR_SUBMIT=c-enter; shift ;;
    --kitty-c-enter) CURSOR_SUBMIT=kitty-c-enter; shift ;;
    --kitty-enter) CURSOR_SUBMIT=kitty-enter; shift ;;
    --kitty-enter1) CURSOR_SUBMIT=kitty-enter1; shift ;;
    --kitty-ctrl4) CURSOR_SUBMIT=kitty-ctrl4; shift ;;
    --kitty-alt2) CURSOR_SUBMIT=kitty-alt2; shift ;;
    --s-enter) CURSOR_SUBMIT=s-enter; shift ;;
    --m-enter) CURSOR_SUBMIT=m-enter; shift ;;
    --cs-enter) CURSOR_SUBMIT=cs-enter; shift ;;
    --cm-enter) CURSOR_SUBMIT=cm-enter; shift ;;
    --enter) CURSOR_SUBMIT=enter; shift ;;
    --wait)
      [[ $# -ge 2 ]] || usage
      CLAUDE_WAIT_SECONDS="$2"; shift 2 ;;
    -h | --help | help) usage ;;
    *)
      break
      ;;
  esac
done

HELPER="${_SCRIPT_DIR}/tmux-pane-helper.sh"
SESSION_CONFIG="${_SCRIPT_DIR}/tmux-session-config.sh"
[[ -x "$HELPER" ]] || { echo "error: missing $HELPER" >&2; exit 1; }

S=$(tmux display-message -p '#{session_name}' 2>/dev/null) || { echo "error: session" >&2; exit 1; }

# --session <project>: override S/W from named collab session conf (cross-session dispatch)
if [[ -n "$_COLLAB_SESSION" ]]; then
  _collab_conf="${_SCRIPT_DIR}/../sessions/${_COLLAB_SESSION}.conf"
  [[ -f "$_collab_conf" ]] || { echo "error: no conf for collab session '${_COLLAB_SESSION}' (${_collab_conf})" >&2; exit 1; }
  _cs=$(grep "^session=" "$_collab_conf" | cut -d= -f2 | head -1)
  _cw=$(grep "^window=" "$_collab_conf" | cut -d= -f2 | head -1)
  [[ -n "$_cs" ]] || { echo "error: missing 'session=' in ${_collab_conf}" >&2; exit 1; }
  S="$_cs"
  W="${_cw:-0}"
  echo "send-keys: cross-session dispatch → session=${S} window=${W} (from ${_COLLAB_SESSION}.conf)" >&2
fi

W="${W:-}"
P=""
MODE=""

# --direct-target session:window:pane — skip all positional W/P resolution.
if [[ -n "${_DIRECT_TARGET:-}" ]]; then
  IFS=: read -r _dt_s _dt_w _dt_p <<< "$_DIRECT_TARGET"
  [[ -n "$_dt_s" && -n "$_dt_w" && -n "$_dt_p" ]] \
    || { echo "error: --direct-target must be session:window:pane (got '${_DIRECT_TARGET}')" >&2; exit 1; }
  S="$_dt_s"
  W="$_dt_w"
  P="$_dt_p"
  if [[ $# -ge 1 && ( "$1" == cursor || "$1" == claude || "$1" == shell || "$1" == gemini ) ]]; then
    MODE="$1"; shift
  else
    MODE="claude"
  fi
# `.` = current client's window index (never assume a fixed window name).
elif [[ "${1:-}" == . ]]; then
  W=$(tmux display-message -p '#I' 2>/dev/null) || { echo "error: could not resolve current window (.)" >&2; exit 1; }
  shift
  if [[ $# -ge 2 && "$1" =~ ^[0-9]+$ && ( "$2" == cursor || "$2" == claude || "$2" == shell || "$2" == gemini ) ]]; then
    P="$1"
    MODE="$2"
    shift 2
  elif [[ $# -ge 1 && ( "$1" == cursor || "$1" == claude || "$1" == shell || "$1" == gemini ) ]]; then
    MODE="$1"
    shift
  else
    usage
  fi
else
  [[ $# -ge 3 ]] || usage
  # Prefer 3-token head (window + pane + mode) when $3 is the mode — avoids treating pane index as window name.
  if [[ $# -ge 3 && ( "$3" == cursor || "$3" == claude || "$3" == shell || "$3" == gemini ) ]]; then
    W="$1"
    P="$2"
    MODE="$3"
    shift 3
  elif [[ $# -ge 2 && ( "$2" == cursor || "$2" == claude || "$2" == shell || "$2" == gemini ) ]]; then
    W="$1"
    MODE="$2"
    shift 2
  else
    usage
  fi
fi

[[ -n "${*:-}" ]] || { echo "error: empty message" >&2; exit 1; }
TEXT="$*"

if [[ -z "$P" ]]; then
  if [[ "$MODE" == "cursor" && -x "$SESSION_CONFIG" ]]; then
    # Prefer pane_id lookup — layout-stable, resolves live without content scan.
    _cursor_pane_id=$("$SESSION_CONFIG" get-pane-id cursor 2>/dev/null) || _cursor_pane_id=""
    if [[ "$_cursor_pane_id" =~ ^%[0-9]+$ ]]; then
      P=$(tmux display-message -t "${_cursor_pane_id}" -p '#{pane_index}' 2>/dev/null) || P=""
      [[ -n "$P" ]] && echo "send-keys: cursor pane via pane_id ${_cursor_pane_id} (live) → index=${P}" >&2
    fi
    # Fallback: content-based scan (used when pane_id not yet registered or pane gone).
    if [[ -z "$P" ]]; then
      P=$("$SESSION_CONFIG" find-cursor "$S" "$W" 2>/dev/null) || P=""
      [[ -n "$P" ]] || { echo "error: no cursor pane found in $S:$W (run tmux-register-pane.sh)" >&2; exit 1; }
      echo "send-keys: cursor pane via content scan → index=${P} in $S:$W" >&2
    fi
  elif [[ "$MODE" == "claude" && -x "$SESSION_CONFIG" ]]; then
    # Prefer pane_id lookup — layout-stable, written by tmux-register-pane.sh.
    _claude_pane_id=$("$SESSION_CONFIG" get-pane-id claude 2>/dev/null) || _claude_pane_id=""
    if [[ "$_claude_pane_id" =~ ^%[0-9]+$ ]]; then
      P=$(tmux display-message -t "${_claude_pane_id}" -p '#{pane_index}' 2>/dev/null) || P=""
      [[ -n "$P" ]] && echo "send-keys: claude pane via pane_id ${_claude_pane_id} (live) → index=${P}" >&2
    fi
    # Fallback: active pane.
    if [[ -z "$P" ]]; then
      P=$("$HELPER" active-pane "$S" "$W") || { echo "error: active-pane in $S:$W" >&2; exit 1; }
    fi
  else
    P=$("$HELPER" active-pane "$S" "$W") || { echo "error: active-pane in $S:$W" >&2; exit 1; }
  fi
fi

TARGET="${S}:${W}.${P}"

# Append reply-to address (cursor/gemini/claude modes) so the receiver knows where to reply.
# Priority: registered file (explicit, survives pane ID drift) → $TMUX_PANE → session config.
# Note: $TMUX_PANE is inherited from process launch — if tmux pane layout changed after
# launch, $TMUX_PANE may point to a different pane index than where Claude is now.
# The registered file (written by tmux-register-pane.sh) stores the explicit address and
# is preferred when available.
if [[ "$MODE" == "cursor" || "$MODE" == "gemini" || "$MODE" == "claude" ]]; then
  # Self-heal: if registered file is missing or in legacy format, auto-register now.
  # Only needed for TUI modes (cursor/gemini) that require stable pane_id registration.
  if [[ "$MODE" == "cursor" || "$MODE" == "gemini" ]]; then
    if [[ -n "${TMUX_PANE:-}" ]]; then
      _heal_key="${TMUX_PANE//\%/p}"
      _heal_file="/tmp/claude-pane-tmux-${_heal_key}"
      _heal_val=""
      [[ -f "$_heal_file" ]] && _heal_val=$(cat "$_heal_file" 2>/dev/null) || true
      if [[ ! "$_heal_val" =~ ^%[0-9]+$ ]]; then
        echo "send-keys: registration missing/stale — auto-registering" >&2
        bash "${_SCRIPT_DIR}/tmux-ensure-registered.sh" >/dev/null 2>&1 || true
      fi
    fi
  fi

  SENDER_S=""
  SENDER_W=""
  SENDER_P=""

  # 0. Registered file: written by tmux-register-pane.sh.
  #    Stores pane_id (e.g. %33) — layout-stable, never goes stale even when panes are
  #    reordered or recreated. Resolve session:window:pane_index live at send time.
  if [[ -n "${TMUX_PANE:-}" ]]; then
    _tmux_key="${TMUX_PANE//\%/p}"
    _reg_file="/tmp/claude-pane-tmux-${_tmux_key}"
    if [[ -f "$_reg_file" ]]; then
      _reg_val=$(cat "$_reg_file" 2>/dev/null) || _reg_val=""
      if [[ "$_reg_val" =~ ^%[0-9]+$ ]]; then
        # New format: pane_id — resolve current position live (never stale).
        SENDER_S=$(tmux display-message -t "${_reg_val}" -p '#{session_name}' 2>/dev/null) || SENDER_S=""
        SENDER_W=$(tmux display-message -t "${_reg_val}" -p '#{window_index}' 2>/dev/null) || SENDER_W=""
        SENDER_P=$(tmux display-message -t "${_reg_val}" -p '#{pane_index}' 2>/dev/null) || SENDER_P=""
        [[ -n "$SENDER_P" ]] && echo "send-keys: sender via pane_id ${_reg_val} (live) → ${SENDER_S}:${SENDER_W}:${SENDER_P}" >&2
      elif [[ "$_reg_val" =~ ^[^:]+:[^:]+:[^:]+$ ]]; then
        # Legacy format: session:window:pane_index — may be stale after layout changes.
        IFS=: read -r SENDER_S SENDER_W SENDER_P <<< "$_reg_val"
        echo "send-keys: sender via registered file (legacy) ${_reg_file} → ${_reg_val}" >&2
      fi
    fi
  fi

  # 1. $TMUX_PANE: fallback when registered file is absent or malformed.
  #    Use tmux display-message to get the live session_name, window_index, and pane_index.
  if [[ -z "$SENDER_P" && -n "${TMUX_PANE:-}" ]]; then
    SENDER_S=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}' 2>/dev/null) || SENDER_S=""
    SENDER_W=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}' 2>/dev/null) || SENDER_W=""
    SENDER_P=$(tmux display-message -t "${TMUX_PANE}" -p '#{pane_index}' 2>/dev/null) || SENDER_P=""
    [[ -n "$SENDER_P" ]] && echo "send-keys: sender via \$TMUX_PANE=${TMUX_PANE} → session=${SENDER_S} window=${SENDER_W} pane=${SENDER_P}" >&2
  fi

  # 2. Session config: last resort — may be stale if pane layout changed.
  #    Uses get-addr claude to retrieve full session:window:pane triplet.
  if [[ -z "$SENDER_P" && -x "$SESSION_CONFIG" ]]; then
    _claude_addr=$("$SESSION_CONFIG" get-addr claude 2>/dev/null) || _claude_addr=""
    if [[ -n "$_claude_addr" ]]; then
      IFS=: read -r SENDER_S SENDER_W SENDER_P <<< "$_claude_addr"
      echo "send-keys: sender via session config get-addr → ${_claude_addr} (WARNING: may be stale — run tmux-register-pane.sh)" >&2
    fi
  fi
  if [[ -n "$SENDER_S" && -n "$SENDER_W" && -n "$SENDER_P" && "$_NO_REPLY" -eq 0 ]]; then
    # Determine correct reply mode: match sender's pane role so receiver uses the right submit key.
    _reply_mode="claude"
    if [[ -n "${TMUX_PANE:-}" && -x "$SESSION_CONFIG" ]]; then
      _cursor_pane_id_chk=$("$SESSION_CONFIG" get-pane-id cursor 2>/dev/null) || _cursor_pane_id_chk=""
      _gemini_pane_id_chk=$("$SESSION_CONFIG" get-pane-id gemini 2>/dev/null) || _gemini_pane_id_chk=""
      if [[ -n "$_cursor_pane_id_chk" && "$TMUX_PANE" == "$_cursor_pane_id_chk" ]]; then
        _reply_mode="cursor"
      elif [[ -n "$_gemini_pane_id_chk" && "$TMUX_PANE" == "$_gemini_pane_id_chk" ]]; then
        _reply_mode="gemini"
      fi
    fi
    TEXT="${TEXT}

---
REQUIRED: After completing the task above, run this bash command in your terminal to send your reply back (do not just print it — execute it):
  bash ./.claude/skills/tmux/scripts/tmux-target-send.sh --direct-target ${SENDER_S}:${SENDER_W}:${SENDER_P} ${_reply_mode} \"your reply here\"
Replace \"your reply here\" with a concise summary of what you did."
  fi
fi

cursor_send_submit() {
  local key
  key=$(echo "$1" | tr '[:upper:]' '[:lower:]')

  # NOTE: Do NOT auto-upgrade kitty-enter → kitty-c-enter for multi-line text.
  # kitty-c-enter (ESC[13;5u) causes a newline in Cursor rather than submitting,
  # which leaves Cursor stuck in multi-line mode and can trigger tmux passthrough/forward mode.
  # kitty-enter (ESC[13u) is the correct submit key for Cursor in Ghostty/kitty+tmux.

  case "$key" in
    s-enter | shift-enter) tmux send-keys -t "$TARGET" "$TEXT" S-Enter ;;
    c-enter | ctrl-enter) tmux send-keys -t "$TARGET" "$TEXT" C-Enter ;;
    m-enter | meta-enter | alt-enter) tmux send-keys -t "$TARGET" "$TEXT" M-Enter ;;
    cs-enter | ctrl-shift-enter) tmux send-keys -t "$TARGET" "$TEXT" C-S-Enter ;;
    cm-enter | ctrl-meta-enter) tmux send-keys -t "$TARGET" "$TEXT" C-M-Enter ;;
    enter | return | c-m | plain) tmux send-keys -t "$TARGET" "$TEXT" C-m ;;
    kitty-c-enter | csi-13-5 | xtermjs-c-enter)
      tmux send-keys -t "$TARGET" "$TEXT"
      sleep 0.3
      tmux send-keys -t "$TARGET" $'\e[13;5u'
      ;;
    kitty-enter | kitty-plain-enter | csi-13u)
      tmux send-keys -t "$TARGET" "$TEXT"
      sleep 0.1
      tmux send-keys -t "$TARGET" $'\e[13u'
      ;;
    kitty-enter1 | csi-13-1u)
      tmux send-keys -t "$TARGET" "$TEXT"
      sleep 0.1
      tmux send-keys -t "$TARGET" $'\e[13;1u'
      ;;
    kitty-ctrl4 | csi-13-4)
      tmux send-keys -t "$TARGET" "$TEXT"
      sleep 0.1
      tmux send-keys -t "$TARGET" $'\e[13;4u'
      ;;
    kitty-alt2 | csi-13-2)
      tmux send-keys -t "$TARGET" "$TEXT"
      sleep 0.1
      tmux send-keys -t "$TARGET" $'\e[13;2u'
      ;;
    *)
      echo "error: unknown --cursor-submit / TMUX_TARGET_SEND_CURSOR: $key (try kitty-enter, kitty-c-enter, kitty-ctrl4, kitty-alt2, c-enter, m-enter, cs-enter, cm-enter, s-enter, enter)" >&2
      return 1
      ;;
  esac
}

echo "send-keys -> -t $TARGET mode=$MODE cursor_submit=${CURSOR_SUBMIT} claude_wait=${CLAUDE_WAIT_SECONDS}" >&2

# For claude mode with --wait: poll until Claude Code is idle before sending.
_claude_wait_idle() {
  local wait_sec="$1"
  local check="${_SCRIPT_DIR}/claude-busy-check.sh"
  [[ -x "$check" ]] || { echo "send-keys: claude-busy-check.sh not found, sending immediately" >&2; return 0; }
  local deadline=$(( $(date +%s) + wait_sec ))
  while true; do
    local state
    state=$("$check" "$S" "$W" "$P" 2>/dev/null || echo "unknown")
    if [[ "$state" == "idle" ]]; then
      echo "send-keys: claude pane $P is idle — sending" >&2
      return 0
    fi
    local now
    now=$(date +%s)
    if [[ "$now" -ge "$deadline" ]]; then
      echo "send-keys: claude pane $P still $state after ${wait_sec}s — sending anyway" >&2
      return 0
    fi
    echo "send-keys: claude pane $P is $state — waiting..." >&2
    sleep 2
  done
}

# Exit copy-mode / choice-mode before sending — prevents the "jump forward" bug
# where rapid loop messages scroll the pane into copy-mode and `f` in the text
# triggers tmux's vi-key jump-forward binding instead of reaching the shell.
_exit_copy_mode() {
  tmux send-keys -t "$1" -X cancel 2>/dev/null || true
}

case "$MODE" in
  cursor|gemini)
    _exit_copy_mode "$TARGET"
    cursor_send_submit "$CURSOR_SUBMIT" || exit 1 ;;
  claude)
    if [[ "$CLAUDE_WAIT_SECONDS" -gt 0 ]]; then
      _claude_wait_idle "$CLAUDE_WAIT_SECONDS"
    fi
    _exit_copy_mode "$TARGET"
    tmux send-keys -t "$TARGET" "$TEXT"
    sleep 0.1
    tmux send-keys -t "$TARGET" C-m
    ;;
  shell) tmux send-keys -t "$TARGET" "$TEXT" C-m ;;
  *) usage ;;
esac
