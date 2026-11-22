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
- `cwaude/` — Qlaude, "A Quest Claude Code App" (formerly Cwaude; the package, module and class
  names are still `dev.cwaude`/`Cwaude*`, so updates install over the existing app and keep its
  Ubuntu and Claude login). The Termux-free successor: runs its own Ubuntu through proot
  (shipped as `lib*.so`, fetched by `scripts/fetch-ubuntu-prebuilts.sh`), keeps tmux alive in a
  foreground service, and talks to it over one `tmux -C` control-mode pipe (`Tmux.kt`). Its UI
  files (`Ansi`, `TapTargets`, `TerminalView`, `Dictation`) started as copies of `app/`'s; fix
  bugs in both until Quest Claude is retired. Whisper's C code is shared from `app/src/main/cpp`.
- `spatial/` — roomscan: RoomPlan (iPhone LiDAR) scans → IFC4 via IfcOpenShell, served over MCP
  (stdio or HTTP with a bearer token). Python; `scripts/roomscan` wraps it. Tests run in CI
  (`.github/workflows/spatial.yml`) and locally with pytest.
- `ios/RoomScan/` — the iPhone capture app for roomscan (SwiftUI + RoomPlan). XcodeGen
  `project.yml`; the .xcodeproj isn't checked in. CI (`.github/workflows/ios.yml`, macOS) is the
  only compiler we have: check it after Swift changes. It also builds an unsigned .ipa.
- `spike/` — the exec spike that proved Cwaude's approach; throwaway.
- `scripts/install.sh` — download the latest CI APK and `adb install` it (`--cwaude` for Cwaude).

## Building

There are no Android build tools on the headset (arm64). CI (`.github/workflows/build.yml`)
builds the APK on every push to `main`; check the run before telling the user it's ready.
