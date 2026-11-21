---
name: quest
description: Drive the Meta Quest headset this session runs on — reconnect adb, take and look at screenshots, open URLs, launch apps, tap/type/swipe on 2D panels, read logs, install APKs. Use whenever the user asks to see, open, test, or control something on the headset, or when adb says "device not found" or "connection refused".
---

# Driving the headset

You are running inside Termux → proot Ubuntu **on the Quest itself**. The headset reaches its own
adb at `127.0.0.1:5555` (`ANDROID_SERIAL` is set in `~/.bashrc`). The `quest` command wraps adb.

## Always start with `quest up`

Port 5555 closes on every reboot, Wi-Fi change, and sometimes on sleep. `quest up`:
1. checks 5555; if closed, scans localhost for the Shizuku/Wireless debugging port (~15 s),
   connects to it and runs `adb tcpip 5555`;
2. reconnects to 5555;
3. re-applies keep-awake (proximity override + stay-on while plugged in).

If `quest up` can't find a port, Shizuku / Wireless debugging is off. Ask the user to open
**Shizuku → Start** (it's already paired), then retry. Don't ask them to type ports.

## Commands

Run `quest help` for exact usage. The main ones:

| Command | Does |
| --- | --- |
| `quest up` | reconnect adb + keep-awake (run first) |
| `quest status` | adb, battery, wakefulness |
| `quest shot` | screenshot → prints a path under `~/quest-shots/`; then **Read that file** to see it |
| `quest focus` | which app/window has focus |
| `quest open <url>` | open a URL in the Quest Browser |
| `quest apps` / `quest launch <pkg>` | list / start apps |
| `quest tap x y`, `quest swipe …`, `quest key back\|home\|enter`, `quest type "text"` | input on 2D panels |
| `quest sleep` | undo keep-awake |

Plain adb also works: `adb logcat -d -t 300`, `adb install -r app.apk`, `adb shell …`.

## Things to know

- **See before you act.** After opening or tapping something, wait 2–5 s, then `quest shot` and
  read the image. To find tap targets, `adb shell uiautomator dump /data/local/tmp/ui.xml` and read
  the `bounds` of the node you want.
- **Each 2D app runs on its own virtual display.** Taps reach 2D panels (browser, settings, panel
  apps) but can't simulate controller pointing in immersive 3D apps.
- **If the headset is lying on a desk,** panels may be out of view in screenshots. Try recentering:
  `adb shell am broadcast -a horizonos.appactions.RECENTER_VIEW -n com.oculus.vrshell/.AssistantBroadcastReceiver`
  (untested — check with a screenshot).
- **System dialogs** like "X isn't responding" block input. Dump the UI, find "Wait" or
  "Close app", tap it.
- **Termux wake lock** can't be set from adb. If the session keeps getting suspended, ask the user
  to tap *Acquire wakelock* in the Termux notification.
- **Building APKs:** there are no Android build tools on arm64. Push to GitHub, let Actions build,
  then `scripts/install.sh` in the quest-claude repo downloads and installs the APK.
