# RoomScan (iPhone / iPad Pro)

Scans a room with Apple's RoomPlan (LiDAR) and sends it to a **roomscan** server
([`spatial/`](../../spatial/README.md)), where an LLM turns it into an IFC model.

- **Scan:** Apple's own RoomPlan scanning UI, with its coaching and the processed 3D result.
- **Live:** while you scan, the room as RoomPlan currently understands it goes to the server every
  2 seconds (newest only, never queued up). An LLM watching the server sees walls, doors and
  furniture appear and can tell you what's missing. Turn it off in Settings to send only the end result.
- **Final:** the processed room is saved on the phone (RoomPlan JSON plus a USDZ 3D model, both in
  the Files app under RoomScan) and replaces the live version on the server.
- **Plan:** every saved scan has a report PDF, drawn on the phone with no server, organised the way
  an organizer works, by spot: the floor plan with every spot numbered (walls with lengths, doors,
  windows, furniture, floor area, ceiling height); then a page per spot (each storage unit, and
  anything named, holding products or photographed) with its front and shelves, size and openings as
  estimates beside tape measurements, the products that go there and its photos; then a page per
  wall with its elevation, photos and products; then the product list, every measurement, and all
  the photos. Feet and inches
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
  elevations can be redrawn (**More → Rebuild elevations**). A frame only paints a spot if no other
  wall stands in the way (doors, windows and openings excepted), and where storage or an appliance
  stands against the wall, its front face is used instead of the wall behind it. Tuned against a
  real two-space scan with a numpy copy of the method; with closet shelving that removed most of the
  smearing.
