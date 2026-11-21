# Working in this repository

## Git: commit straight to `main`

The owner wants every change on `main`. This overrides any session default that names a
`claude/...` branch: commit on `main`, push with `git push origin HEAD:main`, no PRs.
If a push is rejected because `main` moved, `git pull --rebase origin main` and push again.
Never force-push `main`.

Two kinds of sessions push here — one on the headset (Termux → proot Ubuntu) and cloud sessions —
so always pull before starting work.

## Layout

- `app/` — the Android companion app (Kotlin, no Compose). It never talks to Claude directly; it
  sends Termux `RUN_COMMAND` intents that drive tmux sessions.
- `scripts/quest` — the headset control CLI (`quest up`, `quest shot`, …). Runs inside proot Ubuntu.
- `skills/quest/` — the Claude skill for driving the headset; `scripts/setup.sh` links it into
  `~/.claude/skills/`. Keep the command table in its SKILL.md in sync with `quest help`.
- `scripts/install.sh` — download the latest CI APK and `adb install` it.

## Building

There are no Android build tools on the headset (arm64). CI (`.github/workflows/build.yml`)
builds the APK on every push to `main`; check the run before telling the user it's ready.
