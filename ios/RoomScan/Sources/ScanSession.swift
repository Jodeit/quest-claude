import Foundation
import RoomPlan
import UIKit

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
    }

    struct Counts: Equatable {
        var walls = 0, doors = 0, windows = 0, objects = 0

        init() {}
        init(_ room: CapturedRoom) {
            walls = room.walls.count
            doors = room.doors.count
            windows = room.windows.count
            objects = room.objects.count
        }
    }

    nonisolated let id = UUID()
    private(set) var name: String
    /// Every room scanned in this session belongs to one home.
    let homeID = UUID().uuidString
    @Published private(set) var roomsSaved = 0
    let controller = RoomCaptureController()

    @Published private(set) var phase: Phase = .scanning
    @Published private(set) var counts = Counts()
    @Published private(set) var serverStatus: String
    @Published private(set) var photoCount = 0
    @Published private(set) var coverage: CoverageSnapshot?

    /// Photos taken during this scan, kept in memory until the scan is saved with them.
    private var photos: [(ScanPhoto, Data)] = []

    private let client: ServerClient?
    private let live: Bool
    private let library: ScanLibrary
    private var serverScanID: String?
    private var latest: CapturedRoom?
    private var sending = false
    private var lastSent = Date.distantPast
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
        controller.onCoverage = { [weak self] snapshot in
            Task { @MainActor in self?.coverage = snapshot }
        }
        controller.onShutter = { [weak self] in
            Task { @MainActor in _ = await self?.takePhoto() }
        }
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
        photos = []
        photoCount = 0
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
                try await send(try JSONEncoder().encode(room), live: true)
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
            try await client.update(id, body, live: live)
        } else {
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
            body = try JSONEncoder().encode(room)
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
        roomsSaved += 1
        phase = .done(saved)
    }
}
