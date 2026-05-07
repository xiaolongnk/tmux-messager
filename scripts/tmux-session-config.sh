#!/usr/bin/env bash
# Per-session tmux layout config — maps roles (claude/cursor/shell) to pane indices.
#
# Config files: .claude/skills/tmux/sessions/<session-name>.conf
# Format: key=value, one per line, comments with #
#
# Usage:
#   tmux-session-config.sh get <role>               → print comma-list of pane indices
#   tmux-session-config.sh get-first <role>          → print first pane index only
#   tmux-session-config.sh set <role> <pane...>      → write/update entry in config
#   tmux-session-config.sh show                      → print all roles for current session
#   tmux-session-config.sh path                      → print config file path
#
# Examples:
#   tmux-session-config.sh get cursor        → "3,4"
#   tmux-session-config.sh get-first claude  → "1"
#   tmux-session-config.sh set cursor 3 4   → writes cursor_panes=3,4
#   tmux-session-config.sh set claude 1     → writes claude_panes=1
#
# If no config file exists, all commands return empty (no error) so callers can fall back gracefully.

set -euo pipefail

_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_SESSIONS_DIR="/tmp/claude-tmux-sessions"
mkdir -p "$_SESSIONS_DIR"

# Resolve current session name (works inside or outside tmux).
_session() {
  if [[ -n "${TMUX:-}" ]]; then
    tmux display-message -p '#{session_name}' 2>/dev/null || echo ""
  else
    echo ""
  fi
}

_config_path() {
  local session="${1:-$(_session)}"
  echo "${_SESSIONS_DIR}/${session}.conf"
}

_read_key() {
  local file="$1"
  local key="$2"
  [[ -f "$file" ]] || return 0
  grep -F "${key}=" "$file" 2>/dev/null | awk -F= -v k="$key" '$1==k { print substr($0, length($1)+2); exit }' || true
}

_role_key() {
  local role="$1"
  case "$role" in
    claude) echo "claude_panes" ;;
    cursor) echo "cursor_panes" ;;
    shell)  echo "shell_panes"  ;;
    *)      echo "${role}_panes" ;;
  esac
}

CMD="${1:-}"
shift || true

