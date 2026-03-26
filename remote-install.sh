#!/usr/bin/env bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
#  envswitch remote installer
#  curl -fsSL https://raw.githubusercontent.com/YOUR_USERNAME/envswitch/main/remote-install.sh | bash
# ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e

REPO="cotopols/envswitch"
BRANCH="main"
BASE_URL="https://raw.githubusercontent.com/${REPO}/${BRANCH}"
INSTALL_DIR="$HOME/.config/envswitch"
ZSHRC="$HOME/.zshrc"
MARKER="# >>> envswitch >>>"
MARKER_END="# <<< envswitch <<<"

SNIPPET='# >>> envswitch >>>
# Docs: run "envhelp" in your terminal
# Config (optional, uncomment to override defaults):
#   export ENVSWITCH_DIR="$HOME/.envs"
#   export ENVSWITCH_EDITOR="code"
#   export ENVSWITCH_PROTECT="production:prod"
#   export ENVSWITCH_PROMPT=false  # set your own PROMPT after this line
source "$HOME/.config/envswitch/envswitch.zsh"
# <<< envswitch <<<'

echo ""
echo "📦 envswitch remote installer"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Check for curl or wget ────────────────────────────────────
download() {
  if command -v curl &>/dev/null; then
    curl -fsSL "$1"
  elif command -v wget &>/dev/null; then
    wget -qO- "$1"
  else
    echo "✖ Need curl or wget to install. Please install one and retry."
    exit 1
  fi
}

# ── Step 1: Download plugin ──────────────────────────────────
echo "→ Downloading envswitch..."
mkdir -p "$INSTALL_DIR"
download "${BASE_URL}/envswitch.zsh" > "$INSTALL_DIR/envswitch.zsh"
download "${BASE_URL}/uninstall.sh"  > "$INSTALL_DIR/uninstall.sh"
chmod +x "$INSTALL_DIR/envswitch.zsh" "$INSTALL_DIR/uninstall.sh"
echo "  ✔ Plugin installed to $INSTALL_DIR"

# ── Step 2: Create default env directory ──────────────────────
mkdir -p "$HOME/.envs"
echo "  ✔ Created $HOME/.envs"

# ── Step 3: Update .zshrc ────────────────────────────────────
if [[ -f "$ZSHRC" ]]; then
  cp "$ZSHRC" "${ZSHRC}.backup.$(date +%s)"
  echo "  ✔ Backed up .zshrc"
fi

if grep -qF "$MARKER" "$ZSHRC" 2>/dev/null; then
  sed -i.tmp "/$MARKER/,/$MARKER_END/d" "$ZSHRC"
  rm -f "${ZSHRC}.tmp"
  echo "$SNIPPET" >> "$ZSHRC"
  echo "  ✔ Updated existing envswitch block in .zshrc"
else
  touch "$ZSHRC"
  echo "" >> "$ZSHRC"
  echo "$SNIPPET" >> "$ZSHRC"
  echo "  ✔ Added envswitch to .zshrc"
fi

# ── Done ──────────────────────────────────────────────────────
echo ""
echo "✅ Installed! Now run:"
echo ""
echo "    source ~/.zshrc"
echo ""
echo "Then type 'envhelp' to see all commands."
echo "Quick start: 'addenv staging' to create your first env."
echo ""
echo "To uninstall later: bash ~/.config/envswitch/uninstall.sh"
echo ""
