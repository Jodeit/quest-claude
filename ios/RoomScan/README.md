# RoomScan (iPhone / iPad Pro)

Scans a room with Apple's RoomPlan (LiDAR) and sends it to a **roomscan** server
([`spatial/`](../../spatial/README.md)), where an LLM turns it into an IFC model.

- **Scan:** Apple's own RoomPlan scanning UI, with its coaching and the processed 3D result.
- **Live:** while you scan, the room as RoomPlan currently understands it goes to the server every
  2 seconds (newest only, never queued up). An LLM watching the server sees walls, doors and
  furniture appear and can tell you what's missing. Turn it off in Settings to send only the end result.
- **Final:** the processed room is saved on the phone (RoomPlan JSON plus a USDZ 3D model, both in
  the Files app under RoomScan) and replaces the live version on the server.
- **Plan:** every saved scan has a dimensioned floor plan PDF, drawn on the phone with no server:
  the room to scale with each wall's length, doors and windows, furniture footprints, floor area and
  ceiling height, then a list of every measurement (window sill heights included). Feet and inches
  when the phone's region is the US. Tap **Plan** to preview it; its share button mails or AirDrops it.
- **Photos:** the **Photo** button on the scan screen takes a picture from the scanning camera without
  stopping the scan. Each one keeps where the phone stood and which way it faced, so the plan shows it
  as a numbered pin with a wedge in that direction, names what it faced (the nearest object straight
  ahead, else the wall), and adds photo pages. Photos stay on the phone (`photos/` in the scan's
  folder) and in the PDF; they aren't sent to the server. Pause for a moment when you take one: the
  frame is the scanning camera's (about 1920×1440), so movement blurs it.
  **Camera Control** (iPhone 16) and the volume buttons are meant to work as the shutter too; iOS may
  only deliver those presses to apps that run their own camera, and RoomPlan runs it for us, so this
  is unconfirmed on a device.
- **Wall elevations:** while you scan, the app quietly keeps up to 150 frames (960×720), whenever the
  phone is held fairly still and has moved 30 cm or turned 15° since the last one. After the scan it
  projects the best of them onto each wall, giving a straight-on, to-scale photo of every wall seen
  from inside the room. The PDF gets a page per wall with its width and height and the doors, windows
  and objects on or against it outlined, labelled as on the plan. Flat things on the wall are true to
  scale; anything standing out from it (cabinet fronts, furniture) is smeared a little, and parts no
  frame saw are gray. Frames are kept in the scan's `frames/` folder (10–20 MB a scan), so the
  elevations can be redrawn.
- **Offline:** with no server set, or if sending fails, scans stay on the phone; a row's **Send**
  button retries. **JSON** and **3D** share either file anywhere.

Needs iOS 17 and a LiDAR device: iPhone 12 Pro or newer Pro, or an iPad Pro.

## Setup

1. Start the server where it can stay up (the Quest headset, a Mac, a PC):
   ```bash
   roomscan serve --http 0.0.0.0:8765
   ```
   It prints its address and a bearer token.
2. In RoomScan, tap **Set up the server**, enter `http://<that machine's IP>:8765` and the token,
   and tap **Test connection**. iOS asks once for local network access; allow it.
3. **New scan**, name the room, walk it slowly with the phone pointed at the walls, tap **Done**.

On the server side, the scan shows up in `list_scans` with `stage: "live"` while scanning, then
`"final"`.

## Installing it

There's no App Store build. Three ways on:

**TestFlight, no computer at all** (needs the paid Apple Developer Program, $99 a year). CI signs
the app with your account and uploads every build; the TestFlight app installs it. Builds last 90
days and update by themselves. Everything below works from the iPhone:

1. **Join the Developer Program**: the *Apple Developer* app → Account → Enroll. Approval can
   take a day or two.
2. **Make the app record**: [App Store Connect](https://appstoreconnect.apple.com) → Apps → **+** →
   New App. Platform iOS, name *RoomScan* (any unused name), bundle ID `dev.qlaude.roomscan`
   (register it at developer.apple.com → Identifiers → **+** → App IDs if it isn't offered),
   SKU anything.
3. **Make an API key**: App Store Connect → Users and Access → Integrations → App Store Connect API
   → Team Keys → **+**, access **Admin** (Xcode's cloud signing needs it to make the certificate).
   Note the **Key ID** and the **Issuer ID** above the list, and download the `.p8` file (one chance;
   it lands in Files). Your **Team ID** is at developer.apple.com → Account → Membership details.
4. **Give them to GitHub**: in Safari (request the desktop site), the repo → Settings → Secrets and
   variables → Actions → New repository secret, four times:
   `APPLE_TEAM_ID`, `ASC_KEY_ID`, `ASC_ISSUER_ID`, and `ASC_KEY_P8` (the whole `.p8` file's text,
   including the BEGIN/END lines; open it in Files, select all, copy).
5. **Build**: Actions → *RoomScan iOS* → Run workflow (or push anything under `ios/`). The
   *testflight* job uploads; Apple takes 5–30 minutes to process it.
6. **Install**: App Store Connect → your app → TestFlight → Internal Testing → **+** group, add
   yourself. Install the **TestFlight** app, accept the invite, tap Install.

Internal testers (up to 100 people on your account's team) don't need Apple's beta review. If a
build is held for *Missing Compliance*, it's already answered in the app (standard encryption only);
re-run, or answer "None" in App Store Connect.

**Sideload, with a PC or Mac for the first install.** Every push that touches `ios/` builds an unsigned
`RoomScan-unsigned.ipa` (Actions → *RoomScan iOS* → artifacts). Sideload it with
[Sideloadly](https://sideloadly.io) or AltStore, which re-sign it with your Apple ID. With a free
Apple ID it runs for 7 days, then needs re-signing; a paid developer account gives a year.

**From a Mac with Xcode.**
```bash
brew install xcodegen
cd ios/RoomScan && xcodegen && open RoomScan.xcodeproj
```
Pick your team under Signing & Capabilities (change the bundle id if `dev.qlaude.roomscan` is
taken), plug in the phone, Run.

## Notes

- The server address can be plain `http://` (a LAN IP, or a Tailscale name or IP): the app allows
  it, since the server is yours and the token guards it.
- The token is kept in the Keychain; the address in the app's settings.
- What's sent is `JSONEncoder` output of RoomPlan's `CapturedRoom`, exactly what the server's
  reader expects. Multi-room scans (`CapturedStructure`) aren't captured by this app yet; the
  server already reads them.
- Cancelling a live scan leaves its last live snapshot on the server (stage `live`).
