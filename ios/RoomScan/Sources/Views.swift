import QuickLook
import RoomPlan
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var settings: ServerSettings
    @EnvironmentObject private var library: ScanLibrary
    @State private var showSettings = false
    @State private var session: ScanSession?
    @State private var homePlan: URL?
    @State private var homeDollhouse: [SavedScan]?
    @State private var homeError: String?

    var body: some View {
        NavigationStack {
            List {
                if !RoomCaptureSession.isSupported {
                    Section {
                        Label("This device can't scan rooms. RoomPlan needs an iPhone Pro or iPad Pro with LiDAR.",
                              systemImage: "exclamationmark.triangle")
                    }
                }
                Section {
                    // One tap into the camera; the room is named on the scan screen, if at all.
                    Button(action: start) { ScanHero(first: library.scans.isEmpty) }
                        .buttonStyle(PressScale())
                        .disabled(!RoomCaptureSession.isSupported)
                        .listRowInsets(EdgeInsets())
                        .listRowBackground(Color.clear)
                }
                Section {
                    Button {
                        showSettings = true
                    } label: {
                        Label(settings.client == nil ? "Set up the server" : serverLabel,
                              systemImage: settings.client == nil ? "server.rack" : "checkmark.circle")
                    }
                }
                if !library.homes.isEmpty {
                    Section("Homes") {
                        ForEach(library.homes, id: \.first!.id) { rooms in
                            VStack(alignment: .leading, spacing: 6) {
                                Text(rooms.map(\.name).joined(separator: " · ")).font(.subheadline)
                                HStack(spacing: 20) {
                                    Button {
                                        do { homePlan = try library.homePlan(rooms) } catch {
                                            homeError = "Couldn't draw the home plan: \(error.localizedDescription)"
                                        }
                                    } label: { Label("Home plan", systemImage: "house") }
                                    Button {
                                        homeDollhouse = rooms
                                    } label: { Label("Home 3D", systemImage: "cube.transparent") }
                                }
                                .buttonStyle(.borderless)
                                .font(.caption)
                            }
                        }
                        if let homeError { Text(homeError).font(.caption).foregroundStyle(.red) }
                    }
                }
                Section("Scans") {
                    if library.scans.isEmpty {
                        Text("Nothing scanned yet.").foregroundStyle(.secondary)
                    }
                    ForEach(library.scans) { scan in
                        ScanRow(scan: scan)
                    }
                    .onDelete { offsets in
                        offsets.map { library.scans[$0] }.forEach(library.delete)
                    }
                }
            }
            .navigationTitle("RoomScan")
            .quickLookPreview($homePlan)
            .fullScreenCover(isPresented: Binding(get: { homeDollhouse != nil }, set: { if !$0 { homeDollhouse = nil } })) {
                if let rooms = homeDollhouse { DollhouseView(scans: rooms) }
            }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $session) { s in
                ScanScreen(session: s) { session = nil }
            }
        }
    }

    private var serverLabel: String {
        let host = settings.client?.base.host ?? ""
        return settings.liveUpdates ? "Live to \(host)" : "Sending to \(host)"
    }

    private func start() {
        // "Room 3": a placeholder the scan screen offers to replace (tap the name).
        let taken = Set(library.scans.map(\.name))
        var n = library.scans.count + 1
        while taken.contains("Room \(n)") { n += 1 }
        session = ScanSession(name: "Room \(n)", settings: settings, library: library)
    }
}

/// The home screen's way in: big, bright, and saying what happens next.
struct ScanHero: View {
    let first: Bool
    @Environment(\.isEnabled) private var enabled

    var body: some View {
        HStack(spacing: 16) {
            ZStack {
                Circle().fill(.white.opacity(0.22)).frame(width: 60, height: 60)
                Image(systemName: "viewfinder")
                    .font(.system(size: 28, weight: .semibold))
                    .symbolEffect(.pulse, isActive: enabled)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(first ? "Scan your first room" : "Scan a room").font(.title3.weight(.bold))
                Text("Walk round the edge with the phone up. A couple of minutes; it tells you where to point.")
                    .font(.subheadline)
                    .opacity(0.9)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Image(systemName: "chevron.right").font(.headline).opacity(0.8)
        }
        .foregroundStyle(.white)
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            LinearGradient(colors: enabled ? [Color(red: 0.16, green: 0.45, blue: 1), Color(red: 0.42, green: 0.25, blue: 0.95)]
                                           : [.gray, .gray.opacity(0.7)],
                           startPoint: .topLeading, endPoint: .bottomTrailing),
            in: RoundedRectangle(cornerRadius: 22, style: .continuous))
        .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(.isButton)
    }
}

