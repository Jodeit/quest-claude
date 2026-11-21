#!/usr/bin/env bash
# One-time setup inside proot Ubuntu on the headset. Safe to re-run.
#   - puts `quest` on PATH
#   - installs the `quest` skill for every Claude session (~/.claude/skills/quest)
#   - sets ANDROID_SERIAL and puts ~/.local/bin (claude) on PATH for login shells
set -euo pipefail
repo="$(cd "$(dirname "$0")/.." && pwd)"

if [ -x "$repo/scripts/quest" ]; then
  mkdir -p /usr/local/bin
  ln -sf "$repo/scripts/quest" /usr/local/bin/quest
  echo "quest -> /usr/local/bin/quest"
else
  echo "warning: $repo/scripts/quest is missing; commit it from the headset" >&2
fi

mkdir -p "$HOME/.claude/skills"
ln -sfn "$repo/skills/quest" "$HOME/.claude/skills/quest"
echo "skill -> ~/.claude/skills/quest"

# Login shells too: the app starts claude with `bash -lc`, and Ubuntu's .bashrc stops early
# in non-interactive shells, so ~/.local/bin (where claude lives) must be on PATH in ~/.profile.
for rc in "$HOME/.bashrc" "$HOME/.profile"; do
  grep -q 'ANDROID_SERIAL=127.0.0.1:5555' "$rc" 2>/dev/null ||
    echo 'export ANDROID_SERIAL=127.0.0.1:5555' >> "$rc"
done
grep -q 'quest-claude: PATH' "$HOME/.profile" 2>/dev/null ||
  printf '%s\n' '# quest-claude: PATH for claude in login shells' \
    'case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) PATH="$HOME/.local/bin:$PATH" ;; esac' \
    >> "$HOME/.profile"

command -v python3 >/dev/null && python3 -c 'import PIL' 2>/dev/null ||
  echo "tip: apt install -y python3-pil (quest shot uses it to crop/resize)"
echo "done"
