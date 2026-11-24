import QuickLook
import RoomPlan
import SwiftUI

struct HomeView: View {
    @EnvironmentObject private var settings: ServerSettings
    @EnvironmentObject private var library: ScanLibrary
    @State private var showSettings = false
    @State private var askName = false
    @State private var newName = ""
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
                    Button {
                        newName = ""
                        askName = true
                    } label: {
                        Label("New scan", systemImage: "viewfinder")
                    }
                    .disabled(!RoomCaptureSession.isSupported)
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
            .alert("Name this room", isPresented: $askName) {
                TextField("Living room", text: $newName)
                Button("Scan") { start() }
                Button("Cancel", role: .cancel) {}
            }
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
        let name = newName.trimmingCharacters(in: .whitespaces)
        session = ScanSession(name: name.isEmpty ? "Room" : name, settings: settings, library: library)
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
    @State private var showDollhouse = false
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
                 + (scan.photos.map { " · \($0) photo\($0 == 1 ? "" : "s")" } ?? ""))
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
                        do { bundleURL = try library.bundle(scan) } catch {
                            planError = "Couldn't zip the scan: \(error.localizedDescription)"
                        }
                    } label: { Label("Share scan bundle (.zip)", systemImage: "archivebox") }
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
    @State private var gray = true
    @State private var nextName = ""

    var body: some View {
        ZStack(alignment: .bottom) {
            RoomCaptureRepresentable(controller: session.controller)
                .ignoresSafeArea()
            Color.white.opacity(flash ? 0.6 : 0).ignoresSafeArea().allowsHitTesting(false)
                .onChange(of: session.photoCount) { flashOnce() }
            if session.phase == .scanning, let coverage = session.coverage {
                CoverageMap(snapshot: coverage)
                    .padding()
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topTrailing)
                    .allowsHitTesting(false)
            }
            VStack(spacing: 10) {
                Text(title).font(.headline)
                Text("\(session.counts.walls) walls · \(session.counts.doors) doors · "
                     + "\(session.counts.windows) windows · \(session.counts.objects) objects")
                    .font(.subheadline)
                if session.phase == .scanning, let hint = session.coverage?.hint {
                    Text(hint).font(.callout.weight(.medium)).multilineTextAlignment(.center)
                }
                Text(session.serverStatus).font(.caption).foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                HStack(spacing: 12) {
                    switch session.phase {
                    case .scanning:
                        Button("Cancel", role: .cancel) {
                            session.cancel()
                            close()
                        }
                        .buttonStyle(.bordered)
                        Button {
                            gray.toggle()
                            session.controller.showsGray = gray
                        } label: {
                            Image(systemName: gray ? "circle.lefthalf.filled" : "circle")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel(gray ? "Hide gray for unphotographed walls" : "Show gray for unphotographed walls")
                        Button {
                            Task { await shoot() }
                        } label: {
                            Label(session.photoCount == 0 ? "Photo" : "Photo (\(session.photoCount))",
                                  systemImage: "camera.fill")
                        }
                        .buttonStyle(.bordered)
                        Button("Done") {
                            if (session.coverage?.weakWalls ?? 0) > 0 { confirmDone = true } else { session.finish() }
                        }
                        .buttonStyle(.borderedProminent)
                        .confirmationDialog(doneQuestion, isPresented: $confirmDone, titleVisibility: .visible) {
                            Button("Keep scanning", role: .cancel) {}
                            Button("Finish anyway") { session.finish() }
                        }
                    case .processing:
                        ProgressView()
                    case .done:
                        Button("Close", action: close).buttonStyle(.bordered)
                        Button("Scan next room") {
                            nextName = ""
                            askNext = true
                        }
                        .buttonStyle(.borderedProminent)
                    default:
                        Button("Close", action: close).buttonStyle(.borderedProminent)
                    }
                }
            }
            .padding()
            .frame(maxWidth: 420)
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
            .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 18))
            .padding()
        }
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
        case .scanning: return "Scanning \(session.name)"
        case .processing: return "Processing…"
        case .done: return "Saved \(session.name)"
        case let .failed(message): return message
        case .cancelled: return "Cancelled"
        }
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
