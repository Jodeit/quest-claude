import CoreGraphics
import Foundation
import ImageIO
import RoomPlan
import simd

/// The scan as a Gaussian-splat training set: every kept frame with its camera pose and lens, in
/// nerfstudio's `transforms.json` layout (which gsplat, nerfstudio, Brush and most splat trainers
/// read), plus a coloured point cloud to start the splats from. ARKit already knows where every frame
/// was taken, so a trainer skips structure-from-motion, the slow step that fails most often.
/// `spatial/splat/` trains it on a free cloud GPU (Kaggle or Colab).
///
/// Conventions, as nerfstudio expects them: `transform_matrix` is camera-to-world, as rows, with the
/// camera looking down its -z and y up (ARKit's own convention, so poses go in unchanged); images
/// are the camera sensor's landscape frames, unrotated, which is what the intrinsics describe; world
/// is RoomPlan's (metres, y up), the same as the mesh, the twin and every other export.
enum SplatExport {
    /// Most starting points written: plenty to start a room from, small enough to send.
    static let maxPoints = 150_000

    static func make(_ s: SavedScan, library: ScanLibrary) throws -> URL {
        let frames = library.keyframes(for: s).filter { FileManager.default.fileExists(atPath: $0.1.path) }
        guard !frames.isEmpty else { throw CocoaError(.fileNoSuchFile) }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("splat-\(s.id)", isDirectory: true)
        try? FileManager.default.removeItem(at: dir)
        let images = dir.appendingPathComponent("images", isDirectory: true)
        try FileManager.default.createDirectory(at: images, withIntermediateDirectories: true)

        var list: [[String: Any]] = []
        for (k, url) in frames {
            try FileManager.default.copyItem(at: url, to: images.appendingPathComponent(k.file))
            let p = k.pose
            let rows = (0..<4).map { r in [p.columns.0[r], p.columns.1[r], p.columns.2[r], p.columns.3[r]].map(Double.init) }
            var f: [String: Any] = ["file_path": "images/\(k.file)", "transform_matrix": rows,
                                    "fl_x": Double(k.fx), "fl_y": Double(k.fy), "cx": Double(k.cx), "cy": Double(k.cy),
                                    "w": k.width, "h": k.height,
                                    // Ours, ignored by trainers: which pass took it, and how sharp it was.
                                    "pass": k.file.hasPrefix("M") ? "photo-real" : "room"]
            if let sharp = k.sharpness { f["sharpness"] = Double(sharp) }
            if let stop = k.stop { f["stop"] = stop }
            list.append(f)
        }

        // Starting points: the LiDAR mesh when the scan has one, else RoomPlan's surfaces on a grid.
        let room = (try? library.json(for: s)).flatMap { try? JSONDecoder().decode(CapturedRoom.self, from: $0) }
        var points: [SIMD3<Float>]
        var source: String
        if let mesh = library.mesh(for: s), !mesh.positions.isEmpty {
            let step = Swift.max(1, mesh.positions.count / maxPoints)
            points = Swift.stride(from: 0, to: mesh.positions.count, by: step).map { mesh.positions[$0] }
            source = "lidar mesh"
        } else if let room {
            points = surfacePoints(room)
            source = "roomplan surfaces"
        } else {
            points = []
            source = "none"
        }
        let colours = colour(points, frames: frames)
        var transforms: [String: Any] = [
            "camera_model": "OPENCV", "k1": 0, "k2": 0, "p1": 0, "p2": 0,
            "frames": list,
            "roomscan": ["name": s.name, "id": s.id, "date": ISO8601DateFormatter().string(from: s.date),
                         "world": "RoomPlan: metres, y up", "points": source, "made_by": "RoomScan app"] as [String: Any],
        ]
        if !points.isEmpty {
            try writePLY(points, colours, to: dir.appendingPathComponent("points.ply"))
            transforms["ply_file_path"] = "points.ply"
        }
        if let room {
            let floorY = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0
            let ceilingY = room.walls.map { $0.transform.columns.3.y + $0.dimensions.y / 2 }.max() ?? floorY + 2.4
            var info = transforms["roomscan"] as! [String: Any]
            info["floor_y"] = Double(floorY)
            info["ceiling_y"] = Double(ceilingY)
            transforms["roomscan"] = info
        }
        let json = try JSONSerialization.data(withJSONObject: transforms, options: [.prettyPrinted, .sortedKeys])
        try json.write(to: dir.appendingPathComponent("transforms.json"))
        try ("RoomScan splat training set: \(s.name), \(frames.count) frames, \(points.count) starting points (\(source)).\n"
             + "Train it with spatial/splat/RoomScan_splat.ipynb in quest-claude (Kaggle or Colab, free GPU),\n"
             + "or any trainer that reads nerfstudio's transforms.json.\n")
            .write(to: dir.appendingPathComponent("README.txt"), atomically: true, encoding: .utf8)

        return try zipFolder(dir, as: "\(s.id)-splat.zip")
    }

