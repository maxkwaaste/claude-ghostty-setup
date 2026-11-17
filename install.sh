#!/bin/bash
# install.sh: status line, `cc` alias, /handoff command and helper.
#   ./install.sh            install everything except the Ghostty config
#   ./install.sh --ghostty  also install the Ghostty config (backs up yours)
set -euo pipefail
cd "$(dirname "$0")"
REPO="$PWD"
STAMP=$(date +%Y%m%d-%H%M%S)

backup() { [ -e "$1" ] && cp "$1" "$1.bak-$STAMP" && echo "  backed up $1 -> $1.bak-$STAMP"; return 0; }

[ "$(uname)" = Darwin ] || echo "warning: /handoff uses Ghostty's AppleScript, so it only works on macOS."
command -v claude >/dev/null || { echo "Claude Code not found: npm install -g @anthropic-ai/claude-code"; exit 1; }
command -v node   >/dev/null || { echo "node is required"; exit 1; }

echo "1/5 status line (ccstatusline)"
command -v ccstatusline >/dev/null || npm install -g ccstatusline
mkdir -p ~/.config/ccstatusline
backup ~/.config/ccstatusline/settings.json
cp statusline/ccstatusline-settings.json ~/.config/ccstatusline/settings.json

echo "2/5 Claude settings (statusLine + skip the bypass-mode warning)"
mkdir -p ~/.claude
[ -f ~/.claude/settings.json ] || echo '{}' > ~/.claude/settings.json
backup ~/.claude/settings.json
node -e '
const fs=require("fs"), p=process.argv[1], s=JSON.parse(fs.readFileSync(p,"utf8"));
Object.assign(s, JSON.parse(fs.readFileSync(process.argv[2],"utf8")));
fs.writeFileSync(p, JSON.stringify(s,null,2)+"\n");' ~/.claude/settings.json claude/settings.snippet.json

echo "3/5 /handoff command and helper"
mkdir -p ~/.claude/commands ~/.claude/helpers
cp commands/handoff.md ~/.claude/commands/handoff.md
cp helpers/handoff-tab.sh ~/.claude/helpers/handoff-tab.sh
chmod +x ~/.claude/helpers/handoff-tab.sh

echo "4/5 cc alias"
mkdir -p ~/.config/claude-ghostty-setup
cp shell/claude-aliases.zsh ~/.config/claude-ghostty-setup/claude-aliases.zsh
LINE='source ~/.config/claude-ghostty-setup/claude-aliases.zsh'
grep -qxF "$LINE" ~/.zshrc 2>/dev/null || printf '\n# claude-ghostty-setup\n%s\n' "$LINE" >> ~/.zshrc

echo "5/5 Ghostty config"
if [ "${1:-}" = "--ghostty" ]; then
  mkdir -p ~/.config/ghostty
  backup ~/.config/ghostty/config
  cp ghostty/config ~/.config/ghostty/config
else
  echo "  skipped (run with --ghostty to install it)"
fi

echo
echo "Done. Open a new Ghostty window and type: cc"
echo "Inside Claude, type /handoff when you want to continue in a fresh session."
