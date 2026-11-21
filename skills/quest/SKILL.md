---
name: quest
description: Drive the Meta Quest headset this session runs on — reconnect adb, take and look at screenshots, open URLs, launch apps, tap/type/swipe on 2D panels, read logs, install APKs. Use whenever the user asks to see, open, test, or control something on the headset, or when adb says "device not found" or "connection refused".
---

# Driving the headset

You are running inside Termux → proot Ubuntu **on the Quest itself**. The headset reaches its own
adb at `127.0.0.1:5555` (`ANDROID_SERIAL` is set in `~/.bashrc`). The `quest` command wraps adb.

## Always start with `quest up`

Port 5555 closes on every reboot, Wi-Fi change, and sometimes on sleep. `quest up`:
1. checks 5555; if closed, scans localhost for the Wireless debugging port (~15 s),
   connects to it and runs `adb tcpip 5555`;
2. reconnects to 5555;
3. re-applies keep-awake (proximity override + stay-on while plugged in).

If `quest up` can't find a port, Wireless debugging is off. The Quest Claude app turns it back on
at boot, when it opens, and on **Reconnect**, so ask the user to open Quest Claude and tap Reconnect.
Otherwise they can turn it on in Settings > Developer. Don't ask them to type ports. If adb says the
device is unauthorized, run the one-time pairing: `quest pair <port> <code>`, using the port and code from
Settings > Developer > Wireless debugging > Pair device with pairing code.

## Commands

Run `quest help` for exact usage. The main ones:

| Command | Does |
| --- | --- |
| `quest up` | reconnect adb + keep-awake (run first) |
| `quest pair <port> <code>` | one-time pairing with Wireless debugging |
| `quest status` | adb, battery, wakefulness |
| `quest read [match]` | text of a Quest Browser tab via DevTools (`-l` lists tabs, `-a` whole page) |
| `quest term [-n N]` | text of the Termux tmux pane Quest Claude drives (session `claude`) |
| `quest shot` | screenshot of what the wearer sees (passthrough + panels) → prints a path under `~/quest-shots/`; then **Read that file** to see it. `-f`/`-r` use raw screencap instead, which often comes back black |
| `quest focus` | which app/window has focus |
| `quest open <url>` | open a URL in the Quest Browser |
| `quest apps` / `quest launch <pkg>` | list / start apps |
| `quest tap x y`, `quest swipe …`, `quest key back\|home\|enter`, `quest type "text"` | input on 2D panels |
| `quest notifs [-f] [pkg]` | notifications' title and text (e.g. Termux RUN_COMMAND errors); `-f` follows new ones; run it with the Monitor tool to catch errors instead of asking the user to paste them |
| `quest sleep` | undo keep-awake |

Plain adb also works: `adb logcat -d -t 300`, `adb install -r app.apk`, `adb shell …`.

## Things to know

- **Read text before taking screenshots.** For a browser page use `quest read`; for the terminal use
  `quest term`. They're exact and cheaper than an image. Use `quest shot` for anything
  else: native panels, the passthrough room, layout, or when text isn't enough.
- **See before you act.** After opening or tapping something, wait 2–5 s, then check with
  `quest read` / `quest term` / `quest shot`. To find tap targets, `adb shell uiautomator dump /data/local/tmp/ui.xml` and read
  the `bounds` of the node you want.
- **Each 2D app runs on its own virtual display.** Taps reach 2D panels (browser, settings, panel
  apps) but can't simulate controller pointing in immersive 3D apps.
- **If the headset is lying on a desk,** panels may be out of view in screenshots. Try recentering:
  `adb shell am broadcast -a horizonos.appactions.RECENTER_VIEW -n com.oculus.vrshell/.AssistantBroadcastReceiver`
  (untested — check with a screenshot).
- **System dialogs** like "X isn't responding" block input. Dump the UI, find "Wait" or
  "Close app", tap it.
- **Termux wake lock** can't be set from adb, but Termux's own script works from inside proot:
  `PATH=/data/data/com.termux/files/usr/bin:$PATH sh /data/data/com.termux/files/usr/bin/termux-wake-lock`.
  Do it before long jobs (builds); verify with `adb shell dumpsys power | grep termux:service-wakelock`.
- **Building APKs:** there are no Android build tools on arm64. Push to GitHub, let Actions build,
  then `scripts/install.sh` in the quest-claude repo downloads and installs the APK.