struct ScanRow: View {
    @EnvironmentObject private var settings: ServerSettings
    @EnvironmentObject private var library: ScanLibrary
    let scan: SavedScan
    @State private var sending = false
    @State private var planPreview: URL?
    @State private var planError: String?
    @State private var showProducts = false
    @State private var showNames = false
    @State private var bundleURL: URL?
    @State private var makingTwin = false
    @State private var showDollhouse = false
    @State private var showMeasurements = false
    @State private var rebuilding = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(scan.name).font(.headline)
                Spacer()
                Text(scan.date.formatted(date: .abbreviated, time: .shortened))
                    .font(.caption).foregroundStyle(.secondary)
            }
            Text("\(scan.walls) walls · \(scan.doors) doors · \(scan.windows) windows · \(scan.objects) objects"
                 + (scan.photos.map { " · \($0) photo\($0 == 1 ? "" : "s")" } ?? "")
                 + (scan.meshTriangles != nil ? " · photo-real 3D" : ""))
                .font(.subheadline).foregroundStyle(.secondary)
            HStack(spacing: 16) {
                if scan.uploaded {
                    Label(scan.serverScanID ?? "", systemImage: "checkmark.icloud")
                        .font(.caption).foregroundStyle(.green).lineLimit(1)
                } else if settings.client != nil {
                    Button {
                        Task { await upload() }
                    } label: {
                        Label(sending ? "Sending…" : "Send", systemImage: "icloud.and.arrow.up")
                    }
                    .disabled(sending)
                }
                Spacer()
                Button {
                    do { planPreview = try library.plan(for: scan) } catch {
                        planError = "Couldn't draw the plan: \(error.localizedDescription)"
                    }
                } label: { Label("Plan", systemImage: "ruler") }
                Button {
                    showDollhouse = true
                } label: { Label("3D", systemImage: "cube.transparent") }
                Button {
                    showProducts = true
                } label: { Label("Products", systemImage: "shippingbox") }
                Menu {
                    Button {
                        showNames = true
                    } label: { Label("Name spots…", systemImage: "tag") }
                    Button {
                        showMeasurements = true
                    } label: { Label("Measurements…", systemImage: "ruler") }
                    Button {
                        do { bundleURL = try library.bundle(scan) } catch {
                            planError = "Couldn't zip the scan: \(error.localizedDescription)"
                        }
                    } label: { Label("Share scan bundle (.zip)", systemImage: "archivebox") }
                    Button {
                        makingTwin = true
                        let scan = scan, lib = library
                        Task {
                            let result: Result<URL, Error> = await Task.detached(priority: .userInitiated) {
                                Result { try TwinExport.make(scan, library: lib) }
                            }.value
                            makingTwin = false
                            switch result {
                            case let .success(url): bundleURL = url
                            case let .failure(error): planError = "Couldn't make the team twin: \(error.localizedDescription)"
                            }
                        }
                    } label: { Label(makingTwin ? "Making the team twin…" : "Share for team twin (.zip)", systemImage: "person.3") }
                    .disabled(makingTwin)
                    if library.hasFrames(scan) {
                        Button {
                            Task {
                                rebuilding = true
                                defer { rebuilding = false }
                                do { try await library.rebuildElevations(scan) } catch {
                                    planError = "Couldn't rebuild the elevations: \(error.localizedDescription)"
                                }
                            }
                        } label: { Label(rebuilding ? "Rebuilding elevations…" : "Rebuild elevations",
                                         systemImage: "square.3.layers.3d") }
                        .disabled(rebuilding)
                    }
                    ShareLink(item: library.jsonURL(scan)) { Label("Scan (RoomPlan JSON)", systemImage: "doc") }
                    if library.hasUSDZ(scan) {
                        ShareLink(item: library.usdzURL(scan)) { Label("3D model (USDZ)", systemImage: "cube") }
                    }
                } label: { Label("More", systemImage: "ellipsis.circle") }
            }
            .buttonStyle(.borderless)
            .font(.caption)
            if let err = scan.uploadError ?? planError {
                Text(err).font(.caption).foregroundStyle(.red)
            }
        }
        .padding(.vertical, 4)
        .quickLookPreview($planPreview)  // its share button sends the PDF on (Mail, AirDrop, Files)
        .sheet(isPresented: $showProducts) { ProductsView(scan: scan) }
        .sheet(isPresented: $showNames) { SpotNamesView(scan: scan) }
        .sheet(item: $bundleURL) { url in ShareSheet(items: [url]) }
        .fullScreenCover(isPresented: $showDollhouse) { DollhouseView(scans: [scan]) }
        .sheet(isPresented: $showMeasurements) { MeasurementsView(scan: scan) }
    }

    private func upload() async {
        guard let client = settings.client else { return }
        sending = true
        defer { sending = false }
        var s = scan
        do {
            let body = try library.json(for: scan)
            if let id = s.serverScanID {
                try await client.update(id, body, live: false)
            } else {
                s.serverScanID = try await client.create(body, name: s.name, live: false)
            }
            s.uploadError = nil
        } catch {
            s.uploadError = error.localizedDescription
        }
        library.update(s)
    }
}

