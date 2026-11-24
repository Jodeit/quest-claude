import CoreGraphics
import Foundation
import ImageIO
import RoomPlan
import UIKit
import simd

/// A frame decoded to RGB for sampling colours.
struct RGBImage {
    let width: Int, height: Int
    private let px: [UInt8]

    init?(url: URL) {
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else { return nil }
        width = img.width; height = img.height
        var buf = [UInt8](repeating: 0, count: width * height * 4)
        let w = width, h = height
        let ok = buf.withUnsafeMutableBytes { raw -> Bool in
            guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        guard ok else { return nil }
        px = buf
    }

    func sample(_ x: Float, _ y: Float) -> SIMD3<Float> {
        let xi = Swift.min(width - 1, Swift.max(0, Int(x))), yi = Swift.min(height - 1, Swift.max(0, Int(y)))
        let o = (yi * width + xi) * 4
        return SIMD3(Float(px[o]), Float(px[o + 1]), Float(px[o + 2]))
    }
}

/// The scan as a team twin: the folder the shared Claude artifact page loads (twin.json, the web mesh
/// as base64 text, the elevation, shelf, floor and photo images), zipped, for the page's Add a scan.
/// The same format `roomscan twin` writes, so either can feed the page.
enum TwinExport {
    static func make(_ s: SavedScan, library: ScanLibrary) throws -> URL {
        let room = try JSONDecoder().decode(CapturedRoom.self, from: library.json(for: s))
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("twin-\(s.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let img = dir.appendingPathComponent("img", isDirectory: true)
        try FileManager.default.createDirectory(at: img, withIntermediateDirectories: true)
        func copy(_ url: URL?) -> String? {
            guard let url, FileManager.default.fileExists(atPath: url.path) else { return nil }
            try? FileManager.default.copyItem(at: url, to: img.appendingPathComponent(url.lastPathComponent))
            return "img/" + url.lastPathComponent
        }
        func f3(_ v: SIMD3<Float>) -> [Double] { [Double(v.x), Double(v.y), Double(v.z)] }

        let floorY = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0
        let ceilingY = room.walls.map { $0.transform.columns.3.y + $0.dimensions.y / 2 }.max() ?? floorY + 2.4
        let centres = room.walls.map { simd_make_float3($0.transform.columns.3) }
        let centre = centres.isEmpty ? SIMD3<Float>(0, 0, 0) : centres.reduce(.zero, +) / Float(centres.count)
        let names = library.names(for: s)
        let elevations = library.elevations(for: s)

        var ends: [SIMD3<Float>] = []
        var walls: [[String: Any]] = []
        for (i, w) in room.walls.enumerated() {
            let e = elevations.first { $0.0.wall == i }
            let z = simd_make_float3(w.transform.columns.2), c = simd_make_float3(w.transform.columns.3)
            let f = WallFrame(w, flipped: e?.0.flipped ?? (simd_dot(centre - c, z) < 0))
            let a = f.center - f.along * (f.width / 2), b = f.center + f.along * (f.width / 2)
            ends += [a, b]
            let key = "Wall W\(i + 1)"
            var d: [String: Any] = ["key": key, "a": [Double(a.x), Double(a.z)], "b": [Double(b.x), Double(b.z)],
                                    "y0": Double(f.bottom), "height": Double(f.height), "length": Double(f.width),
                                    "normal": [Double(f.normal.x), Double(f.normal.z)]]
            if let n = names[key] { d["name"] = n }
            if let el = copy(e?.1) { d["elevation"] = el }
            walls.append(d)
        }
        var openings: [[String: Any]] = []
        for (kind, list) in [("door", room.doors), ("window", room.windows), ("opening", room.openings)] {
            for o in list {
                let x = simd_make_float3(o.transform.columns.0)
                openings.append(["kind": kind, "center": f3(simd_make_float3(o.transform.columns.3)),
                                 "along": [Double(x.x), Double(x.z)], "width": Double(o.dimensions.x), "height": Double(o.dimensions.y)])
            }
        }
        let fronts = library.storageFronts(for: s)
        var objects: [[String: Any]] = []
        for (i, o) in room.objects.enumerated() {
            let key = "\(i + 1) \(FloorPlanPDF.objectLabel(o.category))"
            var d: [String: Any] = ["key": key, "label": FloorPlanPDF.objectLabel(o.category),
                                    "center": f3(simd_make_float3(o.transform.columns.3)),
                                    "axis": [Double(o.transform.columns.0.x), Double(o.transform.columns.0.z)],
                                    "size": [Double(o.dimensions.x), Double(o.dimensions.y), Double(o.dimensions.z)]]
            if let n = names[key] { d["name"] = n }
            if let pair = fronts.first(where: { $0.0.object == i }) {
                let fr = pair.0, url = pair.1
                d["front"] = ["image": copy(url) as Any, "shelves": fr.shelves.map { Double($0) },
                              "openings_top_first": fr.openings.reversed().map { Double($0) },
                              "width": Double(fr.width), "height": Double(fr.height), "depth": Double(fr.depth)]
            }
            objects.append(d)
        }
        var floor: [String: Any] = [:]
        if let f = room.floors.first, f.polygonCorners.count > 2 {
            floor["polygon"] = f.polygonCorners.map { p -> [Double] in
                let w = f.transform * SIMD4<Float>(p.x, p.y, p.z, 1)
                return [Double(w.x), Double(w.z)]
            }
        }
        if let pair = library.floorImage(for: s) {
            let fl = pair.0, url = pair.1
            floor["image"] = copy(url)
            floor["bounds"] = [fl.minX, fl.minZ, fl.maxX, fl.maxZ].map { Double($0) }
            floor["y"] = Double(fl.y)
        }
        var photos: [[String: Any]] = []
        for (n, (p, url)) in library.photos(for: s).enumerated() {
            let pose = p.pose
            let fwd = -simd_make_float3(pose.columns.2)
            var d: [String: Any] = ["id": "P\(n + 1)", "position": f3(simd_make_float3(pose.columns.3)),
                                    "direction": [Double(fwd.x), Double(fwd.z)], "date": ISO8601DateFormatter().string(from: p.date)]
            if let im = copy(url) { d["image"] = im }
            photos.append(d)
        }

        var meshInfo: Any = NSNull()
        if let mesh = library.mesh(for: s), let first = ends.first {
            let lo = ends.reduce(first) { simd_min($0, $1) }, hi = ends.reduce(first) { simd_max($0, $1) }
            let web = mesh.webMesh(frames: library.keyframes(for: s), ceilingY: ceilingY,
                                   bounds: (SIMD3(lo.x - 0.4, floorY - 0.3, lo.z - 0.4), SIMD3(hi.x + 0.4, ceilingY + 0.3, hi.z + 0.4)))
            var model: [UInt32] = [], ceil: [UInt32] = []
            for (t, isCeiling) in web.ceiling.enumerated() {
                let tri = web.faces[(t * 3)..<(t * 3 + 3)]
                if isCeiling { ceil += tri } else { model += tri }
            }
            var data = Data("RTW1".utf8)
            for n in [UInt32(web.positions.count), UInt32(model.count), UInt32(ceil.count)] { withUnsafeBytes(of: n.littleEndian) { data.append(contentsOf: $0) } }
            for p in web.positions { for v in [p.x, p.y, p.z] { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } } }
            for c in web.colors { data.append(contentsOf: [c.x, c.y, c.z]) }
            while data.count % 4 != 0 { data.append(0) }
            for i in model + ceil { withUnsafeBytes(of: i.littleEndian) { data.append(contentsOf: $0) } }
            try data.base64EncodedString().write(to: dir.appendingPathComponent("mesh.b64.txt"), atomically: true, encoding: .ascii)
            meshInfo = ["file": "mesh.b64.txt", "vertices": web.positions.count, "triangles": model.count / 3,
                        "ceiling_triangles": ceil.count / 3]
        }

        // What the app already knows about the scan, for the page to start from.
        let measured = library.measurements(for: s)
        let seed: [String: Any] = [
            "names": names,
            "products": library.products(for: s).map { ["spot": $0.location, "product": $0.product, "qty": $0.qty] },
            "measured": measured.confirmed.mapValues { Double($0) },
            "measures": measured.custom.map { ["label": $0.label, "a": $0.a.map { Double($0) }, "b": $0.b.map { Double($0) },
                                              "length": Double($0.length), "confirmed": $0.confirmed.map { Double($0) } as Any] },
        ]
        let twin: [String: Any] = [
            "name": s.name, "date": ISO8601DateFormatter().string(from: s.date), "units": "imperial",
            "floor_y": Double(floorY), "ceiling_y": Double(ceilingY), "centre": f3(centre),
            "bounds": [f3(ends.reduce(ends.first ?? .zero) { simd_min($0, $1) }), f3(ends.reduce(ends.first ?? .zero) { simd_max($0, $1) })],
            "walls": walls, "openings": openings, "objects": objects, "floor": floor, "photos": photos,
            "mesh": meshInfo, "seed": seed, "processing": ["made_by": "RoomScan app"],
        ]
        try JSONSerialization.data(withJSONObject: twin).write(to: dir.appendingPathComponent("twin.json"))

        // Zip the folder (iOS zips a folder read "for uploading").
        var made: URL?
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &coordError) { zip in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent("\(s.id)-twin.zip")
            do {
                try? FileManager.default.removeItem(at: dest)
                try FileManager.default.copyItem(at: zip, to: dest)
                made = dest
            } catch { failure = error }
        }
        if let coordError { throw coordError }
        if let failure { throw failure }
        guard let made else { throw CocoaError(.fileWriteUnknown) }
        return made
    }
}