- **Whole homes:** after a room is saved, **Scan next room** names the next one and carries on without
  stopping the camera (RoomPlan's multi-room support, iOS 17), so every room of the session comes out
  in one coordinate system. Each is an ordinary scan with its own plan, elevations, photos and
  products; the home list gets a **Home plan**: every room in place on one page, with names and
  floor areas, and **Home 3D**: the dollhouse of every room together. Walk between rooms with the phone up; covering the camera or a long pause can lose
  tracking.
- **Photo-real 3D:** RoomPlan's boxes and flat walls can't look real: anything with depth smears
  across what's behind it. The app keeps ARKit's LiDAR mesh (the room's real surface shape) when the
  session has one, and after a room is saved, **Photo-real pass** keeps the camera going in ARKit's
  mesh mode, drawing the mesh over the camera as it builds, while frames are kept as before.
  Starting ARKit's mesh mode moves the world origin (3.5 m on the first try), so the phone's pose
  just before and after the switch moves everything back, and the mesh is then fitted onto
  RoomPlan's walls and floor (a few cm). Each triangle is painted from the frame that sees it most
  head-on and close among frames where it's the nearest surface (a quarter-size depth buffer per
  frame: 95% painted on a real scan), wound to face that frame and drawn one-sided, so walls
  between you and the room vanish from outside. The ceiling is hidden in the dollhouse view, and
  scraps beyond the room are trimmed. **Walk** stands you in the room at eye height: one finger
  looks around, two fingers walk and side-step, pinch steps forward. Measuring lands on the real
  surfaces. Each scan's info.json records
  `roomPlanMeshTriangles`: whether RoomPlan's own session builds a mesh at all.
- **Dollhouse:** a scan's **3D** button shows it as a model to turn and zoom: walls wearing their
  elevation photos, the floor, furniture as see-through boxes tagged with their spot names, and photo
  pins. Walls are one-sided, facing the room, so whichever walls stand between you and the room are
  see-through from behind and you look in. Tap a box for its products, a pin for its photo. **Share
  3D** exports it as USDZ, which any iPhone, iPad or Mac opens, in AR too.
- **Coverage while scanning:** a map in the corner, turned so the way the phone points is up, colours
  each wall red to green by how much of it the kept frames have seen (30 cm cells, seen from the
  room side, fairly head-on, within 5 m: what the elevations need), with an overall percentage and a
  hint like *Point at the red wall to your left (62%)*. **Done** asks first if a wall is under 70%:
  on the first real scan, walls around 70% already had clear gray gaps.
- **Frame checks and the floor:** nearly black frames (a covered lens) are left out, and so is any
  edge band with a fingertip in it (more than 8% skin-coloured), thresholds from the first two real
  scans, where a fingertip crept into the bottom of several frames. The same frames also make a floor image from above (transparent outside the floor,
  neutral under furniture), which the dollhouse lays on its floor.
- **Coloring in:** while scanning, the parts of the walls no kept frame has photographed yet show in
  black and white over the live camera, and colour in as frames cover them (about 15 times a second:
  the uncovered 30 cm cells from the coverage, projected onto the screen as a mask over a grayscale
  copy of the camera frame). The half-circle button on the scan screen turns it off.
- **Shelves:** RoomPlan gives a storage unit as one box. The elevation pass also projects the frames onto
  each storage unit's front face, to scale, where every shelf edge is a horizontal line at its true
  height; rows where brightness jumps across a quarter of the width or more, 8 cm apart, are taken as
  shelf edges. The PDF gets a page per unit: the front with the shelves drawn, width, depth, height and
  each opening's clear height to the nearest half inch, each with a blank to write the tape
  measurement in. They're estimates (about ±1"), and say so. Tapping the unit in the dollhouse shows
  the openings too. Tried on a real closet scan's frames first.
- **Your own measurements:** in the dollhouse, **Measure** then tap two points on a wall, the floor or a
  unit: the distance is drawn and can be saved with a name (walls carry to-scale photos, so this
  works on things in them, like trim or a gap). **Measurements** (in the dollhouse, or **More →
  Measurements…**) lists every estimate (walls, each unit's width, depth and height, every shelf
  opening) and every 3D measurement, each with a field for the tape measurement (15¼, 15 1/4,
  1' 3¼"). Tape measurements replace the estimates in the PDF, marked ✓, and fill the shelf pages'
  Measured column.
- **Sending a scan:** **More → Share scan bundle** zips the scan's folder (scan, photos, frames,
  elevations, PDF, products, names) to send on, e.g. into a Claude chat to look at what went wrong.
- **Spot names:** **More → Name spots…** lists every object and wall as labelled on the plan
  (*3 Storage*, *Wall W2*); give the ones that matter a name (*Coffee station*). Names show on the
  plan, elevations, photo captions and products page (*3 Coffee station*), and in the calculator's
  Location column (*Pantry · Coffee station*). Products keep the plan label underneath, so renaming
  a spot later carries through.
- **Products:** each scan's **Products** button lists the organizing products used in the room by
  location, using the plan's own labels (*3 Storage*, *Wall W2*, or the whole room), picked from a
  catalog imported once from a CSV export of the product calculator's product tab (a column headed
  *Product*; *Unit Price* and *Store* are read too). The catalog stays on the phone. **Copy rows for
  the calculator** puts tab-separated rows on the clipboard shaped for the calculator's *Client
  Product List*: Location, Product, an empty Price (the sheet's formula fills it) and Qty in Home, so
  they paste in at the Location column. **Share as CSV** gives the same with unit prices and stores.
  The plan PDF gets a *products by location* page.
- **Products from a store link:** in *Add product*, paste a product link (Safari, or the Target,
  Amazon or Container Store app: Share → Copy). The app opens it in a hidden browser on the phone, so
  the page's own scripts run (Target fills its price in that way) and bot checks see a real phone,
  then reads the name, price, photo and dimensions. Edit the name to the master list's style, and it
  joins the catalog marked new; **Copy new products for the master list** puts them on the clipboard
  as Product, Unit Price, Store, URL rows for the calculator's product tab, so its price lookups work.
  Whether each store lets a hidden browser read its pages is only known on a phone: from a cloud
  server Container Store shows a robot check and Target a "Sorry for the wait" page.
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
   New App. Platform iOS, name *RoomScan* (any unused name), bundle ID `dev.ai.roomscan`
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
Pick your team under Signing & Capabilities (change the bundle id if `dev.ai.roomscan` is
taken), plug in the phone, Run.

## Notes

- The server address can be plain `http://` (a LAN IP, or a Tailscale name or IP): the app allows
  it, since the server is yours and the token guards it.
- The token is kept in the Keychain; the address in the app's settings.
- What's sent is `JSONEncoder` output of RoomPlan's `CapturedRoom`, exactly what the server's
  reader expects. Multi-room scans (`CapturedStructure`) aren't captured by this app yet; the
  server already reads them.
- Cancelling a live scan leaves its last live snapshot on the server (stage `live`).