struct ScanScreen: View {
    @ObservedObject var session: ScanSession
    let close: () -> Void
    @State private var flash = false
    @State private var confirmDone = false
    @State private var askNext = false
    @State private var askRename = false
    @State private var gray = true
    @State private var nextName = ""
    @State private var renameText = ""

    /// The camera is live: the RoomPlan scan, or the photo-real pass after it.
    private var live: Bool { session.phase == .scanning || session.meshPassRunning }

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureRepresentable(controller: session.controller)
                .ignoresSafeArea()
            Color.white.opacity(flash ? 0.6 : 0).ignoresSafeArea().allowsHitTesting(false)
                .onChange(of: session.photoCount) { flashOnce() }
            if live, let coverage = session.coverage {
                CoverageMap(snapshot: coverage)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            if session.meshPassRunning, let stop = session.stop {
                StopRing(progress: stop)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                    .allowsHitTesting(false)
                    .transition(.opacity)
            }
            VStack(spacing: 10) {
                if live, let tip {
                    HintCard(tip: tip)
                        .id(tip.text)
                        .transition(.asymmetric(insertion: .move(edge: .bottom).combined(with: .opacity), removal: .opacity))
                }
                panel
            }
            .animation(.snappy, value: tip?.text)
            .frame(maxWidth: 440)
            .padding()
        }
        .animation(.easeInOut(duration: 0.25), value: session.coverage == nil)
        // A tick each time RoomPlan finds something new: the scan answering back.
        .sensoryFeedback(.increase, trigger: session.counts) { old, new in new.total > old.total }
        .alert("Name the next room", isPresented: $askNext) {
            TextField("Kitchen", text: $nextName)
            Button("Scan") {
                let n = nextName.trimmingCharacters(in: .whitespaces)
                session.nextRoom(named: n.isEmpty ? "Room \(session.roomsSaved + 1)" : n)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Walk straight there with the phone up: keeping the camera going is what lets the rooms "
                 + "line up on the home plan.")
        }
        .alert("Name this room", isPresented: $askRename) {
            TextField("Living room", text: $renameText)
            Button("Save") { session.rename(to: renameText) }
            Button("Cancel", role: .cancel) {}
        }
    }

    private var panel: some View {
        VStack(spacing: 12) {
            header
            CountChips(counts: session.counts)
            if !session.serverStatus.isEmpty {
                Text(session.serverStatus).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            if session.phase.isDone, !session.meshPassRunning, !session.checklist.isEmpty {
                BeforeYouLeave(session: session)
            }
            if session.phase.isDone, !session.meshPassRunning, !session.previews.isEmpty {
                SpotPreviews(session: session)
            }
            controls
        }
        .padding(14)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 24, style: .continuous))
    }

    private var header: some View {
        HStack(spacing: 8) {
            StatusDot(phase: session.phase, meshPass: session.meshPassRunning)
            if session.phase == .scanning || session.phase == .processing {
                // Scans start with a made-up name; tap it to name the room.
                Button {
                    renameText = session.name.hasPrefix("Room ") ? "" : session.name
                    askRename = true
                } label: {
                    HStack(spacing: 6) {
                        Text(title).font(.headline).lineLimit(1)
                        Image(systemName: "pencil").font(.subheadline.weight(.semibold)).foregroundStyle(.secondary)
                    }
                }
                .buttonStyle(.plain)
                .accessibilityHint("Names the room")
            } else {
                Text(title).font(.headline).lineLimit(2)
            }
            Spacer(minLength: 8)
            if session.phase == .scanning {
                Text(session.startedAt, style: .timer)
                    .font(.subheadline.monospacedDigit().weight(.medium))
                    .foregroundStyle(.secondary)
            } else if session.phase == .processing {
                ProgressView()
            }
        }
    }

    @ViewBuilder private var controls: some View {
        switch session.phase {
        case .scanning:
            HStack(spacing: 12) {
                RoundIconButton(symbol: "xmark", label: "Cancel scan") {
                    session.cancel()
                    close()
                }
                RoundIconButton(symbol: gray ? "circle.lefthalf.filled" : "circle",
                                label: gray ? "Hide gray for unphotographed walls" : "Show gray for unphotographed walls") {
                    gray.toggle()
                    session.controller.showsGray = gray
                }
                Spacer(minLength: 0)
                ShutterButton(count: session.photoCount) { Task { await shoot() } }
                Spacer(minLength: 0)
                Button {
                    if (session.coverage?.weakWalls ?? 0) > 0 { confirmDone = true } else { session.finish() }
                } label: {
                    Label("Done", systemImage: "checkmark")
                        .font(.headline)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                }
                .buttonStyle(.borderedProminent)
                .buttonBorderShape(.capsule)
                .tint(.green)
                .confirmationDialog(doneQuestion, isPresented: $confirmDone, titleVisibility: .visible) {
                    Button("Keep scanning", role: .cancel) {}
                    Button("Finish anyway") { session.finish() }
                }
            }
        case .processing:
            Text("Hold on while RoomPlan tidies up the walls.").font(.caption).foregroundStyle(.secondary)
        case .done where session.meshPassRunning:
            Button {
                session.finishMeshPass()
            } label: {
                Label("Finish photo-real pass", systemImage: "checkmark").font(.headline).frame(maxWidth: .infinity)
                    .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .buttonBorderShape(.capsule)
            .tint(.green)
        case .done:
            HStack(spacing: 10) {
                Button("Close", action: close).buttonStyle(.bordered)
                Button {
                    session.startMeshPass()
                } label: { Label("Photo-real", systemImage: "cube.transparent") }
                    .buttonStyle(.bordered)
                Button {
                    nextName = ""
                    askNext = true
                } label: { Label("Next room", systemImage: "arrow.right") }
                    .buttonStyle(.borderedProminent)
            }
            .buttonBorderShape(.capsule)
            .font(.subheadline.weight(.semibold))
        default:
            Button("Close", action: close).buttonStyle(.borderedProminent).buttonBorderShape(.capsule)
        }
    }

    /// What to tell the person right now: the capture hint, else the coverage one, else a first step.
    private var tip: ScanTip? {
        guard live else { return nil }
        if let text = session.hint ?? session.coverage?.hint { return ScanTip(text) }
        if session.meshPassRunning {
            return ScanTip("Sweep slowly at chest height; go close to shelves and anything you'll want to measure.",
                           symbol: "cube.transparent", tint: .cyan)
        }
        if session.counts.walls == 0 {
            return ScanTip("Point at a wall and walk slowly round the edge of the room. Walls light up as they're found.",
                           symbol: "figure.walk", tint: .blue)
        }
        return nil
    }

    private func shoot() async { _ = await session.takePhoto() }

    /// A flash on every photo, whether from the button, Camera Control or a volume button.
    private func flashOnce() {
        flash = true
        withAnimation(.easeOut(duration: 0.3)) { flash = false }
    }

    private var doneQuestion: String {
        let n = session.coverage?.weakWalls ?? 0
        return "\(n) wall\(n == 1 ? " is" : "s are") under 70% photographed (red or orange on the map), so "
            + "\(n == 1 ? "its" : "their") elevation\(n == 1 ? "" : "s") will have gray gaps."
    }

    private var title: String {
        switch session.phase {
        case .scanning: return session.meshPassRunning ? "Photo-real pass" : session.name
        case .processing: return "Processing \(session.name)…"
        case .done: return session.meshPassRunning ? "Photo-real pass" : "Saved \(session.name)"
        case let .failed(message): return message
        case .cancelled: return "Cancelled"
        }
    }
}

