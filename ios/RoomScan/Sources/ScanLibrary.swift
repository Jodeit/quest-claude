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
    var homeID: String?  // rooms scanned one after another in one session share it
    var meshTriangles: Int?          // the saved LiDAR mesh
    var roomPlanMeshTriangles: Int?  // most mesh triangles the session had during the RoomPlan scan
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
    func storageFronts(for s: SavedScan) -> [(StorageFront, URL)] { WallElevations.loadStorageFronts(from: elevationsFolder(s)) }
    func floorImage(for s: SavedScan) -> (WallElevations.FloorImage, URL)? { WallElevations.loadFloor(from: elevationsFolder(s)) }

    func hasFrames(_ s: SavedScan) -> Bool {
        FileManager.default.fileExists(atPath: framesFolder(s).appendingPathComponent("frames.json").path)
    }

    /// Redraw the elevations from the frames already kept (after the app's method improves).
    func rebuildElevations(_ s: SavedScan) async throws {
        let room = try JSONDecoder().decode(CapturedRoom.self, from: json(for: s))
        await addElevations(s, room: room)
    }

    /// The whole scan folder as a .zip (scan, photos, frames, elevations, PDF, products, names), for
    /// sending on. iOS zips a folder when it's read "for uploading".
    func bundle(_ s: SavedScan) throws -> URL {
        _ = try? plan(for: s)  // include an up-to-date PDF
        var made: URL?
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: folder(s), options: .forUploading, error: &coordError) { zip in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(s.id).zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zip, to: dest)
                made = dest
            } catch {
                failure = error
            }
        }
        if let coordError { throw coordError }
        if let failure { throw failure }
        guard let made else { throw CocoaError(.fileWriteUnknown) }
        return made
    }

    /// Homes: rooms that share a homeID, two or more, oldest room first.
    var homes: [[SavedScan]] {
        Dictionary(grouping: scans.filter { $0.homeID != nil }, by: { $0.homeID! })
            .values.filter { $0.count > 1 }
            .map { $0.sorted { $0.date < $1.date } }
            .sorted { ($0.first?.date ?? .distantPast) > ($1.first?.date ?? .distantPast) }
    }

    /// One page with every room of a home in place.
    func homePlan(_ rooms: [SavedScan]) throws -> URL {
        let decoded = try rooms.map { (name: $0.name, room: try JSONDecoder().decode(CapturedRoom.self, from: json(for: $0))) }
        let first = rooms.first!
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(first.id)-home-plan.pdf")
        let title = "Home: " + rooms.map(\.name).joined(separator: ", ")
        try FloorPlanPDF.renderHome(decoded, title: title, date: first.date).write(to: url, options: .atomic)
        return url
    }

    func meshURL(_ s: SavedScan) -> URL { folder(s).appendingPathComponent("mesh.bin") }
    func mesh(for s: SavedScan) -> LiDARMesh? { LiDARMesh.read(from: meshURL(s)) }

    /// Keeps a LiDAR mesh with the scan, and any frames taken for it (the photo-real pass), first
    /// fitting it onto the room's walls and floor and moving the frames the same way.
    func addMesh(_ mesh: LiDARMesh, frames: [(Keyframe, Data)] = [], to s: SavedScan) {
        var mesh = mesh
        var frames = frames
        if let data = try? json(for: s), let room = try? JSONDecoder().decode(CapturedRoom.self, from: data) {
            let fix = mesh.fit(to: room)
            for i in frames.indices { frames[i].0.transform = (fix * frames[i].0.pose).packed }
        }
        try? mesh.write(to: meshURL(s))
        if !frames.isEmpty {
            let dir = framesFolder(s)
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            for (frame, jpeg) in frames { try? jpeg.write(to: dir.appendingPathComponent(frame.file)) }
            let all = keyframes(for: s).map { $0.0 } + frames.map { $0.0 }
            try? encoder.encode(all).write(to: dir.appendingPathComponent("frames.json"))
        }
        var updated = s
        updated.meshTriangles = mesh.triangleCount
        update(updated)
    }

    func products(for s: SavedScan) -> [ProductLine] {
        guard let data = try? Data(contentsOf: folder(s).appendingPathComponent("products.json")) else { return [] }
        return (try? decoder.decode([ProductLine].self, from: data)) ?? []
    }

    /// Saves the scan's product list; the plan PDF is redrawn with it next time it's opened.
    func setProducts(_ lines: [ProductLine], for s: SavedScan) {
        try? encoder.encode(lines).write(to: folder(s).appendingPathComponent("products.json"), options: .atomic)
        try? FileManager.default.removeItem(at: planURL(s))
        objectWillChange.send()
    }

    /// The organizer's names for spots: plan label ("3 Storage", "Wall W2") -> name ("Coffee station").
    func names(for s: SavedScan) -> [String: String] {
        guard let data = try? Data(contentsOf: folder(s).appendingPathComponent("names.json")) else { return [:] }
        return (try? decoder.decode([String: String].self, from: data)) ?? [:]
    }

    func setNames(_ names: [String: String], for s: SavedScan) {
        let kept = names.filter { !$0.value.trimmingCharacters(in: .whitespaces).isEmpty }
        try? encoder.encode(kept).write(to: folder(s).appendingPathComponent("names.json"), options: .atomic)
        try? FileManager.default.removeItem(at: planURL(s))
        objectWillChange.send()
    }

    /// The places products can go, labelled as on the plan: the whole room, each wall, each object.
    func locations(for s: SavedScan) -> [String] {
        var out = [ProductLine.wholeRoom]
        guard let data = try? json(for: s), let room = try? JSONDecoder().decode(CapturedRoom.self, from: data) else {
            return out
        }
        out += room.objects.enumerated().map { "\($0.offset + 1) \(FloorPlanPDF.objectLabel($0.element.category))" }
        out += room.walls.indices.map { "Wall W\($0 + 1)" }
        return out
    }

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
                                elevations: elevations(for: s), products: products(for: s), names: names(for: s),
                                fronts: storageFronts(for: s), measured: measurements(for: s), to: planURL(s))
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
                                   elevations: elevations(for: s), products: products(for: s), names: names(for: s),
                                   fronts: storageFronts(for: s), measured: measurements(for: s), to: url)
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
    func save(room: CapturedRoom, json: Data, name: String, homeID: String? = nil, photos: [(ScanPhoto, Data)] = [],
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
                             photos: photos.isEmpty ? nil : photos.count, homeID: homeID)
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
