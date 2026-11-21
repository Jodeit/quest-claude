#!/usr/bin/env bash
# Download the APK from the latest successful CI run and install it on the headset.
# Usage: scripts/install.sh [run-id]
set -euo pipefail
cd "$(dirname "$0")/.."

run="${1:-}"
if [ -z "$run" ]; then
  run=$(gh run list --workflow build.yml --branch main --status success --limit 1 \
        --json databaseId --jq '.[0].databaseId')
fi
[ -n "$run" ] || { echo "No successful run found"; exit 1; }

rm -rf dist && mkdir -p dist
echo "Downloading run $run…"
gh run download "$run" --name quest-claude-apk --dir dist

echo "Installing on ${ANDROID_SERIAL:-default device}…"
adb install -r -g dist/quest-claude.apk
adb shell pm grant dev.questclaude com.termux.permission.RUN_COMMAND 2>/dev/null || true
# Lets the app turn Wireless debugging back on after reboots (replaces Shizuku).
adb shell pm grant dev.questclaude android.permission.WRITE_SECURE_SETTINGS
adb shell am start -n dev.questclaude/.MainActivity
