#!/usr/bin/env bash
# ━━━ envswitch installer ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e

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
echo "📦 envswitch installer"
echo "━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Step 1: Copy plugin file ─────────────────────────────────
echo "→ Installing plugin to $INSTALL_DIR ..."
mkdir -p "$INSTALL_DIR"

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
if [[ -f "$SCRIPT_DIR/envswitch.zsh" ]]; then
  cp "$SCRIPT_DIR/envswitch.zsh" "$INSTALL_DIR/envswitch.zsh"
else
  echo "✖ Could not find envswitch.zsh next to this script."
  echo "  Make sure install.sh and envswitch.zsh are in the same folder."
  exit 1
fi
chmod +x "$INSTALL_DIR/envswitch.zsh"
echo "  ✔ Plugin installed"

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
