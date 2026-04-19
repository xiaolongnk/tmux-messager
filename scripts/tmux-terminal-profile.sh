#!/usr/bin/env bash
# Print terminal hints for tmux → Cursor Agent submit-key defaults (agent / user onboarding).
set -euo pipefail
_SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=tmux-cursor-submit-resolve.sh
source "${_SCRIPT_DIR}/tmux-cursor-submit-resolve.sh"

echo "=== Terminal detection (for tmux-send / Cursor submit) ==="
echo "TERM_PROGRAM=${TERM_PROGRAM:-<unset>}"
echo "TERM=${TERM:-<unset>}"
echo "GHOSTTY_RESOURCES_DIR=${GHOSTTY_RESOURCES_DIR:-<unset>}"
echo "UNAME=$(uname -s 2>/dev/null || echo '?')"
echo ""
echo "Resolved default Cursor submit key (same as tmux-target-send cursor mode):"
echo "  $(resolve_tmux_cursor_submit)"
echo ""
echo "Override for this shell:"
echo "  export TMUX_TARGET_SEND_CURSOR=kitty-enter   # example"
echo ""
echo "Persistent config (first non-comment line = key name, e.g. kitty-enter):"
f="${CLAUDE_TMUX_CURSOR_SUBMIT_FILE:-${SUPERX_TMUX_CURSOR_SUBMIT_FILE:-${XDG_CONFIG_HOME:-$HOME/.config}/claude-tmux/cursor-submit}}"
echo "  $f"
echo "  (or set CLAUDE_TMUX_CURSOR_SUBMIT_FILE to another path)"
echo ""
echo "Ghostty: TERM_PROGRAM=ghostty — kitty-enter (ESC [ 13 u) = Cursor Agent submit in tmux."
echo "Manual ⌘↩ in Ghostty: keybind = cmd+enter=csi:13u   (match kitty-enter; avoid csi:13;5u for Cursor)"
