import Foundation
import RoomPlan
import UIKit
import simd

/// One scan from start to saved: streams interim rooms to the server while scanning (at most one
/// every couple of seconds, always the newest), then saves and sends the processed room.
@MainActor
final class ScanSession: ObservableObject, Identifiable {
    enum Phase: Equatable {
        case scanning
        case processing
        case done(SavedScan)
        case failed(String)
        case cancelled

        var isDone: Bool {
            if case .done = self { return true }
            return false
        }
    }

    struct Counts: Equatable {
        var walls = 0, doors = 0, windows = 0, objects = 0
        var total: Int { walls + doors + windows + objects }

        init() {}
        init(_ room: CapturedRoom) {
            walls = room.walls.count
            doors = room.doors.count
            windows = room.windows.count
            objects = room.objects.count
        }
    }

    /// One storage unit in the "Before you leave" checklist.
    struct UnitCheck: Identifiable, Equatable {
        var id: Int { object }
        var object: Int          // index into the room's objects
        var label: String
        var hasPhoto: Bool       // a pinned photo was taken close to its front, facing it
        var unconfirmedShelves: Int  // shelf edges the LiDAR mesh did not confirm (all of them without a mesh)
    }

    nonisolated let id = UUID()
    @Published private(set) var name: String
    /// When this room's scan started, for the clock on the scan screen.
    @Published private(set) var startedAt = Date()
    /// Every room scanned in this session belongs to one home.
    let homeID = UUID().uuidString
    @Published private(set) var roomsSaved = 0
    @Published private(set) var meshPassRunning = false
    let controller = RoomCaptureController()

    @Published private(set) var phase: Phase = .scanning
    @Published private(set) var counts = Counts()
    @Published private(set) var serverStatus: String
    @Published private(set) var photoCount = 0
    @Published private(set) var coverage: CoverageSnapshot?
    /// The capture hint of the moment (CaptureHints), before the coverage one.
    @Published private(set) var hint: String?
    /// The photo-real pass's stop of the moment, for the ring (nil when not at one).
    @Published private(set) var stop: StopProgress?
    /// After the photo-real pass: a 360 preview per stop, gray where nothing was photographed.
    @Published private(set) var previews: [SpotPreview] = []
    /// Storage units of the room just saved, with what still needs a close-up or a tape.
    @Published private(set) var checklist: [UnitCheck] = []

    /// Photos taken during this scan, kept in memory until the scan is saved with them.
    private var photos: [(ScanPhoto, Data)] = []

    private let client: ServerClient?
    private let live: Bool
    private let library: ScanLibrary
    private var serverScanID: String?
    private var latest: CapturedRoom?
    private var sending = false
    private var lastSent = Date.distantPast
    /// The name changed since the server copy was made: the next send carries it.
    private var renamed = false
    private static let liveInterval: TimeInterval = 2

    init(name: String, settings: ServerSettings, library: ScanLibrary) {
        self.name = name
        self.library = library
        client = settings.client
        live = settings.liveUpdates && client != nil
        serverStatus = client == nil ? "No server set: the scan stays on this phone."
            : live ? "Live: waiting for the first walls…" : "Will send to the server when done."
        controller.onLiveUpdate = { [weak self] room in
            Task { @MainActor in self?.liveUpdate(room) }
        }
        controller.onFinished = { [weak self] result in
            Task { @MainActor in self?.finished(result) }
        }
        controller.onHint = { [weak self] text in
            Task { @MainActor in if self?.hint != text { self?.hint = text } }
        }
        controller.onStop = { [weak self] progress in
            Task { @MainActor in if self?.stop != progress { self?.stop = progress } }
        }
        controller.onCoverage = { [weak self] snapshot in
            Task { @MainActor in self?.coverage = snapshot }
        }
        controller.onShutter = { [weak self] in
            Task { @MainActor in _ = await self?.takePhoto() }
        }
    }

    /// Scans start with a made-up name, one tap from the home screen; this names the room while
    /// scanning (the saved scan and the server copy both take it).
    func rename(to new: String) {
        let n = new.trimmingCharacters(in: .whitespaces)
        guard !n.isEmpty, n != name, phase == .scanning || phase == .processing else { return }
        name = n
        renamed = true
    }

    func finish() {
        guard phase == .scanning else { return }
        phase = .processing
        controller.finish()
    }

    func cancel() {
        phase = .cancelled
        controller.finish()
    }

