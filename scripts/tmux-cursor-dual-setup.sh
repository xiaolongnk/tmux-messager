#!/usr/bin/env bash
# Set up 2 Cursor Agent panes in the current tmux window.
# Layout: Claude (left, full height) | cursor-1 (right-top) / cursor-2 (right-bottom)
#
# Usage:
#   tmux-cursor-dual-setup.sh              # create 2 new cursor panes
#   tmux-cursor-dual-setup.sh --kill       # kill existing cursor panes first
#   tmux-cursor-dual-setup.sh --status     # show current cursor pane status
#
# Prerequisites: run inside tmux. Set CURSOR_AGENT_CMD to your Cursor/agent binary (default: cursor).
set -euo pipefail

[[ -n "${TMUX:-}" ]] || { echo "error: run inside tmux" >&2; exit 1; }

_HELPER_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HELPER="$_HELPER_DIR/tmux-pane-helper.sh"
SEND="$_HELPER_DIR/tmux-target-send.sh"

S=$(tmux display-message -p '#{session_name}') || exit 1
W=$(tmux display-message -p '#I') || exit 1

CURSOR_TITLES=("cursor-1" "cursor-2")
AGENT_CMD="${CURSOR_AGENT_CMD:-cursor}"  # override: export CURSOR_AGENT_CMD=your-binary

# Find all panes whose title starts with "cursor-" in current window.
# Falls back to "Cursor Agent" title if custom title hasn't been set yet.
find_cursor_panes() {
  local session="$1" window="$2"
  local idx title found=0
  while IFS= read -r idx; do
    title=$(tmux display-message -t "$session:${window}.${idx}" -p '#{pane_title}' 2>/dev/null) || continue
    # Match: cursor-* (lowercase), Cursor * (capital + space), or "Cursor Agent"
    if [[ "$title" =~ ^[Cc]ursor[\ \-] || "$title" == "Cursor Agent" || "$title" == "cursor" ]]; then
      echo "${idx}:${title}"
      found=1
    fi
  done < <(tmux list-panes -t "$session:$window" -F '#{pane_index}' 2>/dev/null)
  return $(( found == 0 ? 1 : 0 ))
}

cmd_status() {
  echo "=== Dual Cursor Status ==="
  echo "session=$S window=$W"
  echo ""
  local found
  found=$(find_cursor_panes "$S" "$W" || true)
  if [[ -z "$found" ]]; then
    echo "No cursor panes found."
  else
    echo "$found" | while IFS=: read -r idx title; do
      local cmd running
      cmd=$(tmux display-message -t "$S:$W.$idx" -p '#{pane_current_command}' 2>/dev/null || echo "?")
      echo "  pane $idx: title=$title command=$cmd"
    done
  fi
}

cmd_kill() {
  local found idx
  found=$(find_cursor_panes "$S" "$W" || true)
  if [[ -z "$found" ]]; then
    echo "No cursor panes to kill."
    return 0
  fi
  # Kill in reverse order to avoid pane renumbering issues.
  tail -r <<<"$found" | while IFS=: read -r idx title; do
    echo "killing pane $idx ($title)..."
    tmux kill-pane -t "$S:$W.$idx" 2>/dev/null || true
  done
  echo "All cursor panes killed."
}

cmd_setup() {
  local existing
  existing=$(find_cursor_panes "$S" "$W" || true)
  if [[ -n "$existing" ]]; then
    local count
    count=$(echo "$existing" | wc -l | tr -d ' ')
    if [[ "$count" -eq 2 ]]; then
      echo "Already have 2 cursor panes:"
      echo "$existing" | while IFS=: read -r idx title; do
        echo "  pane $idx: $title"
      done
      echo "Use --kill first to recreate."
      return 0
    fi
    echo "Found $count cursor pane(s), expected 2. Use --kill first."
    return 1
  fi

  # Find the non-Claude pane to split from, or split from current.
  # We split the current window right-side, then split that vertically.
  echo "Creating dual cursor layout..."

  # Split current window horizontally (right pane).
  tmux split-window -t "$S:$W" -h -p 50 2>/dev/null || {
    echo "error: horizontal split failed" >&2; exit 1;
  }
  # New pane is now the active one — it got the next pane index.
  # Get its index.
  local pane2
  pane2=$(tmux display-message -p '#{pane_index}' 2>/dev/null)
  tmux send-keys -t "$S:$W.$pane2" "$AGENT_CMD" C-m

  # Split pane2 vertically (bottom half).
  tmux split-window -t "$S:$W.$pane2" -v -p 50 2>/dev/null || {
    echo "error: vertical split failed" >&2; exit 1;
  }
  local pane3
  pane3=$(tmux display-message -p '#{pane_index}' 2>/dev/null)
  tmux send-keys -t "$S:$W.$pane3" "$AGENT_CMD" C-m

  # Refocus Claude pane (pane 1).
  tmux select-pane -t "$S:$W.1" 2>/dev/null || true

  # Set pane titles after a delay — Cursor Agent overwrites the title on startup.
  ( sleep 5 && tmux select-pane -t "$S:$W.$pane2" -T "cursor-1" && tmux select-pane -t "$S:$W.$pane3" -T "cursor-2" ) &

  echo "Dual cursor setup complete:"
  echo "  cursor-1 → pane $pane2 (right-top)"
  echo "  cursor-2 → pane $pane3 (right-bottom)"
  echo "  (titles will be set after agent starts ~5s)"
}

case "${1:-}" in
  --kill)   cmd_kill ;;
  --status) cmd_status ;;
  --setup|"") cmd_setup ;;
  -h|--help|help)
    echo "Usage: $(basename "$0") [--kill|--status|--setup]"
    echo "  (default)  Create 2 Cursor Agent panes in current window"
    echo "  --kill     Kill all existing cursor-* panes"
    echo "  --status   Show current cursor pane status"
    ;;
  *) echo "unknown option: $1" >&2; exit 1 ;;
esac
