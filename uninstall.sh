#!/usr/bin/env bash
# ━━━ envswitch uninstaller ━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
set -e

INSTALL_DIR="$HOME/.config/envswitch"
ZSHRC="$HOME/.zshrc"
MARKER="# >>> envswitch >>>"
MARKER_END="# <<< envswitch <<<"

echo ""
echo "🗑  envswitch uninstaller"
echo "━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""

# ── Remove from .zshrc ────────────────────────────────────────
if grep -qF "$MARKER" "$ZSHRC" 2>/dev/null; then
  cp "$ZSHRC" "${ZSHRC}.backup.$(date +%s)"
  sed -i.tmp "/$MARKER/,/$MARKER_END/d" "$ZSHRC"
  rm -f "${ZSHRC}.tmp"
  echo "  ✔ Removed envswitch block from .zshrc"
else
  echo "  · No envswitch block found in .zshrc"
fi

# ── Remove plugin files ──────────────────────────────────────
if [[ -d "$INSTALL_DIR" ]]; then
  rm -rf "$INSTALL_DIR"
  echo "  ✔ Removed $INSTALL_DIR"
else
  echo "  · Plugin directory not found"
fi

echo ""
echo "✅ Uninstalled. Your env files in ~/.envs were left untouched."
echo "   Run 'source ~/.zshrc' to reload your shell."
echo ""