    /// After a room is saved: scan the next one without stopping the camera, so it lands in the
    /// same coordinates and the home can be drawn as a whole.
    func nextRoom(named next: String) {
        guard case .done = phase else { return }
        name = next
        renamed = false
        startedAt = Date()
        photos = []
        photoCount = 0
        checklist = []
        previews = []
        coverage = nil
        counts = Counts()
        serverScanID = nil
        latest = nil
        lastSent = .distantPast
        serverStatus = client == nil ? "No server set: the scan stays on this phone."
            : live ? "Live: waiting for the first walls…" : "Will send to the server when done."
        phase = .scanning
        controller.startNextRoom()
    }

    /// After a room is saved: sweep it again while ARKit builds its LiDAR mesh, for the photo-real model.
    func startMeshPass() {
        guard case .done = phase, !meshPassRunning else { return }
        if controller.startMeshPass() {
            meshPassRunning = true
            previews = []
            coverage = nil  // the pass reports its own, from the mesh
            serverStatus = "Photo-real pass: sweep the room slowly, close to things you care about, until the "
                + "blue mesh covers them. Then tap Finish."
        } else {
            serverStatus = "This device can't build a LiDAR mesh."
        }
    }

    func finishMeshPass() {
        guard meshPassRunning, case let .done(saved) = phase else { return }
        let mesh = controller.finishMeshPass()
        meshPassRunning = false
        guard let mesh else {
            serverStatus = "No mesh came through; the room is saved as it was."
            return
        }
        let known = Set(library.keyframes(for: saved).map { $0.0.file })
        let frames = controller.keyframes.filter { $0.0.file.hasPrefix("M") && !known.contains($0.0.file) }
        library.addMesh(mesh, frames: frames, to: saved)
        serverStatus = "Photo-real model saved: \(mesh.triangleCount) triangles, \(frames.count) more frames. Open 3D."
        let current = library.scans.first { $0.id == saved.id } ?? saved
        checklist = buildChecklist(current)  // the mesh may have confirmed more shelf edges
        let all = controller.keyframes
        Task {
            let made = await Task.detached(priority: .userInitiated) { SpotPreview.make(frames: all) }.value
            if !meshPassRunning { previews = made }
        }
    }

    /// One-tap start for a unit's missing close-up: brings the camera back up (the photo-real pass is the
    /// existing way to have it live after a save) and says which unit to go to.
    func startCloseUp(of unit: UnitCheck) {
        if !meshPassRunning { startMeshPass() }
        if meshPassRunning {
            serverStatus = "Go to \(unit.label), stand about a metre from its front and keep it in view."
        }
    }

    /// Storage units of a saved room: which have a pinned photo close to their front, and how many of
    /// their shelf edges the LiDAR mesh did not confirm.
    private func buildChecklist(_ saved: SavedScan) -> [UnitCheck] {
        guard let data = try? library.json(for: saved),
              let room = try? JSONDecoder().decode(CapturedRoom.self, from: data) else { return [] }
        let fronts = library.storageFronts(for: saved).map { $0.0 }
        let poses = library.photos(for: saved).map { $0.0.pose }
        let names: [String: String] = library.names(for: saved)
        // The room's middle, from its walls: a unit with no scanned front is taken to face it.
        var centre = SIMD3<Float>(0, 0, 0)
        if !room.walls.isEmpty {
            for w in room.walls { centre += simd_make_float3(w.transform.columns.3) }
            centre /= Float(room.walls.count)
        }
        var out: [UnitCheck] = []
        for (index, o) in room.objects.enumerated() where o.category == .storage {
            let front = fronts.first { $0.object == index }
            let t = o.transform
            let center = simd_make_float3(t.columns.3)
            var zAxis = simd_make_float3(t.columns.2)
            zAxis.y = 0
            zAxis = simd_length(zAxis) > 1e-6 ? simd_normalize(zAxis) : SIMD3<Float>(0, 0, 1)
            var normal: SIMD3<Float> = zAxis
            if let front {
                if front.flipped { normal = -zAxis }
            } else {
                var toRoom = centre - center
                toRoom.y = 0
                if simd_dot(toRoom, zAxis) < 0 { normal = -zAxis }
            }
            let target = center + normal * (o.dimensions.z / 2)
            var covered = false
            for pose in poses {
                let cam = simd_make_float3(pose.columns.3)
                let forward = -simd_normalize(simd_make_float3(pose.columns.2))
                let toUnit = target - cam
                let dist = simd_length(toUnit)
                guard dist > 0.01, dist < 2.0 else { continue }
                if simd_dot(toUnit / dist, forward) > 0.7 && simd_dot(-toUnit / dist, normal) > 0.3 {
                    covered = true
                    break
                }
            }
            var unsure = 0
            if let front {
                if let sure = front.confirmed {
                    unsure = sure.filter { !$0 }.count
                } else {
                    unsure = front.shelves.count
                }
            }
            // The plan's own label for it ("3 Storage", or "3 Coffee station" when named).
            let key = "\(index + 1) \(FloorPlanPDF.objectLabel(o.category))"
            let size = front.map { " (\(FloorPlanPDF.fine($0.width)) wide, \(FloorPlanPDF.fine($0.height)) high)" } ?? ""
            out.append(UnitCheck(object: index, label: "\(FloorPlanPDF.shown(key, names))\(size)", hasPhoto: covered,
                                 unconfirmedShelves: unsure))
        }
        return out
    }

