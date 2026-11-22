#!/usr/bin/env bash
# Download an APK from the latest successful CI run and install it on the headset.
# Usage: scripts/install.sh [--qlaude|--cwaude] [--force] [run-id]
#   default   Quest Claude (dev.questclaude), which drives Claude in Termux
#   --qlaude  Qlaude (formerly Cwaude; package dev.cwaude), which runs its own Ubuntu: no Termux
#             needed. --cwaude still works.
#   --force   install Qlaude even while other tabs' Claudes are mid-reply. Updating Qlaude kills
#             every tab; they come back resumed, but a reply in progress is cut off.
set -euo pipefail
cd "$(dirname "$0")/.."

artifact=quest-claude-apk apk=quest-claude.apk pkg=dev.questclaude
force= run=
for a in "$@"; do
  case "$a" in
    --qlaude|--cwaude) artifact=cwaude-apk apk=cwaude.apk pkg=dev.cwaude ;;
    -f|--force) force=1 ;;
    *) run="$a" ;;
  esac
done

# Claudes that are working right now, other than the one running this script: one line each,
# "tab (session name)". Each live Claude keeps ~/.claude/sessions/<pid>.json with its status.
busy_claudes() {
  local mine=" " p=$$ f pid
  while [ "${p:-0}" -gt 1 ]; do  # this script's ancestors, so our own Claude doesn't count
    mine+="$p "
    # ppid is the 2nd field after the ")" ending the command name (which may hold spaces).
    p=$(sed 's/.*) [^ ]* \([0-9]*\).*/\1/' "/proc/$p/stat" 2>/dev/null) || break
  done
  for f in "$HOME"/.claude/sessions/*.json; do
    [ -e "$f" ] || continue
    pid=$(basename "$f" .json)
    [ -d "/proc/$pid" ] || continue          # left behind by a Claude that was killed
    case "$mine" in *" $pid "*) continue ;; esac
    grep -q '"status":"busy"' "$f" || continue
    tab=$(sed -n 's/.*"tmux":"\([^:"]*\).*/\1/p' "$f")
    name=$(sed -n 's/.*"name":"\([^"]*\)".*/\1/p' "$f")
    echo "  ${tab:-?} (${name:-pid $pid})"
  done
}

if [ "$pkg" = dev.cwaude ] && [ -z "$force" ]; then
  busy=$(busy_claudes)
  if [ -n "$busy" ]; then
    echo "These tabs are mid-reply, and updating Qlaude kills every tab:"
    echo "$busy"
    echo "They reopen resumed afterwards, but these replies would be cut off."
    if [ -t 0 ]; then
      read -rp "Install anyway? [y/N] " ok
      case "$ok" in [yY]*) ;; *) echo "Not installed."; exit 1 ;; esac
    else
      echo "Not installed. Wait for them to finish, or pass --force to install anyway."
      exit 3
    fi
  fi
fi

if [ -z "$run" ]; then
  run=$(gh run list --workflow build.yml --branch main --status success --limit 1 \
        --json databaseId --jq '.[0].databaseId')
fi
[ -n "$run" ] || { echo "No successful run found"; exit 1; }

rm -rf dist && mkdir -p dist
echo "Downloading $artifact from run $run…"
gh run download "$run" --name "$artifact" --dir dist

echo "Installing on ${ANDROID_SERIAL:-default device}…"
if ! out=$(adb install -r -g "dist/$apk" 2>&1); then
  echo "$out" >&2
  if grep -q UPDATE_INCOMPATIBLE <<<"$out"; then
    echo "The installed $pkg is signed with a different key (Qlaude builds moved from the shared" >&2
    echo "debug key to the private release key). Updating means uninstalling first, which deletes" >&2
    echo "its Ubuntu, files and Claude login:  adb uninstall $pkg && $0 $*" >&2
  fi
  exit 1
fi
echo "$out"
[ "$pkg" = dev.questclaude ] &&
  { adb shell pm grant dev.questclaude com.termux.permission.RUN_COMMAND 2>/dev/null || true; }
# Lets the app turn Wireless debugging back on after reboots (replaces Shizuku).
adb shell pm grant "$pkg" android.permission.WRITE_SECURE_SETTINGS
adb shell am start -n "$pkg/.MainActivity"