/// One line of guidance with an icon that says what kind it is: warnings in orange and pulsing,
/// progress in green, a direction in blue.
struct ScanTip: Equatable {
    var text: String
    var symbol: String
    var tint: Color
    var urgent = false

    init(_ text: String, symbol: String, tint: Color, urgent: Bool = false) {
        self.text = text
        self.symbol = symbol
        self.tint = tint
        self.urgent = urgent
    }

    /// From the wording of CaptureHints' and Coverage's messages.
    init(_ text: String) {
        func has(_ s: String) -> Bool { text.localizedCaseInsensitiveContains(s) }
        let look: (String, Color, Bool)
        if has("slow down") { look = ("tortoise.fill", .orange, true) }
        else if has("finger") { look = ("hand.raised.fill", .orange, true) }
        else if has("dark") { look = ("lightbulb.fill", .yellow, true) }
        else if has("tracking") || has("losing its place") || has("finding its place") || has("more detail") {
            look = ("exclamationmark.triangle.fill", .orange, true)
        }
        else if has("good.") || has("well covered") { look = ("checkmark.seal.fill", .green, false) }
        else if has("all the way round") || has("tilt") { look = ("arrow.up.and.down.circle.fill", .cyan, false) }
        else if has("turn slowly") { look = ("arrow.triangle.2.circlepath", .cyan, false) }
        else if has("storage") { look = ("archivebox.fill", .purple, false) }
        else if has("floor") { look = ("arrow.down.to.line", .blue, false) }
        else if has("wall") { look = ("viewfinder", .blue, false) }
        else { look = ("sparkles", .blue, false) }
        self.init(text, symbol: look.0, tint: look.1, urgent: look.2)
    }
}