    /// Take a photo from the scanning camera; it's pinned on the plan where it was taken.
    func takePhoto() async -> Bool {
        guard phase == .scanning, let shot = await controller.capturePhoto() else { return false }
        let photo = ScanPhoto(file: String(format: "P%02d.jpg", photos.count + 1), date: Date(), pose: shot.pose)
        photos.append((photo, shot.jpeg))
        photoCount = photos.count
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
        return true
    }

    // MARK: live

    private func liveUpdate(_ room: CapturedRoom) {
        guard phase == .scanning else { return }
        counts = Counts(room)
        guard live else { return }
        latest = room
        pump()
    }

    private func pump() {
        guard !sending, phase == .scanning, let room = latest else { return }
        let wait = Self.liveInterval - Date().timeIntervalSince(lastSent)
        if wait > 0 {
            sending = true
            Task {
                try? await Task.sleep(nanoseconds: UInt64(wait * 1_000_000_000))
                sending = false
                pump()
            }
            return
        }
        latest = nil
        sending = true
        lastSent = Date()
        Task {
            do {
                // A room's JSON runs to hundreds of kilobytes: encode it away from the main thread,
                // which is drawing the camera.
                let body = try await Task.detached(priority: .utility) { try JSONEncoder().encode(room) }.value
                try await send(body, live: true)
                serverStatus = "Live: sent \(Date().formatted(date: .omitted, time: .standard))"
            } catch {
                serverStatus = "Live update failed: \(error.localizedDescription)"
            }
            sending = false
            pump()
        }
    }

    private func send(_ body: Data, live: Bool) async throws {
        guard let client else { return }
        if let id = serverScanID {
            let rename = renamed ? name : nil
            try await client.update(id, body, live: live, name: rename)
            if let rename, rename == name { renamed = false }  // unless renamed again meanwhile
        } else {
            renamed = false
            serverScanID = try await client.create(body, name: name, live: live)
        }
    }

    // MARK: final

    private func finished(_ result: Result<CapturedRoom, Error>) {
        guard phase != .cancelled else { return }
        switch result {
        case let .failure(error):
            phase = .failed(error.localizedDescription)
        case let .success(room):
            counts = Counts(room)
            Task { await saveAndSend(room) }
        }
    }

    private func saveAndSend(_ room: CapturedRoom) async {
        let body: Data
        var saved: SavedScan
        do {
            body = try await Task.detached(priority: .userInitiated) { try JSONEncoder().encode(room) }.value
            saved = try library.save(room: room, json: body, name: name, homeID: homeID, photos: photos,
                                     frames: controller.keyframes)
        } catch {
            phase = .failed("Couldn't save the scan: \(error.localizedDescription)")
            return
        }
        if !controller.keyframes.isEmpty {
            let status = serverStatus
            serverStatus = "Making wall elevations…"
            await library.addElevations(saved, room: room)
            serverStatus = status
        }
        if client != nil {
            while sending { try? await Task.sleep(nanoseconds: 100_000_000) }  // let a live send land first
            serverStatus = "Sending…"
            do {
                try await send(body, live: false)
                saved.serverScanID = serverScanID
                saved.uploadError = nil
                serverStatus = "On the server as \(serverScanID ?? "?")"
            } catch {
                saved.uploadError = error.localizedDescription
                serverStatus = "Saved here; sending failed: \(error.localizedDescription)"
            }
            library.update(saved)
        }
        // The LiDAR mesh, if RoomPlan's session had one (and how much it saw either way).
        saved.roomPlanMeshTriangles = controller.meshTrianglesSeen
        library.update(saved)
        if let mesh = controller.roomMesh { library.addMesh(mesh, to: saved) }
        saved = library.scans.first { $0.id == saved.id } ?? saved
        checklist = buildChecklist(saved)
        roomsSaved += 1
        phase = .done(saved)
    }
}
