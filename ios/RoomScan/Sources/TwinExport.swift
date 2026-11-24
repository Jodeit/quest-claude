import CoreGraphics
import CoreImage
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
                d["front"] = ["image": copy(url).map { $0 as Any } ?? NSNull(), "shelves": fr.shelves.map { Double($0) },
                              "openings_top_first": fr.openings.reversed().map { Double($0) },
                              "width": Double(fr.width), "height": Double(fr.height), "depth": Double(fr.depth),
                              "confirmed": fr.confirmed.map { $0 as Any } ?? NSNull()]
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
            let frames = library.keyframes(for: s)
            let web = mesh.texturedExport(frames: frames, ceilingY: ceilingY,
                                          bounds: (SIMD3(lo.x - 0.4, floorY - 0.3, lo.z - 0.4), SIMD3(hi.x + 0.4, ceilingY + 0.3, hi.z + 0.4)))
            let tri = web.choice.count
            // Model triangles first, then ceiling; grouped by frame within each.
            let order = (0..<tri).sorted { a, b in
                web.ceiling[a] != web.ceiling[b] ? !web.ceiling[a] : web.choice[a] < web.choice[b]
            }
            // Each frame used, at 960 px with its exposure correction baked in.
            let fdir = img.appendingPathComponent("f", isDirectory: true)
            try FileManager.default.createDirectory(at: fdir, withIntermediateDirectories: true)
            let context = CIContext()
            var names = [Int: String]()
            for k in Set(web.choice) where k >= 0 {
                guard var image = CIImage(contentsOf: frames[k].1) else { continue }
                let g = web.gains[k]
                image = image.applyingFilter("CIColorMatrix", parameters: [
                    "inputRVector": CIVector(x: CGFloat(g.x), y: 0, z: 0, w: 0),
                    "inputGVector": CIVector(x: 0, y: CGFloat(g.y), z: 0, w: 0),
                    "inputBVector": CIVector(x: 0, y: 0, z: CGFloat(g.z), w: 0)])
                if image.extent.width > 960 {
                    image = image.applyingFilter("CILanczosScaleTransform", parameters: [kCIInputScaleKey: 960 / image.extent.width])
                }
                let name = (frames[k].0.file as NSString).deletingPathExtension + ".jpg"
                let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                guard let jpeg = context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                            options: [quality: 0.82]) else { continue }
                try jpeg.write(to: fdir.appendingPathComponent(name))
                names[k] = "img/f/" + name
            }
            var groups: [[String: Any]] = []
            var i = 0
            while i < order.count {
                let k = web.choice[order[i]], c = web.ceiling[order[i]]
                var j = i
                while j < order.count, web.choice[order[j]] == k, web.ceiling[order[j]] == c { j += 1 }
                var g: [String: Any] = ["start": i, "count": j - i, "ceiling": c]
                if let name = names[k] { g["image"] = name } else { g["image"] = NSNull() }
                groups.append(g)
                i = j
            }
            // RTW2: count, box (min, size), per corner u16 positions across the box and u16 texture coordinates.
            let cs = order.flatMap { t in (0..<3).map { web.corners[t * 3 + $0] } }
            let us = order.flatMap { t in (0..<3).map { web.uv[t * 3 + $0] } }
            let bmin = cs.reduce(cs.first ?? .zero) { simd_min($0, $1) }, bmax = cs.reduce(cs.first ?? .zero) { simd_max($0, $1) }
            let size = simd_max(bmax - bmin, SIMD3(repeating: 1e-6))
            var data = Data("RTW2".utf8)
            func put<T>(_ v: T) { withUnsafeBytes(of: v) { data.append(contentsOf: $0) } }
            put(UInt32(tri).littleEndian)
            for v in [bmin.x, bmin.y, bmin.z, size.x, size.y, size.z] { put(v.bitPattern.littleEndian) }
            func q(_ x: Float) -> UInt16 { UInt16(Swift.min(65535, Swift.max(0, (x * 65535).rounded()))) }
            for p in cs { let r = (p - bmin) / size; put(q(r.x).littleEndian); put(q(r.y).littleEndian); put(q(r.z).littleEndian) }
            for u in us { put(q(u.x).littleEndian); put(q(u.y).littleEndian) }
            try data.base64EncodedString().write(to: dir.appendingPathComponent("mesh.b64.txt"), atomically: true, encoding: .ascii)
            meshInfo = ["file": "mesh.b64.txt", "format": "RTW2", "triangles": web.ceiling.filter { !$0 }.count,
                        "ceiling_triangles": web.ceiling.filter { $0 }.count, "frames": names.count, "groups": groups]
        }

        // What the app already knows about the scan, for the page to start from.
        let measured = library.measurements(for: s)
        let seed: [String: Any] = [
            "names": names,
            "products": library.products(for: s).map { ["spot": $0.location, "product": $0.product, "qty": $0.qty] },
            "measured": measured.confirmed.mapValues { Double($0) },
            "measures": measured.custom.map { ["label": $0.label, "a": $0.a.map { Double($0) }, "b": $0.b.map { Double($0) },
                                              "length": Double($0.length), "confirmed": $0.confirmed.map { Double($0) as Any } ?? NSNull()] },
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
