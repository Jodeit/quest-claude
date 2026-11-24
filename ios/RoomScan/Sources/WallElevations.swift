import CoreGraphics
import Foundation
import ImageIO
import RoomPlan
import UIKit
import simd

/// One wall seen straight on from inside the room: the keyframes projected onto the wall's plane.
/// Flat things on the wall land true to scale; things that stand out from it (cabinet fronts,
/// furniture) are smeared a little, since every frame sees them from a different place.
struct Elevation: Codable, Hashable {
    var wall: Int          // index into the room's walls: W1 is 0
    var file: String       // in the scan's elevations folder
    var flipped: Bool      // the room is on the wall's -z side
}

/// A wall's own coordinates, as seen from the room: u metres from the left end, v metres up from
/// the bottom, depth metres out from the wall toward the room.
struct WallFrame {
    let center: SIMD3<Float>
    let along: SIMD3<Float>   // to the viewer's right
    let normal: SIMD3<Float>  // toward the room
    let width: Float
    let height: Float

    init(_ wall: CapturedRoom.Surface, flipped: Bool) {
        let t = wall.transform
        center = simd_make_float3(t.columns.3)
        let x = Self.horizontal(t.columns.0, fallback: SIMD3(1, 0, 0))
        let z = Self.horizontal(t.columns.2, fallback: SIMD3(0, 0, 1))
        // Looking at the wall from its +z side, +x is to the right; from the -z side, -x is.
        along = flipped ? -x : x
        normal = flipped ? -z : z
        width = wall.dimensions.x
        height = wall.dimensions.y
    }

    var bottom: Float { center.y - height / 2 }

    func world(u: Float, v: Float) -> SIMD3<Float> {
        center + along * (u - width / 2) + SIMD3(0, v - height / 2, 0)
    }

    func local(_ p: SIMD3<Float>) -> (u: Float, v: Float, depth: Float) {
        let d = p - center
        return (simd_dot(d, along) + width / 2, p.y - bottom, simd_dot(d, normal))
    }

    private static func horizontal(_ v: simd_float4, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let h = SIMD3<Float>(v.x, 0, v.z)
        let l = simd_length(h)
        return l > 1e-6 ? h / l : fallback
    }
}

enum WallElevations {
    private static let pixelsPerMetre: Float = 200
    private static let maxSide: Float = 1800
    private static let framesPerWall = 30

    /// A flat rectangle standing upright: a wall, or a door/window/opening (a hole in one).
    private struct Panel {
        let c, x, z: SIMD3<Float>  // centre; horizontal along and across, unit length
        let halfW, halfH: Float
        var holes: [Panel] = []

        init(_ s: CapturedRoom.Surface) {
            let t = s.transform
            c = simd_make_float3(t.columns.3)
            x = Self.flat(t.columns.0, SIMD3(1, 0, 0))
            z = Self.flat(t.columns.2, SIMD3(0, 0, 1))
            halfW = s.dimensions.x / 2
            halfH = s.dimensions.y / 2
        }

        private static func flat(_ v: simd_float4, _ fallback: SIMD3<Float>) -> SIMD3<Float> {
            let h = SIMD3<Float>(v.x, 0, v.z), l = simd_length(h)
            return l > 1e-6 ? h / l : fallback
        }
    }

    /// The room's walls with their holes, for asking whether a wall stands between a camera and a point.
    private struct Occluders {
        var walls: [Panel]

        init(_ room: CapturedRoom) {
            let holes = (room.doors + room.windows + room.openings).map(Panel.init)
            walls = room.walls.map { w in
                var p = Panel(w)
                p.holes = holes.filter { abs(simd_dot($0.c - p.c, p.z)) < 0.3 }
                return p
            }
        }

        /// True if another wall (not `skip`) crosses the line from the camera to the point, other
        /// than through a door, window or opening in it.
        func blocked(_ cam: SIMD3<Float>, _ p: SIMD3<Float>, skip: Int) -> Bool {
            let d = p - cam
            for (j, w) in walls.enumerated() where j != skip {
                let den = simd_dot(d, w.z)
                guard abs(den) > 1e-6 else { continue }
                let t = simd_dot(w.c - cam, w.z) / den
                guard t > 0.02, t < 0.97 else { continue }
                let hit = cam + d * t
                let r = hit - w.c
                guard abs(simd_dot(r, w.x)) < w.halfW - 0.03, abs(r.y) < w.halfH else { continue }
                let throughHole = w.holes.contains { h in
                    abs(simd_dot(hit - h.c, h.x)) < h.halfW && abs(hit.y - h.c.y) < h.halfH
                }
                if !throughHole { return true }
            }
            return false
        }
    }