    /// Points every 8 cm on the walls and floor, and on the faces of each object's box.
    private static func surfacePoints(_ room: CapturedRoom) -> [SIMD3<Float>] {
        let step: Float = 0.08
        var out: [SIMD3<Float>] = []
        for w in room.walls {
            let f = WallFrame(w, flipped: false)
            for u in Swift.stride(from: Float(0), through: f.width, by: step) {
                for v in Swift.stride(from: Float(0), through: f.height, by: step) { out.append(f.world(u: u, v: v)) }
            }
        }
        if !room.walls.isEmpty {
            var lo = SIMD3<Float>(repeating: .greatestFiniteMagnitude), hi = -lo
            for w in room.walls {
                let c = simd_make_float3(w.transform.columns.3), x = simd_make_float3(w.transform.columns.0) * w.dimensions.x / 2
                lo = simd_min(lo, simd_min(c - x, c + x)); hi = simd_max(hi, simd_max(c - x, c + x))
            }
            let floorY = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0
            for x in Swift.stride(from: lo.x, through: hi.x, by: step) {
                for z in Swift.stride(from: lo.z, through: hi.z, by: step) { out.append(SIMD3(x, floorY, z)) }
            }
        }
        for o in room.objects {
            let t = o.transform, h = o.dimensions / 2
            let c = simd_make_float3(t.columns.3)
            let ax = [simd_make_float3(t.columns.0), simd_make_float3(t.columns.1), simd_make_float3(t.columns.2)]
            for face in 0..<6 {
                let n = face / 2, sign: Float = face % 2 == 0 ? -1 : 1
                let a = (n + 1) % 3, b = (n + 2) % 3
                for i in Swift.stride(from: -h[a], through: h[a], by: step) {
                    for j in Swift.stride(from: -h[b], through: h[b], by: step) {
                        out.append(c + ax[n] * (sign * h[n]) + ax[a] * i + ax[b] * j)
                    }
                }
            }
        }
        if out.count > maxPoints {
            let keep = maxPoints
            out = (0..<keep).map { out[$0 * out.count / keep] }
        }
        return out
    }

    /// Each point's colour from the nearest frame that sees it (no occlusion test: these only start
    /// the splats off, and training corrects them). Frames are decoded at 200 pixels to keep memory
    /// small; points no frame sees are mid gray.
    private static func colour(_ points: [SIMD3<Float>], frames: [(Keyframe, URL)]) -> [SIMD3<UInt8>] {
        struct Small { let inverse: simd_float4x4; let fx, fy, cx, cy: Float; let w, h: Int; let px: [UInt8] }
        let cams: [Small] = frames.compactMap { k, url in
            guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [kCGImageSourceCreateThumbnailFromImageAlways: true,
                                                                       kCGImageSourceThumbnailMaxPixelSize: 200] as CFDictionary)
            else { return nil }
            let w = img.width, h = img.height
            var px = [UInt8](repeating: 0, count: w * h * 4)
            let ok = px.withUnsafeMutableBytes { raw -> Bool in
                guard let ctx = CGContext(data: raw.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                          space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
                return true
            }
            guard ok, k.width > 0 else { return nil }
            let s = Float(w) / Float(k.width)
            return Small(inverse: k.pose.inverse, fx: k.fx * s, fy: k.fy * s, cx: k.cx * s, cy: k.cy * s, w: w, h: h, px: px)
        }
        return points.map { p in
            var best: (depth: Float, colour: SIMD3<UInt8>)?
            for c in cams {
                let q = c.inverse * SIMD4(p, 1)
                let depth = -q.z
                guard depth > 0.2, depth < (best?.depth ?? 6) else { continue }
                let x = c.cx + c.fx * q.x / depth, y = c.cy - c.fy * q.y / depth
                guard x >= 0, y >= 0, x < Float(c.w), y < Float(c.h) else { continue }
                let o = (Int(y) * c.w + Int(x)) * 4
                best = (depth, SIMD3(c.px[o], c.px[o + 1], c.px[o + 2]))
            }
            return best?.colour ?? SIMD3(128, 128, 128)
        }
    }

    /// Binary little-endian PLY: x, y, z as floats, red, green, blue as bytes.
    private static func writePLY(_ points: [SIMD3<Float>], _ colours: [SIMD3<UInt8>], to url: URL) throws {
        var data = Data(("ply\nformat binary_little_endian 1.0\nelement vertex \(points.count)\n"
                         + "property float x\nproperty float y\nproperty float z\n"
                         + "property uchar red\nproperty uchar green\nproperty uchar blue\nend_header\n").utf8)
        data.reserveCapacity(data.count + points.count * 15)
        for (p, c) in Swift.zip(points, colours) {
            for v in [p.x, p.y, p.z] { withUnsafeBytes(of: v.bitPattern.littleEndian) { data.append(contentsOf: $0) } }
            data.append(contentsOf: [c.x, c.y, c.z])
        }
        try data.write(to: url)
    }

    /// iOS zips a folder that's read "for uploading".
    private static func zipFolder(_ dir: URL, as name: String) throws -> URL {
        var made: URL?
        var failure: Error?
        var coordError: NSError?
        NSFileCoordinator().coordinate(readingItemAt: dir, options: .forUploading, error: &coordError) { zip in
            let dest = FileManager.default.temporaryDirectory.appendingPathComponent(name)
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
