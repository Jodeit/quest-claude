#!/usr/bin/env bash
# One-time setup inside proot Ubuntu on the headset. Safe to re-run.
#   - puts `quest` on PATH
#   - installs the `quest` skill for every Claude session (~/.claude/skills/quest)
#   - makes sure ANDROID_SERIAL is set
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

grep -q 'ANDROID_SERIAL=127.0.0.1:5555' "$HOME/.bashrc" 2>/dev/null ||
  echo 'export ANDROID_SERIAL=127.0.0.1:5555' >> "$HOME/.bashrc"

command -v python3 >/dev/null && python3 -c 'import PIL' 2>/dev/null ||
  echo "tip: apt install -y python3-pil (quest shot uses it to crop/resize)"
echo "done"
