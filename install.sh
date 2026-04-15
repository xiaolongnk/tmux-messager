#!/usr/bin/env bash
# tmux-messager installer
# Usage: bash install.sh [--dir <path>] [--key kitty-enter|c-enter] [--non-interactive]
set -euo pipefail

# ── colours ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'
info()  { echo -e "${GREEN}▶${NC} $*"; }
warn()  { echo -e "${YELLOW}⚠${NC}  $*"; }
die()   { echo -e "${RED}✗${NC}  $*" >&2; exit 1; }
step()  { echo -e "\n${BOLD}${CYAN}$*${NC}"; }

# ── defaults ─────────────────────────────────────────────────────────────────
INSTALL_DIR="${TMUX_MESSAGER_DIR:-$HOME/.local/share/tmux-messager}"
SUBMIT_KEY=""
NON_INTERACTIVE=false

# ── parse args ───────────────────────────────────────────────────────────────
while [[ $# -gt 0 ]]; do
  case "$1" in
    --dir)           INSTALL_DIR="$2"; shift 2 ;;
    --key)           SUBMIT_KEY="$2";  shift 2 ;;
    --non-interactive) NON_INTERACTIVE=true; shift ;;
    -h|--help)
      echo "Usage: bash install.sh [--dir PATH] [--key kitty-enter|c-enter] [--non-interactive]"
      echo ""
      echo "  --dir PATH          install scripts to PATH (default: ~/.local/share/tmux-messager)"
      echo "  --key KEY           set Cursor submit key without prompting"
      echo "  --non-interactive   skip all prompts, use auto-detected values"
      exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
done

echo -e "${BOLD}tmux-messager installer${NC}"
echo "────────────────────────────────────"

# ── 1. check bash version ────────────────────────────────────────────────────
step "1/5  Checking prerequisites"

BASH_MAJOR="${BASH_VERSION%%.*}"
if [[ "$BASH_MAJOR" -lt 4 ]]; then
  die "bash 4+ required (found $BASH_VERSION)\n    macOS: brew install bash"
fi
info "bash $BASH_VERSION  ✓"

# ── 2. check tmux ────────────────────────────────────────────────────────────
if ! command -v tmux &>/dev/null; then
  die "tmux not found\n    macOS: brew install tmux"
fi
TMUX_VER="$(tmux -V | grep -oE '[0-9]+\.[0-9]+' | head -1)"
TMUX_MAJOR="${TMUX_VER%%.*}"
if [[ "$TMUX_MAJOR" -lt 3 ]]; then
  warn "tmux 3.2+ recommended (found $TMUX_VER) — some features may not work"
else
  info "tmux $TMUX_VER  ✓"
fi

# ── 3. install scripts ───────────────────────────────────────────────────────
step "2/5  Installing scripts"

SCRIPTS_SRC="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/scripts"
[[ -d "$SCRIPTS_SRC" ]] || die "scripts/ directory not found — run from the repo root"

mkdir -p "$INSTALL_DIR/scripts" "$INSTALL_DIR/sessions"
cp "$SCRIPTS_SRC"/*.sh "$INSTALL_DIR/scripts/"
chmod +x "$INSTALL_DIR/scripts/"*.sh

info "scripts installed → $INSTALL_DIR/scripts/"

# ── 4. detect + configure submit key ────────────────────────────────────────
step "3/5  Configuring Cursor submit key"

mkdir -p "$HOME/.config/claude-tmux"

if [[ -z "$SUBMIT_KEY" ]]; then
  # auto-detect
  if [[ "${TERM_PROGRAM:-}" == "ghostty" ]] || [[ -n "${GHOSTTY_RESOURCES_DIR:-}" ]]; then
    SUBMIT_KEY="kitty-enter"
    DETECTED_BY="Ghostty detected"
  elif [[ "$(uname -s)" == "Darwin" ]]; then
    SUBMIT_KEY="kitty-enter"
    DETECTED_BY="macOS default"
  else
    SUBMIT_KEY="c-enter"
    DETECTED_BY="Linux default"
  fi

  if [[ "$NON_INTERACTIVE" == false ]]; then
    echo ""
    echo "  Terminal : ${TERM_PROGRAM:-unknown}"
    echo "  Detected : $SUBMIT_KEY  ($DETECTED_BY)"
    echo ""
    read -rp "  Use '$SUBMIT_KEY' for Cursor Agent submit? [Y/n] " yn
    case "${yn,,}" in
      n|no)
        echo ""
        echo "  Options: kitty-enter (Ghostty/kitty)  |  c-enter (other terminals)"
        read -rp "  Enter submit key: " SUBMIT_KEY
        ;;
    esac
  fi
fi

echo "$SUBMIT_KEY" > "$HOME/.config/claude-tmux/cursor-submit"
info "submit key '$SUBMIT_KEY' → ~/.config/claude-tmux/cursor-submit"

# ── 5. create convenience symlinks ──────────────────────────────────────────
step "4/5  Creating convenience wrappers"

BIN_DIR="$HOME/.local/bin"
mkdir -p "$BIN_DIR"

for script in tmux-target-send cursor-dispatch tmux-pane-helper tmux-terminal-profile; do
  target="$INSTALL_DIR/scripts/${script}.sh"
  link="$BIN_DIR/$script"
  if [[ -f "$target" ]]; then
    ln -sf "$target" "$link"
    info "$script  →  $link"
  fi
done

# ── 6. path hint ─────────────────────────────────────────────────────────────
step "5/5  Path check"

if [[ ":$PATH:" != *":$BIN_DIR:"* ]]; then
  warn "$BIN_DIR is not in \$PATH"
  echo ""
  echo "  Add to ~/.bashrc / ~/.zshrc / ~/.config/fish/config.fish:"
  echo "    export PATH=\"\$HOME/.local/bin:\$PATH\"    # bash/zsh"
  echo "    fish_add_path ~/.local/bin               # fish"
else
  info "$BIN_DIR is in \$PATH  ✓"
fi

# ── done ─────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}${GREEN}Installation complete!${NC}"
echo ""
echo "  Scripts   :  $INSTALL_DIR/scripts/"
echo "  Config    :  ~/.config/claude-tmux/cursor-submit  (${SUBMIT_KEY})"
echo "  Wrappers  :  $BIN_DIR/{tmux-target-send,cursor-dispatch,…}"
echo ""
echo -e "${BOLD}Quick start:${NC}"
echo ""
echo "  # 1. Register your pane (run once per session)"
echo "  bash $INSTALL_DIR/scripts/tmux-ensure-registered.sh"
echo ""
echo "  # 2. Send a message to a Cursor Agent pane"
echo "  tmux-target-send . 2 cursor \"implement the login page\""
echo ""
echo "  # 3. Smart dispatch to any idle Cursor pane"
echo "  cursor-dispatch \"add unit tests for auth module\""
echo ""
echo "  # 4. Diagnose terminal + submit key"
echo "  tmux-terminal-profile"
echo ""