struct HintCard: View {
    let tip: ScanTip

    var body: some View {
        HStack(alignment: .center, spacing: 12) {
            Image(systemName: tip.symbol)
                .font(.title3.weight(.semibold))
                .foregroundStyle(tip.tint)
                .symbolEffect(.pulse, isActive: tip.urgent)
                .frame(width: 30)
            Text(tip.text)
                .font(.callout.weight(.semibold))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(tip.tint.opacity(tip.urgent ? 0.8 : 0.35), lineWidth: tip.urgent ? 2 : 1)
        }
        .accessibilityElement(children: .combine)
    }
}

/// What RoomPlan has found, as chips that count up (and light up once there's one).
struct CountChips: View {
    let counts: ScanSession.Counts

    var body: some View {
        HStack(spacing: 8) {
            chip(counts.walls, "square.split.2x1", "wall")
            chip(counts.doors, "door.left.hand.closed", "door")
            chip(counts.windows, "window.vertical.closed", "window")
            chip(counts.objects, "sofa", "object")
        }
        .animation(.snappy, value: counts)
    }

    private func chip(_ n: Int, _ symbol: String, _ noun: String) -> some View {
        HStack(spacing: 5) {
            Image(systemName: symbol).font(.caption.weight(.semibold))
            Text("\(n)").font(.subheadline.weight(.bold).monospacedDigit())
                .contentTransition(.numericText(value: Double(n)))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .foregroundStyle(n > 0 ? Color.primary : Color.secondary)
        .background(n > 0 ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.07), in: Capsule())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("\(n) \(noun)\(n == 1 ? "" : "s")")
    }
}

/// Red and breathing while the camera records, green once saved.
struct StatusDot: View {
    let phase: ScanSession.Phase
    let meshPass: Bool