    /// Makes elevations/<W#>.jpg and elevations.json in `dir` (replacing what was there) and
    /// returns what it made. Slow-ish (a second or so a wall): call it off the main thread.
    static func render(_ room: CapturedRoom, frames: [(Keyframe, URL)], to dir: URL) -> [Elevation] {
        guard !frames.isEmpty else { return [] }
        try? FileManager.default.removeItem(at: dir)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let views = frames.map { View($0.0, url: $0.1) }
        let occluders = Occluders(room)
        var made: [Elevation] = []
        for (i, wall) in room.walls.enumerated() {
            autoreleasepool {
                if let e = renderWall(i, wall, room: room, occluders: occluders, views: views, to: dir) {
                    made.append(e)
                }
            }
        }
        if let data = try? JSONEncoder().encode(made) {
            try? data.write(to: dir.appendingPathComponent("elevations.json"))
        }
        return made
    }

    /// Reads what render made, with the files' locations.
    static func load(from dir: URL) -> [(Elevation, URL)] {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("elevations.json")),
              let list = try? JSONDecoder().decode([Elevation].self, from: data) else { return [] }
        return list.map { ($0, dir.appendingPathComponent($0.file)) }
    }

    private static func renderWall(_ index: Int, _ wall: CapturedRoom.Surface, room: CapturedRoom,
                                   occluders: Occluders, views: [View], to dir: URL) -> Elevation? {
        guard wall.dimensions.x > 0.2, wall.dimensions.y > 0.2 else { return nil }
        // The room is on whichever side the camera mostly was.
        let c = simd_make_float3(wall.transform.columns.3)
        let z = simd_make_float3(wall.transform.columns.2)
        var side: Float = 0
        for v in views where simd_distance(v.position, c) < 8 { side += simd_dot(v.position - c, z) > 0 ? 1 : -1 }
        let flipped = side < 0
        let f = WallFrame(wall, flipped: flipped)

        // The frames that see this wall best: from the room side, looking at it, covering most of it.
        let spots: [(Float, Float)] = [(0.5, 0.5), (0.15, 0.15), (0.85, 0.15), (0.15, 0.85), (0.85, 0.85)]
        let probes = spots.map { f.world(u: $0.0 * f.width, v: $0.1 * f.height) }
        var scored: [(View, Float)] = []
        for v in views {
            guard simd_dot(v.position - c, f.normal) > 0.2 else { continue }
            let look = simd_dot(v.forward, -f.normal)
            guard look > 0.3 else { continue }
            let seen = probes.filter { v.project($0) != nil }.count
            if seen > 0 { scored.append((v, Float(seen) * look)) }
        }
        let chosen = scored.sorted { $0.1 > $1.1 }.prefix(framesPerWall).compactMap { Bitmap($0.0) }
        guard !chosen.isEmpty else { return nil }

        // Storage, appliances and the like standing against the wall: look at their front face rather
        // than the wall behind, so shelves and drawers land where they are instead of smearing.
        struct Front { var u0, u1, v0, v1, depth: Float }
        var fronts: [Front] = []
        for o in room.objects {
            let t = o.transform
            let oc = simd_make_float3(t.columns.3)
            let ax = simd_make_float3(t.columns.0) * (o.dimensions.x / 2)
            let az = simd_make_float3(t.columns.2) * (o.dimensions.z / 2)
            let corners = [oc - ax - az, oc + ax - az, oc + ax + az, oc - ax + az].map { f.local($0) }
            let us = corners.map { $0.u }, depths = corners.map { $0.depth }
            guard let near = depths.min(), let far = depths.max(), near < 0.4, near > -0.3,
                  let u0 = us.min(), let u1 = us.max(), u1 > 0, u0 < f.width else { continue }
            let v0 = oc.y - o.dimensions.y / 2 - f.bottom
            fronts.append(Front(u0: u0, u1: u1, v0: v0, v1: v0 + o.dimensions.y, depth: far))
        }

        let ppm = Swift.min(pixelsPerMetre, maxSide / Swift.max(f.width, f.height))
        let w = Swift.max(1, Int(f.width * ppm)), h = Swift.max(1, Int(f.height * ppm))
        var out = [UInt8](repeating: 255, count: w * h * 4)
        for j in 0..<h {
            let v = (Float(h - j) - 0.5) / ppm
            for i in 0..<w {
                let u = (Float(i) + 0.5) / ppm
                var p = f.world(u: u, v: v)
                if let front = fronts.first(where: { u >= $0.u0 && u <= $0.u1 && v >= $0.v0 && v <= $0.v1 }) {
                    p += f.normal * front.depth
                }
                var rgb = SIMD3<Float>(0, 0, 0), total: Float = 0
                for bm in chosen {
                    guard let px = bm.view.project(p) else { continue }
                    let x = px.0, y = px.1
                    let toCam = bm.view.position - p
                    let dist = simd_length(toCam)
                    let facing = simd_dot(toCam / dist, f.normal)
                    guard facing > 0.15, !occluders.blocked(bm.view.position, p, skip: index) else { continue }
                    // Prefer head-on, close, and away from the frame's edges (where seams would show).
                    let edge = Swift.min(1, Swift.min(Swift.min(x, bm.w - x), Swift.min(y, bm.h - y)) / (0.12 * bm.w))
                    // To the 8th power: the best frame for each spot wins, so there are fewer double images.
                    var weight = facing * edge
                    weight = weight * weight
                    weight = weight * weight
                    weight = weight * weight / (dist * dist)
                    guard weight > 0 else { continue }
                    rgb += bm.sample(x, y) * weight
                    total += weight
                }
                let o = (j * w + i) * 4
                if total > 0 {
                    let color = rgb / total
                    out[o] = UInt8(Swift.min(255, color.x))
                    out[o + 1] = UInt8(Swift.min(255, color.y))
                    out[o + 2] = UInt8(Swift.min(255, color.z))
                } else {
                    out[o] = 236; out[o + 1] = 236; out[o + 2] = 236  // no frame saw this part
                }
            }
        }

        let name = "W\(index + 1).jpg"
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let image: CGImage? = out.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: cs, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)?.makeImage()
        }
        guard let image, let jpeg = UIImage(cgImage: image).jpegData(compressionQuality: 0.82),
              (try? jpeg.write(to: dir.appendingPathComponent(name))) != nil else { return nil }
        return Elevation(wall: index, file: name, flipped: flipped)
    }

    /// A keyframe's camera: where it was, where it looked, and how it maps world points to pixels.
    private struct View {
        let url: URL
        let inverse: simd_float4x4
        let position: SIMD3<Float>
        let forward: SIMD3<Float>
        let fx, fy, cx, cy: Float
        let width, height: Float

        init(_ k: Keyframe, url: URL) {
            self.url = url
            let pose = k.pose
            inverse = pose.inverse
            position = simd_make_float3(pose.columns.3)
            forward = simd_normalize(-simd_make_float3(pose.columns.2))
            fx = k.fx; fy = k.fy; cx = k.cx; cy = k.cy
            width = Float(k.width); height = Float(k.height)
        }

        /// The pixel a world point lands on (ARKit camera: x right, y up, looking down -z), if in view.
        func project(_ p: SIMD3<Float>) -> (Float, Float)? {
            let c = inverse * SIMD4(p, 1)
            let depth = -c.z
            guard depth > 0.1 else { return nil }
            let x = cx + fx * c.x / depth, y = cy - fy * c.y / depth
            guard x >= 0, y >= 0, x < width - 1, y < height - 1 else { return nil }
            return (x, y)
        }
    }

    /// A keyframe decoded to RGBA, for sampling.
    private struct Bitmap {
        let view: View
        let pixels: [UInt8]
        let w: Float, h: Float
        private let stride: Int

        init?(_ view: View) {
            guard let src = CGImageSourceCreateWithURL(view.url as CFURL, nil),
                  let img = CGImageSourceCreateImageAtIndex(src, 0, nil),
                  img.width == Int(view.width), img.height == Int(view.height) else { return nil }
            var px = [UInt8](repeating: 0, count: img.width * img.height * 4)
            let cs = CGColorSpace(name: CGColorSpace.sRGB)!
            let ok = px.withUnsafeMutableBytes { buf -> Bool in
                guard let ctx = CGContext(data: buf.baseAddress, width: img.width, height: img.height,
                                          bitsPerComponent: 8, bytesPerRow: img.width * 4, space: cs,
                                          bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return false }
                ctx.draw(img, in: CGRect(x: 0, y: 0, width: img.width, height: img.height))
                return true
            }
            guard ok else { return nil }
            self.view = view
            pixels = px
            w = view.width
            h = view.height
            stride = img.width * 4
        }

        /// Bilinear, 0-255 per channel.
        func sample(_ x: Float, _ y: Float) -> SIMD3<Float> {
            let x0 = Int(x), y0 = Int(y)
            let fx = x - Float(x0), fy = y - Float(y0)
            func at(_ xi: Int, _ yi: Int) -> SIMD3<Float> {
                let o = yi * stride + xi * 4
                return SIMD3(Float(pixels[o]), Float(pixels[o + 1]), Float(pixels[o + 2]))
            }
            let top = at(x0, y0) * (1 - fx) + at(x0 + 1, y0) * fx
            let bottom = at(x0, y0 + 1) * (1 - fx) + at(x0 + 1, y0 + 1) * fx
            return top * (1 - fy) + bottom * fy
        }
    }
}
