import Foundation
import RoomPlan

/// A finished scan kept on the phone: Documents/Scans/<id>/{room.json, room.usdz, <id>-plan.pdf, info.json}.
/// The Files app can see Documents, so the JSON and USDZ can be pulled off without the server.
struct SavedScan: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var date: Date
    var walls: Int
    var doors: Int
    var windows: Int
    var objects: Int
    var photos: Int?  // nil for scans saved before the app took photos
    var serverScanID: String?
    var uploadError: String?

    var uploaded: Bool { serverScanID != nil && uploadError == nil }
}

final class ScanLibrary: ObservableObject {
    @Published private(set) var scans: [SavedScan] = []
    let root: URL

    private let encoder: JSONEncoder = {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return e
    }()
    private let decoder: JSONDecoder = {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return d
    }()

    init() {
        root = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scans", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        reload()
    }

    func folder(_ s: SavedScan) -> URL { root.appendingPathComponent(s.id, isDirectory: true) }
    func jsonURL(_ s: SavedScan) -> URL { folder(s).appendingPathComponent("room.json") }
    func usdzURL(_ s: SavedScan) -> URL { folder(s).appendingPathComponent("room.usdz") }
    func hasUSDZ(_ s: SavedScan) -> Bool { FileManager.default.fileExists(atPath: usdzURL(s).path) }
    func planURL(_ s: SavedScan) -> URL { folder(s).appendingPathComponent("\(s.id)-plan.pdf") }
    func photosFolder(_ s: SavedScan) -> URL { folder(s).appendingPathComponent("photos", isDirectory: true) }
    func framesFolder(_ s: SavedScan) -> URL { folder(s).appendingPathComponent("frames", isDirectory: true) }
    func elevationsFolder(_ s: SavedScan) -> URL { folder(s).appendingPathComponent("elevations", isDirectory: true) }

    func keyframes(for s: SavedScan) -> [(Keyframe, URL)] {
        let dir = framesFolder(s)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("frames.json")),
              let list = try? decoder.decode([Keyframe].self, from: data) else { return [] }
        return list.map { ($0, dir.appendingPathComponent($0.file)) }
    }

    func elevations(for s: SavedScan) -> [(Elevation, URL)] { WallElevations.load(from: elevationsFolder(s)) }

    /// Projects the scan's keyframes onto each wall, then redraws the plan PDF with them.
    /// Takes a few seconds; runs off the main thread.
    func addElevations(_ s: SavedScan, room: CapturedRoom) async {
        let frames = keyframes(for: s)
        guard !frames.isEmpty else { return }
        let dir = elevationsFolder(s)
        let made = await Task.detached(priority: .userInitiated) {
            WallElevations.render(room, frames: frames, to: dir)
        }.value
        guard !made.isEmpty else { return }
        try? FloorPlanPDF.write(room, name: s.name, date: s.date, photos: photos(for: s),
                                elevations: elevations(for: s), to: planURL(s))
    }

    /// The scan's photos with their files, in the order they were taken.
    func photos(for s: SavedScan) -> [(ScanPhoto, URL)] {
        let dir = photosFolder(s)
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("photos.json")),
              let list = try? decoder.decode([ScanPhoto].self, from: data) else { return [] }
        return list.map { ($0, dir.appendingPathComponent($0.file)) }
    }

    /// The dimensioned floor plan PDF, drawn from the saved scan if it isn't there yet
    /// (scans saved before the app made plans).
    func plan(for s: SavedScan) throws -> URL {
        let url = planURL(s)
        if !FileManager.default.fileExists(atPath: url.path) {
            let room = try JSONDecoder().decode(CapturedRoom.self, from: json(for: s))
            try FloorPlanPDF.write(room, name: s.name, date: s.date, photos: photos(for: s),
                                   elevations: elevations(for: s), to: url)
        }
        return url
    }

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        scans = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("info.json")) else { return nil }
            return try? decoder.decode(SavedScan.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    /// Keep a processed room: its RoomPlan JSON, a USDZ model of it, the photos and keyframes
    /// taken while scanning, a floor plan PDF, and the bookkeeping. Elevations come after
    /// (addElevations), since they take a while.
    func save(room: CapturedRoom, json: Data, name: String, photos: [(ScanPhoto, Data)] = [],
              frames: [(Keyframe, Data)] = []) throws -> SavedScan {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let slug = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        var scan = SavedScan(id: "\(stamp)-\(slug.isEmpty ? "scan" : slug)", name: name, date: Date(),
                             walls: room.walls.count, doors: room.doors.count,
                             windows: room.windows.count, objects: room.objects.count,
                             photos: photos.isEmpty ? nil : photos.count)
        while FileManager.default.fileExists(atPath: folder(scan).path) { scan.id += "-1" }
        try FileManager.default.createDirectory(at: folder(scan), withIntermediateDirectories: true)
        try json.write(to: jsonURL(scan))
        try? room.export(to: usdzURL(scan))  // a nice-to-have; the JSON is what the server needs
        if !photos.isEmpty {
            let dir = photosFolder(scan)
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (photo, jpeg) in photos { try jpeg.write(to: dir.appendingPathComponent(photo.file)) }
            try encoder.encode(photos.map { $0.0 }).write(to: dir.appendingPathComponent("photos.json"))
        }
        if !frames.isEmpty {
            let dir = framesFolder(scan)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (frame, jpeg) in frames { try? jpeg.write(to: dir.appendingPathComponent(frame.file)) }
            try? encoder.encode(frames.map { $0.0 }).write(to: dir.appendingPathComponent("frames.json"))
        }
        try? FloorPlanPDF.write(room, name: name, date: scan.date, photos: self.photos(for: scan), to: planURL(scan))
        try write(scan)
        return scan
    }

    func update(_ scan: SavedScan) {
        try? write(scan)
        reload()
    }

    func delete(_ scan: SavedScan) {
        try? FileManager.default.removeItem(at: folder(scan))
        reload()
    }

    func json(for scan: SavedScan) throws -> Data { try Data(contentsOf: jsonURL(scan)) }

    private func write(_ scan: SavedScan) throws {
        try encoder.encode(scan).write(to: folder(scan).appendingPathComponent("info.json"))
        reload()
    }
}
