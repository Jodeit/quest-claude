#!/usr/bin/env bash
# Download an APK from the latest successful CI run and install it on the headset.
# Usage: scripts/install.sh [--cwaude] [run-id]
#   default   Quest Claude (dev.questclaude), which drives Claude in Termux
#   --cwaude  Cwaude (dev.cwaude), which runs its own Ubuntu: no Termux needed
set -euo pipefail
cd "$(dirname "$0")/.."

artifact=quest-claude-apk apk=quest-claude.apk pkg=dev.questclaude
if [ "${1:-}" = "--cwaude" ]; then
  artifact=cwaude-apk apk=cwaude.apk pkg=dev.cwaude
  shift
fi

run="${1:-}"
if [ -z "$run" ]; then
  run=$(gh run list --workflow build.yml --branch main --status success --limit 1 \
        --json databaseId --jq '.[0].databaseId')
fi
[ -n "$run" ] || { echo "No successful run found"; exit 1; }

rm -rf dist && mkdir -p dist
echo "Downloading $artifact from run $run…"
gh run download "$run" --name "$artifact" --dir dist

echo "Installing on ${ANDROID_SERIAL:-default device}…"
adb install -r -g "dist/$apk"
[ "$pkg" = dev.questclaude ] &&
  { adb shell pm grant dev.questclaude com.termux.permission.RUN_COMMAND 2>/dev/null || true; }
# Lets the app turn Wireless debugging back on after reboots (replaces Shizuku).
adb shell pm grant "$pkg" android.permission.WRITE_SECURE_SETTINGS
adb shell am start -n "$pkg/.MainActivity"
