import CoreGraphics
import Foundation
import RoomPlan
import UIKit
import simd

/// A storage unit seen straight on, to scale, with the shelves found in it. RoomPlan gives a unit as
/// one box; projecting the kept frames onto its front face turns every shelf edge into a horizontal
/// line at its true height, which is what's measured here. Estimates, for a tape to confirm.
struct StorageFront: Codable, Hashable {
    var object: Int          // index into the room's objects
    var file: String         // the front image, in the elevations folder
    var width, height, depth: Float
    var flipped: Bool        // the front is the box's -z face
    var shelves: [Float]     // edges found, metres up from the unit's bottom, lowest first

    /// The clear openings between shelf edges (and the unit's top and bottom), lowest first.
    var openings: [Float] {
        let edges = [0] + shelves + [height]
        return zip(edges.dropFirst(), edges).map { $0 - $1 }.filter { $0 > 0.05 }
    }
}

extension WallElevations {
    /// Front images and shelves for every storage unit, saved as storage.json beside the elevations.
    static func renderStorageFronts(_ room: CapturedRoom, views: [View], occluders: Occluders, to dir: URL) {
        var made: [StorageFront] = []
        for (i, o) in room.objects.enumerated() where o.category == .storage {
            autoreleasepool {
                if let f = renderFront(i, o, views: views, occluders: occluders, to: dir) { made.append(f) }
            }
        }
        if let data = try? JSONEncoder().encode(made) {
            try? data.write(to: dir.appendingPathComponent("storage.json"))
        }
    }

    static func loadStorageFronts(from dir: URL) -> [(StorageFront, URL)] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("storage.json")),
              let list = try? JSONDecoder().decode([StorageFront].self, from: data) else { return [] }
        return list.map { ($0, dir.appendingPathComponent($0.file)) }
    }

    private static func renderFront(_ index: Int, _ o: CapturedRoom.Object, views: [View], occluders: Occluders,
                                    to dir: URL) -> StorageFront? {
        let t = o.transform
        let c = simd_make_float3(t.columns.3)
        let x = simd_normalize(simd_make_float3(t.columns.0)), z = simd_normalize(simd_make_float3(t.columns.2))
        let width = o.dimensions.x, height = o.dimensions.y, depth = o.dimensions.z
        guard width > 0.15, height > 0.15 else { return nil }
        // The front is the side the camera mostly was.
        var side: Float = 0
        for v in views where simd_distance(v.position, c) < 8 { side += simd_dot(v.position - c, z) > 0 ? 1 : -1 }
        let flipped = side < 0
        let normal = flipped ? -z : z, along = flipped ? -x : x
        let front = c + normal * (depth / 2)
        let up = SIMD3<Float>(0, 1, 0)
        func world(_ u: Float, _ v: Float) -> SIMD3<Float> { front + along * (u - width / 2) + up * (v - height / 2) }

        let probes = [world(width / 2, height / 2), world(width * 0.15, height * 0.15), world(width * 0.85, height * 0.85)]
        var scored: [(View, Float)] = []
        for v in views {
            guard simd_dot(v.position - front, normal) > 0.2 else { continue }
            let look = simd_dot(v.forward, -normal)
            guard look > 0.3 else { continue }
            let seen = probes.filter { v.project($0) != nil }.count
            if seen > 0 { scored.append((v, Float(seen) * look)) }
        }
        let chosen = scored.sorted { $0.1 > $1.1 }.prefix(framesPerWall).compactMap { Bitmap($0.0) }
        guard !chosen.isEmpty else { return nil }

        let ppm = Swift.min(300, 1200 / Swift.max(width, height))
        let w = Swift.max(1, Int(width * ppm)), h = Swift.max(1, Int(height * ppm))
        var out = [UInt8](repeating: 255, count: w * h * 4)
        var lum = [Float](repeating: 236, count: w * h)
        for j in 0..<h {
            let v = (Float(h - j) - 0.5) / ppm
            for i in 0..<w {
                let p = world((Float(i) + 0.5) / ppm, v)
                var rgb = SIMD3<Float>(0, 0, 0), total: Float = 0
                for bm in chosen {
                    guard let px = bm.view.project(p), bm.usable(px.0, px.1) else { continue }
                    let toCam = bm.view.position - p
                    let dist = simd_length(toCam)
                    let facing = simd_dot(toCam / dist, normal)
                    guard facing > 0.3, !occluders.blocked(bm.view.position, p, skip: -1) else { continue }
                    let edge = Swift.min(1, Swift.min(Swift.min(px.0, bm.w - px.0), Swift.min(px.1, bm.h - px.1)) / (0.12 * bm.w))
                    var weight = facing * edge
                    weight = weight * weight
                    weight = weight * weight
                    weight = weight * weight / (dist * dist)
                    guard weight > 0 else { continue }
                    rgb += bm.sample(px.0, px.1) * weight
                    total += weight
                }
                let color = total > 0 ? rgb / total : SIMD3<Float>(236, 236, 236)
                let o = (j * w + i) * 4
                out[o] = UInt8(Swift.min(255, color.x)); out[o + 1] = UInt8(Swift.min(255, color.y))
                out[o + 2] = UInt8(Swift.min(255, color.z))
                lum[j * w + i] = 0.299 * color.x + 0.587 * color.y + 0.114 * color.z
            }
        }

        // Shelf edges: rows where brightness jumps between one row and the next across a quarter or
        // more of the width, at least 8 cm apart. (Tried on a real closet: shelf fronts, the tops
        // and bottoms of units.)
        var strong = [Float](repeating: 0, count: h)
        for j in 0..<(h - 1) {
            var n = 0
            for i in 0..<w where abs(lum[(j + 1) * w + i] - lum[j * w + i]) > 18 { n += 1 }
            strong[j] = Float(n) / Float(w)
        }
        var profile = [Float](repeating: 0, count: h)
        for j in 0..<h {
            let lo = Swift.max(0, j - 2), hi = Swift.min(h - 1, j + 2)
            profile[j] = strong[lo...hi].reduce(0, +) / 5
        }
        var peaks: [Int] = []
        for j in profile.indices.sorted(by: { profile[$0] > profile[$1] }) {
            guard profile[j] >= 0.25 else { break }
            if peaks.allSatisfy({ abs($0 - j) > Int(0.08 * ppm) }) { peaks.append(j) }
        }
        // Edges right at the unit's top or bottom are its own edges, not shelves.
        let margin = Int(0.03 * ppm)
        let shelves = peaks.filter { $0 > margin && $0 < h - margin }.map { Float(h - $0) / ppm }.sorted()

        let name = "S\(index + 1).jpg"
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let image: CGImage? = out.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        guard let image, let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.85),
              (try? jpeg.write(to: dir.appendingPathComponent(name))) != nil else { return nil }
        return StorageFront(object: index, file: name, width: width, height: height, depth: depth,
                            flipped: flipped, shelves: shelves)
    }
}