    var body: some View {
        let recording = phase == .scanning || meshPass
        Image(systemName: "circle.fill")
            .font(.system(size: 10))
            .foregroundStyle(recording ? Color.red : phase.isDone ? Color.green : Color.secondary)
            .symbolEffect(.pulse, isActive: recording)
            .accessibilityHidden(true)
    }
}

struct RoundIconButton: View {
    let symbol: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 44, height: 44)
                .background(Color.primary.opacity(0.1), in: Circle())
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(label)
    }
}

/// A camera-app shutter: the photo button is the one you reach for while scanning.
struct ShutterButton: View {
    let count: Int
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            ZStack {
                Circle().strokeBorder(.white, lineWidth: 4).frame(width: 70, height: 70)
                Circle().fill(.white).frame(width: 56, height: 56)
                Image(systemName: "camera.fill").font(.title3).foregroundStyle(.black)
            }
            .overlay(alignment: .topTrailing) {
                if count > 0 {
                    Text("\(count)")
                        .font(.caption2.weight(.bold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(count)))
                        .foregroundStyle(.white)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor, in: Capsule())
                        .offset(x: 4, y: -2)
                }
            }
            .animation(.snappy, value: count)
        }
        .buttonStyle(PressScale())
        .accessibilityLabel(count == 0 ? "Take photo" : "Take photo, \(count) taken")
    }
}

struct PressScale: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.9 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

/// After a scan: the storage units that still need a close-up photo, and the ones whose shelf edges
/// the LiDAR mesh could not confirm.
struct BeforeYouLeave: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        let unsure = session.checklist.filter { $0.unconfirmedShelves > 0 }
        VStack(alignment: .leading, spacing: 6) {
            Text("Before you leave").font(.subheadline.weight(.semibold))
            ForEach(session.checklist) { unit in
                HStack(spacing: 8) {
                    Image(systemName: unit.hasPhoto ? "checkmark.circle.fill" : "circle")
                        .foregroundStyle(unit.hasPhoto ? Color.green : Color.orange)
                    Text(unit.label).font(.caption).lineLimit(2)
                    Spacer()
                    if unit.hasPhoto {
                        Text("close-up taken").font(.caption2).foregroundStyle(.secondary)
                    } else {
                        // A saved scan can't take a new pinned photo; the photos come from scanning.
                        Text("Scan again to add photos").font(.caption2).foregroundStyle(.secondary)
                    }
                }
            }
            if !unsure.isEmpty {
                let names = unsure.map { $0.label.components(separatedBy: " (").first ?? $0.label }
                Label("Confirm shelf heights with a tape: " + names.joined(separator: ", ")
                      + " (LiDAR did not confirm \(unsure.map { $0.unconfirmedShelves }.reduce(0, +)) shelf edges).",
                      systemImage: "ruler")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct SettingsView: View {
    @EnvironmentObject private var settings: ServerSettings
    @Environment(\.dismiss) private var dismiss
    @State private var check: String?
    @State private var checking = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("http://192.168.1.20:8765", text: $settings.serverURL)
                        .keyboardType(.URL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                    SecureField("Bearer token", text: $settings.token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                } header: {
                    Text("roomscan server")
                } footer: {
                    Text("Start it with: roomscan serve --http 0.0.0.0:8765 (on the Quest, a Mac or a PC). "
                         + "It prints its address and token.")
                }
                Section {
                    Toggle("Send while scanning", isOn: $settings.liveUpdates)
                } footer: {
                    Text("An LLM watching the server sees the room build up and can tell you what's missing. "
                         + "Off: only the finished scan is sent.")
                }
                Section {
                    Button {
                        Task { await test() }
                    } label: {
                        HStack {
                            Text("Test connection")
                            if checking { Spacer(); ProgressView() }
                        }
                    }
                    .disabled(settings.client == nil || checking)
                    if let check { Text(check).font(.callout) }
                }
            }
            .navigationTitle("Server")
            .toolbar { Button("Done") { dismiss() } }
        }
    }

    private func test() async {
        guard let client = settings.client else { return }
        checking = true
        defer { checking = false }
        do {
            let n = try await client.scanCount()
            check = "Connected. The server has \(n) scan\(n == 1 ? "" : "s")."
        } catch {
            check = error.localizedDescription
        }
    }
}
