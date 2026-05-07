#!/usr/bin/env bash
# Manage stable per-pane role tags via tmux user options.
#
# Stores @coworker-role (and @coworker-tagged-at) directly on the pane.
# Survives across pane title changes, process restarts, and Claude/Cursor
# OSC-2 title rewrites. Cleared automatically when the pane dies.
#
# Usage:
#   tmux-pane-tag.sh set    <pane> <role>     # tag a pane with a role
#   tmux-pane-tag.sh get    <pane>            # print role of one pane (or empty)
#   tmux-pane-tag.sh list                     # list all tagged panes in session
#   tmux-pane-tag.sh resolve <role>           # pane_id of pane carrying <role>
#   tmux-pane-tag.sh clear  <pane>            # remove the tag
#
# <pane> accepts: pane_id (%51), session:window.pane (0:3.2), or bare index in current window.
#
# Idempotent: calling set with an existing role on the same pane is a no-op;
# calling set with a role already used on a different pane fails unless --force.
set -euo pipefail

_resolve_pane() {
  local arg="$1"
  if [[ "$arg" == %* ]]; then
    printf '%s' "$arg"
    return
  fi
  if [[ "$arg" == *:* ]]; then
    tmux display-message -t "$arg" -p '#{pane_id}' 2>/dev/null
    return
  fi
  # Use $TMUX_PANE to anchor to the calling process's window — bare index "2" means
  # pane 2 in the calling pane's window, not in the client's currently focused window.
  local sess win
  if [[ -n "${TMUX_PANE:-}" ]]; then
    sess=$(tmux display-message -t "${TMUX_PANE}" -p '#{session_name}' 2>/dev/null) || sess=""
    win=$(tmux display-message -t "${TMUX_PANE}" -p '#{window_index}' 2>/dev/null) || win=""
  else
    sess=$(tmux display-message -p '#{session_name}' 2>/dev/null) || sess=""
    win=$(tmux display-message -p '#{window_index}' 2>/dev/null) || win=""
  fi
  tmux display-message -t "${sess}:${win}.${arg}" -p '#{pane_id}' 2>/dev/null
}

_session() {
  tmux display-message -p '#{session_name}' 2>/dev/null
}

cmd_set() {
  local pane_arg="$1" role="$2" force="${3:-0}"
  local pane_id
  pane_id=$(_resolve_pane "$pane_arg")
  [[ -n "$pane_id" ]] || { echo "error: cannot resolve pane '$pane_arg'" >&2; exit 1; }

  local existing
  existing=$(cmd_resolve "$role" 2>/dev/null || echo "")
  if [[ -n "$existing" && "$existing" != "$pane_id" && "$force" != "1" ]]; then
    echo "error: role '$role' already on pane $existing (use --force to reassign)" >&2
    exit 1
  fi

  tmux set-option -p -t "$pane_id" '@coworker-role' "$role"
  tmux set-option -p -t "$pane_id" '@coworker-tagged-at' "$(date +%s)"
  echo "tagged: $pane_id @coworker-role=$role"
}

cmd_get() {
  local pane_arg="$1"
  local pane_id
  pane_id=$(_resolve_pane "$pane_arg")
  [[ -n "$pane_id" ]] || { echo "error: cannot resolve pane '$pane_arg'" >&2; exit 1; }
  tmux show-options -pqv -t "$pane_id" '@coworker-role' 2>/dev/null
}

cmd_list() {
  local sess
  sess=$(_session)
  [[ -n "$sess" ]] || { echo "error: not inside tmux" >&2; exit 1; }
  tmux list-panes -s -t "$sess" \
    -F '#{pane_id}|#{session_name}:#{window_index}.#{pane_index}|#{@coworker-role}|#{@coworker-tagged-at}|#{pane_title}' \
    2>/dev/null \
    | awk -F'|' '$3 != "" { printf "%-6s  %-20s  role=%-15s  tagged_at=%-12s  title=%s\n", $1, $2, $3, $4, $5 }'
}

cmd_resolve() {
  local role="$1"
  local sess
  sess=$(_session)
  [[ -n "$sess" ]] || { echo "error: not inside tmux" >&2; exit 1; }
  tmux list-panes -s -t "$sess" \
    -F '#{pane_id}|#{@coworker-role}' 2>/dev/null \
    | awk -F'|' -v r="$role" '$2 == r { print $1; exit }'
}

cmd_clear() {
  local pane_arg="$1"
  local pane_id
  pane_id=$(_resolve_pane "$pane_arg")
  [[ -n "$pane_id" ]] || { echo "error: cannot resolve pane '$pane_arg'" >&2; exit 1; }
  tmux set-option -pu -t "$pane_id" '@coworker-role' 2>/dev/null || true
  tmux set-option -pu -t "$pane_id" '@coworker-tagged-at' 2>/dev/null || true
  echo "cleared: $pane_id"
}

[[ -n "${TMUX:-}" ]] || { echo "error: run inside tmux (TMUX unset)" >&2; exit 1; }

case "${1:-}" in
  set)
    shift
    force=0
    args=()
    for a in "$@"; do
      [[ "$a" == "--force" ]] && force=1 || args+=("$a")
    done
    [[ ${#args[@]} -eq 2 ]] || { echo "usage: $0 set <pane> <role> [--force]" >&2; exit 1; }
    cmd_set "${args[0]}" "${args[1]}" "$force"
    ;;
  get)
    shift
    [[ $# -eq 1 ]] || { echo "usage: $0 get <pane>" >&2; exit 1; }
    cmd_get "$1"
    ;;
  list)
    cmd_list
    ;;
  resolve)
    shift
    [[ $# -eq 1 ]] || { echo "usage: $0 resolve <role>" >&2; exit 1; }
    cmd_resolve "$1"
    ;;
  clear)
    shift
    [[ $# -eq 1 ]] || { echo "usage: $0 clear <pane>" >&2; exit 1; }
    cmd_clear "$1"
    ;;
  -h|--help|"")
    sed -n '4,18p' "$0" | sed 's/^# \{0,1\}//'
    ;;
  *)
    echo "unknown subcommand: $1" >&2
    exit 1
    ;;
esac