case "$CMD" in
  get)
    role="${1:-cursor}"
    session="${2:-$(_session)}"
    cfg=$(_config_path "$session")
    key=$(_role_key "$role")
    _read_key "$cfg" "$key"
    ;;

  get-first)
    role="${1:-cursor}"
    session="${2:-$(_session)}"
    cfg=$(_config_path "$session")
    key=$(_role_key "$role")
    val=$(_read_key "$cfg" "$key")
    echo "${val%%,*}"
    ;;

  set)
    role="${1:-}"; shift || true
    [[ -n "$role" ]] || { echo "usage: set <role> <pane...>" >&2; exit 1; }
    [[ $# -ge 1 ]] || { echo "usage: set <role> <pane...>" >&2; exit 1; }
    session="${CLAUDE_TMUX_SESSION_NAME:-$(_session)}"
    cfg=$(_config_path "$session")
    key=$(_role_key "$role")
    val=$(IFS=,; echo "$*")

    mkdir -p "$(dirname "$cfg")"

    if [[ -f "$cfg" ]] && grep -qF "${key}=" "$cfg" 2>/dev/null && awk -F= -v k="$key" '$1==k{found=1;exit} END{exit !found}' "$cfg" 2>/dev/null; then
      # Update existing line using awk (safe against | in val).
      tmp=$(mktemp)
      awk -F= -v k="$key" -v v="$val" 'BEGIN{OFS="="} $1==k{$2=v; print k"="v; next} 1' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    else
      # Append new entry.
      echo "${key}=${val}" >> "$cfg"
    fi
    echo "set ${role} → ${val} in ${cfg}" >&2
    ;;

  set-addr)
    # Store full session:window:pane triplet for a role (e.g. claude_addr, cursor_addr).
    # Usage: tmux-session-config.sh set-addr <role> <session:window:pane>
    role="${1:-}"; shift || true
    addr="${1:-}"; shift || true
    [[ -n "$role" ]] || { echo "usage: set-addr <role> <session:window:pane>" >&2; exit 1; }
    [[ -n "$addr" ]] || { echo "usage: set-addr <role> <session:window:pane>" >&2; exit 1; }
    session="${CLAUDE_TMUX_SESSION_NAME:-$(_session)}"
    cfg=$(_config_path "$session")
    key="${role}_addr"
    mkdir -p "$(dirname "$cfg")"
    if [[ -f "$cfg" ]] && awk -F= -v k="$key" '$1==k{found=1;exit} END{exit !found}' "$cfg" 2>/dev/null; then
      tmp=$(mktemp)
      awk -F= -v k="$key" -v v="$addr" '$1==k{print k"="v; next} 1' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    else
      echo "${key}=${addr}" >> "$cfg"
    fi
    echo "set-addr ${role} → ${addr} in ${cfg}" >&2
    ;;

  get-addr)
    # Retrieve full session:window:pane triplet for a role.
    # Usage: tmux-session-config.sh get-addr <role> [session]
    role="${1:-cursor}"
    session="${2:-$(_session)}"
    cfg=$(_config_path "$session")
    _read_key "$cfg" "${role}_addr"
    ;;

  set-pane-id)
    # Store pane_id (e.g. %33) for a role — layout-stable, never goes stale.
    # Usage: tmux-session-config.sh set-pane-id <role> <pane_id>
    role="${1:-}"; shift || true
    pane_id="${1:-}"; shift || true
    [[ -n "$role" ]] || { echo "usage: set-pane-id <role> <pane_id>" >&2; exit 1; }
    [[ -n "$pane_id" ]] || { echo "usage: set-pane-id <role> <pane_id>" >&2; exit 1; }
    session="${CLAUDE_TMUX_SESSION_NAME:-$(_session)}"
    cfg=$(_config_path "$session")
    key="${role}_pane_id"
    mkdir -p "$(dirname "$cfg")"
    if [[ -f "$cfg" ]] && awk -F= -v k="$key" '$1==k{found=1;exit} END{exit !found}' "$cfg" 2>/dev/null; then
      tmp=$(mktemp)
      awk -F= -v k="$key" -v v="$pane_id" '$1==k{print k"="v; next} 1' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    else
      echo "${key}=${pane_id}" >> "$cfg"
    fi
    echo "set-pane-id ${role} → ${pane_id} in ${cfg}" >&2
    ;;

  get-pane-id)
    # Retrieve pane_id (e.g. %33) for a role.
    # Usage: tmux-session-config.sh get-pane-id <role> [session]
    role="${1:-cursor}"
    session="${2:-$(_session)}"
    cfg=$(_config_path "$session")
    _read_key "$cfg" "${role}_pane_id"
    ;;

  set-submit-key)
    # Store the submit key for a role (kitty-enter, c-m, c-enter, …).
    # Set at registration time so send scripts never re-detect at runtime.
    # Usage: tmux-session-config.sh set-submit-key <role> <key>
    role="${1:-}"; shift || true
    key="${1:-}";  shift || true
    [[ -n "$role" ]] || { echo "usage: set-submit-key <role> <key>" >&2; exit 1; }
    [[ -n "$key"  ]] || { echo "usage: set-submit-key <role> <key>" >&2; exit 1; }
    session="${CLAUDE_TMUX_SESSION_NAME:-$(_session)}"
    cfg=$(_config_path "$session")
    skey="${role}_submit_key"
    mkdir -p "$(dirname "$cfg")"
    if [[ -f "$cfg" ]] && awk -F= -v k="$skey" '$1==k{found=1;exit} END{exit !found}' "$cfg" 2>/dev/null; then
      tmp=$(mktemp)
      awk -F= -v k="$skey" -v v="$key" '$1==k{print k"="v; next} 1' "$cfg" > "$tmp" && mv "$tmp" "$cfg"
    else
      echo "${skey}=${key}" >> "$cfg"
    fi
    echo "set-submit-key ${role} → ${key} in ${cfg}" >&2
    ;;

  get-submit-key)
    # Retrieve the stored submit key for a role, or empty string if not set.
    # Usage: tmux-session-config.sh get-submit-key <role> [session]
    role="${1:-}"
    session="${2:-$(_session)}"
    cfg=$(_config_path "$session")
    _read_key "$cfg" "${role}_submit_key"
    ;;

  show)
    session="${1:-$(_session)}"
    cfg=$(_config_path "$session")
    if [[ ! -f "$cfg" ]]; then
      echo "no config for session '${session}' (${cfg})" >&2
      exit 0
    fi
    echo "session config: ${cfg}"
    grep -v '^#' "$cfg" | grep -v '^$' || true
    ;;

  path)
    session="${1:-$(_session)}"
    _config_path "$session"
    ;;

  find-cursor)
    # Scan ALL panes in current window for Cursor Agent panes.
    # Primary detection: pane content fingerprints (UI strings unique to Cursor Agent).
    # Fallback: title pattern or command name (for freshly started panes).
    # Usage: tmux-session-config.sh find-cursor [session [window]]
    # Prints one pane index per line. Exits 0 if any found, 1 if none.
    session="${1:-$(_session)}"
    if [[ -n "${TMUX_PANE:-}" ]]; then
      window="${2:-$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}' 2>/dev/null)}"
    else
      window="${2:-$(tmux display-message -p '#I' 2>/dev/null)}"
    fi
    found=0
    while IFS= read -r p; do
      target="${session}:${window}.${p}"
      is_cursor=0
      # Primary: content-based fingerprint (reliable regardless of pane title).
      content=$(tmux capture-pane -t "$target" -p -S -30 2>/dev/null) || content=""
      if echo "$content" | grep -qE \
        '(Add a follow-up|Ask Agent|ctrl\+c to stop|Auto-run everything|ctrl\+r to review|files edited|Generating\.\.\.)'; then
        is_cursor=1
      fi
      # Fallback: title or command.
      if [[ "$is_cursor" -eq 0 ]]; then
        title=$(tmux display-message -t "$target" -p '#{pane_title}' 2>/dev/null) || title=""
        cmd=$(tmux display-message -t "$target" -p '#{pane_current_command}' 2>/dev/null) || cmd=""
        if [[ "$title" =~ ^[Cc]ursor[\ \-] || "$title" == "Cursor Agent" || "$cmd" == "cursor" ]]; then
          is_cursor=1
        fi
      fi
      if [[ "$is_cursor" -eq 1 ]]; then
        echo "$p"
        found=1
      fi
    done < <(tmux list-panes -t "${session}:${window}" -F '#{pane_index}' 2>/dev/null)
    [[ "$found" -eq 1 ]] && exit 0 || exit 1
    ;;

  ""|--help|-h|help)
    sed -n '2,20p' "$0" | sed 's/^# //'
    ;;

  *)
    echo "unknown command: $CMD" >&2
    exit 1
    ;;
esac
