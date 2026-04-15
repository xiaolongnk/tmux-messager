#!/usr/bin/env bash
# Resolve default Cursor-Agent submit key for tmux-target-send / tmux-pane-helper send.
# Single source of truth — source from other scripts, do not execute standalone.
# shellcheck shell=bash

# Priority:
#   1) TMUX_TARGET_SEND_CURSOR (set in environment, even empty → ${var:-c-enter})
#   2) First non-comment line in config file (see below)
#   3) Ghostty → kitty-enter (ESC [ 13 u — Cursor Agent in Ghostty+tmux; NOT kitty-c-enter)
#   4) Darwin → kitty-enter
#   5) Else → c-enter
resolve_tmux_cursor_submit() {
  if [[ -n "${TMUX_TARGET_SEND_CURSOR+x}" ]]; then
    printf '%s\n' "${TMUX_TARGET_SEND_CURSOR:-c-enter}"
    return 0
  fi

  local f line
  f="${CLAUDE_TMUX_CURSOR_SUBMIT_FILE:-${SUPERX_TMUX_CURSOR_SUBMIT_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-tmux/cursor-submit}}"
  if [[ -f "$f" ]]; then
    line=$(grep -v '^[[:space:]]*#' "$f" | grep -m1 -v '^[[:space:]]*$' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//') || true
    if [[ -n "$line" ]]; then
      printf '%s\n' "$line"
      return 0
    fi
  fi

  if [[ "${TERM_PROGRAM:-}" == "ghostty" ]] || [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
    printf '%s\n' kitty-enter
    return 0
  fi

  case "$(uname -s 2>/dev/null)" in
    Darwin) printf '%s\n' kitty-enter ;;
    *) printf '%s\n' c-enter ;;
  esac
}
