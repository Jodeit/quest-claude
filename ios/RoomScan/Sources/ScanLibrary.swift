import Foundation
import RoomPlan

/// A finished scan kept on the phone: Documents/Scans/<id>/{room.json, room.usdz, info.json}.
/// The Files app can see Documents, so the JSON and USDZ can be pulled off without the server.
struct SavedScan: Identifiable, Codable, Hashable {
    var id: String
    var name: String
    var date: Date
    var walls: Int
    var doors: Int
    var windows: Int
    var objects: Int
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

    func reload() {
        let dirs = (try? FileManager.default.contentsOfDirectory(at: root, includingPropertiesForKeys: nil)) ?? []
        scans = dirs.compactMap { dir in
            guard let data = try? Data(contentsOf: dir.appendingPathComponent("info.json")) else { return nil }
            return try? decoder.decode(SavedScan.self, from: data)
        }
        .sorted { $0.date > $1.date }
    }

    /// Keep a processed room: its RoomPlan JSON, a USDZ model of it, and the bookkeeping.
    func save(room: CapturedRoom, json: Data, name: String) throws -> SavedScan {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = f.string(from: Date())
        let slug = name.lowercased().components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
        var scan = SavedScan(id: "\(stamp)-\(slug.isEmpty ? "scan" : slug)", name: name, date: Date(),
                             walls: room.walls.count, doors: room.doors.count,
                             windows: room.windows.count, objects: room.objects.count)
        while FileManager.default.fileExists(atPath: folder(scan).path) { scan.id += "-1" }
        try FileManager.default.createDirectory(at: folder(scan), withIntermediateDirectories: true)
        try json.write(to: jsonURL(scan))
        try? room.export(to: usdzURL(scan))  // a nice-to-have; the JSON is what the server needs
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
