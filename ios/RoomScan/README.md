# RoomScan (iPhone / iPad Pro)

Scans a room with Apple's RoomPlan (LiDAR) and sends it to a **roomscan** server
([`spatial/`](../../spatial/README.md)), where an LLM turns it into an IFC model.

- **Scan:** Apple's own RoomPlan scanning UI, with its coaching and the processed 3D result.
- **Live:** while you scan, the room as RoomPlan currently understands it goes to the server every
  2 seconds (newest only, never queued up). An LLM watching the server sees walls, doors and
  furniture appear and can tell you what's missing. Turn it off in Settings to send only the end result.
- **Final:** the processed room is saved on the phone (RoomPlan JSON plus a USDZ 3D model, both in
  the Files app under RoomScan) and replaces the live version on the server.
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

There's no App Store build. Two ways on:

**From CI, no Mac needed.** Every push that touches `ios/` builds an unsigned
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
