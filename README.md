# Quest Claude

A lightweight Android companion app for Meta Quest that drives
[Claude Code](https://claude.com/claude-code) running in Termux.

- **Compose box**: big multiline input; sent via tmux bracketed paste so newlines don't submit early.
- **Voice dictation**: the system speech recognizer if there is one, otherwise the keyboard's mic.
- **Key bar**: Esc, Ctrl-C, Tab, Shift-Tab, arrows, Enter.
- **Status**: Termux installed, RUN_COMMAND permission, USB debugging, and whether adb is listening on `127.0.0.1:5555`.

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
