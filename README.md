# Quest Claude

A lightweight Android companion app for Meta Quest that drives
[Claude Code](https://claude.com/claude-code) running in Termux.

Open Quest Claude and it starts everything: Wireless debugging, adb on 5555 (`quest up`), tmux in
Termux, and Claude in a detached tmux session. A live copy of the Claude pane appears in the app, so you never need to open the Termux window. Termux needs one setting, once:
`allow-external-apps=true` in `~/.termux/termux.properties`.

- **Terminal**: the Claude tmux pane, in color, refreshed about once a second (right away after
  you type). Tap it (or ⌨) and type: keys go straight to Claude, like a terminal. With a
  Bluetooth keyboard, Enter sends, Shift+Enter starts a new line, and Ctrl/Alt combos work.
- **Voice dictation**: on-device [whisper.cpp](https://github.com/ggml-org/whisper.cpp) (`base.en`).
  Tap Dictate, talk, tap Stop; the text is pasted into Claude's prompt (no Enter). Quest has no speech recognizer
  that other apps can use, so it's built in. The first tap downloads the model (57 MB) once.
- **Key bar**: Esc, Ctrl-C, Tab, Shift-Tab, arrows, Enter.
- **Status**: Termux installed, RUN_COMMAND permission, USB debugging, and whether adb is listening on `127.0.0.1:5555`.
- **Reconnect**: turns Wireless debugging back on (Android switches it off at every boot), then runs
  `quest up` in Ubuntu, which finds its port, reopens adb on 5555 and turns keep-awake back on.
  Tapping the status bar while 5555 is closed does the same. The app also re-enables Wireless
  debugging at boot and whenever it opens, so Shizuku isn't needed.
- **Remote**: starts `claude remote-control` in its own tmux session (`claude-rc`), so you can drive
  the headset's Claude from claude.ai or the Claude app on another device.

## adb without Shizuku

`quest` uses Ubuntu's own adb against the headset's Wireless debugging. Once per headset:

1. Settings > Developer > turn on **Wireless debugging**, then **Pair device with pairing code**.
2. Keep that dialog open and, in Ubuntu, run `quest pair <port> <code>` with the port and code it shows.
3. `scripts/install.sh` grants the app `WRITE_SECURE_SETTINGS` so it can turn Wireless debugging
   back on after reboots.

After a reboot, open Quest Claude and tap **Reconnect** (or run `quest up`).

## How it works

The app never talks to Claude directly. It sends Termux
[`RUN_COMMAND`](https://github.com/termux/termux-app/wiki/RUN_COMMAND-Intent) intents that run
`tmux` commands against a session (default `claude`). **Open Claude** starts or re-attaches the
session in a Termux window, running (by default):

```
proot-distro login ubuntu -- bash -lc 'cd ~ && claude'
```

Both the session name and the command can be changed in ⚙ Settings.

## One-time Termux setup

```sh
pkg install tmux
echo "allow-external-apps=true" >> ~/.termux/termux.properties
termux-reload-settings
```

## Headset control: `quest` and the skill

Inside proot Ubuntu, from a clone of this repo:

```sh
scripts/setup.sh
```

That puts `quest` on the PATH and links `skills/quest` into `~/.claude/skills/`, so every Claude
session on the headset knows to run `quest up` first and how to take screenshots, open pages,
launch apps and send input. Run `quest help` for the full command list.

## Build & install

There are no Android build tools on arm64 Termux/proot, so GitHub Actions builds the APK on every
push to `main` (tags `v*` also get a GitHub release). From the headset:

```sh
scripts/install.sh          # latest successful main build
scripts/install.sh <run-id> # a specific run
```

That downloads the artifact with `gh`, then `adb install -r -g` and grants the Termux permission.

`debug.keystore` is a throwaway debug key committed on purpose, so every CI build installs over the
previous one. Don't use it for anything you publish.
