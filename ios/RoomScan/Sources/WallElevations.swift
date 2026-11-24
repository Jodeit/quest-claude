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
        autoreleasepool {
            if let floor = renderFloor(room, occluders: occluders, views: views, to: dir),
               let data = try? JSONEncoder().encode(floor) {
                try? data.write(to: dir.appendingPathComponent("floor.json"))
            }
        }
        return made
    }

    /// The floor from above: where it lies (ARKit x and z) and the image of it.
    struct FloorImage: Codable, Hashable {
        var file: String
        var minX, minZ, maxX, maxZ, y: Float
    }

    static func loadFloor(from dir: URL) -> (FloorImage, URL)? {
        guard let data = try? Data(contentsOf: dir.appendingPathComponent("floor.json")),
              let f = try? JSONDecoder().decode(FloorImage.self, from: data) else { return nil }
        return (f, dir.appendingPathComponent(f.file))
    }

    /// The frames projected onto the floor, seen from above: a PNG, transparent outside RoomPlan's
    /// floor outline, neutral under furniture (the dollhouse puts boxes there, and furniture smears).
    private static func renderFloor(_ room: CapturedRoom, occluders: Occluders, views: [View], to dir: URL) -> FloorImage? {
        guard let f = room.floors.first, f.polygonCorners.count > 2 else { return nil }
        let outline = f.polygonCorners.map { p -> SIMD2<Float> in
            let w = f.transform * SIMD4<Float>(p.x, p.y, p.z, 1)
            return SIMD2(w.x, w.z)
        }
        let y = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? f.transform.columns.3.y
        let lo = outline.dropFirst().reduce(outline[0]) { simd_min($0, $1) } - 0.05
        let hi = outline.dropFirst().reduce(outline[0]) { simd_max($0, $1) } + 0.05
        // Frames looking down, most downward first.
        let chosen = views.filter { $0.forward.y < -0.2 }.sorted { $0.forward.y < $1.forward.y }
            .prefix(framesPerWall).compactMap { Bitmap($0) }
        guard !chosen.isEmpty else { return nil }
        struct Footprint { var c, ax, az: SIMD2<Float>; var hx, hz: Float }
        let footprints = room.objects.map { o -> Footprint in
            let t = o.transform
            func flat(_ v: simd_float4) -> SIMD2<Float> {
                let h = SIMD2(v.x, v.z), l = simd_length(h)
                return l > 1e-6 ? h / l : SIMD2(1, 0)
            }
            return Footprint(c: SIMD2(t.columns.3.x, t.columns.3.z), ax: flat(t.columns.0), az: flat(t.columns.2),
                             hx: o.dimensions.x / 2, hz: o.dimensions.z / 2)
        }
        func inside(_ q: SIMD2<Float>) -> Bool {
            var yes = false
            var j = outline.count - 1
            for i in outline.indices {
                let a = outline[i], b = outline[j]
                if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { yes.toggle() }
                j = i
            }
            return yes
        }
        let ppm = Swift.min(100, 1600 / Swift.max(hi.x - lo.x, hi.y - lo.y))
        let w = Swift.max(1, Int((hi.x - lo.x) * ppm)), h = Swift.max(1, Int((hi.y - lo.y) * ppm))
        var out = [UInt8](repeating: 0, count: w * h * 4)
        let up = SIMD3<Float>(0, 1, 0)
        for j in 0..<h {
            for i in 0..<w {
                let q = SIMD2(lo.x + (Float(i) + 0.5) / ppm, lo.y + (Float(j) + 0.5) / ppm)
                guard inside(q) else { continue }  // stays transparent
                let o = (j * w + i) * 4
                out[o + 3] = 255
                if footprints.contains(where: { fp in
                    let d = q - fp.c
                    return abs(simd_dot(d, fp.ax)) < fp.hx && abs(simd_dot(d, fp.az)) < fp.hz
                }) {
                    out[o] = 214; out[o + 1] = 208; out[o + 2] = 200
                    continue
                }
                let p = SIMD3(q.x, y, q.y)
                var rgb = SIMD3<Float>(0, 0, 0), total: Float = 0
                for bm in chosen {
                    guard let px = bm.view.project(p), bm.usable(px.0, px.1) else { continue }
                    let toCam = bm.view.position - p
                    let dist = simd_length(toCam)
                    let facing = simd_dot(toCam / dist, up)
                    guard facing > 0.15, !occluders.blocked(bm.view.position, p, skip: -1) else { continue }
                    let edge = Swift.min(1, Swift.min(Swift.min(px.0, bm.w - px.0), Swift.min(px.1, bm.h - px.1)) / (0.12 * bm.w))
                    var weight = facing * edge
                    weight = weight * weight
                    weight = weight * weight
                    weight = weight * weight / (dist * dist)
                    guard weight > 0 else { continue }
                    rgb += bm.sample(px.0, px.1) * weight
                    total += weight
                }
                let c = total > 0 ? rgb / total : SIMD3<Float>(236, 236, 236)
                out[o] = UInt8(Swift.min(255, c.x)); out[o + 1] = UInt8(Swift.min(255, c.y)); out[o + 2] = UInt8(Swift.min(255, c.z))
            }
        }
        let cs = CGColorSpace(name: CGColorSpace.sRGB)!
        let image: CGImage? = out.withUnsafeMutableBytes { buf in
            CGContext(data: buf.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                      space: cs, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)?.makeImage()
        }
        guard let image, let png = UIImage(cgImage: image).pngData(),
              (try? png.write(to: dir.appendingPathComponent("floor.png"))) != nil else { return nil }
        return FloorImage(file: "floor.png", minX: lo.x, minZ: lo.y, maxX: hi.x, maxZ: hi.y, y: y)
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
                    guard let px = bm.view.project(p), bm.usable(px.0, px.1) else { continue }
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
            let width = img.width, height = img.height, rowBytes = width * 4
            // Nearly black frames (lens covered, the first moment of a scan) spoil whatever they touch:
            // the one in the first real scan averaged 15 where the rest were 100+. (Low contrast is no
            // test: plain walls and ceilings are low-contrast and good.)
            var sum: Float = 0, n: Float = 0
            for y in Swift.stride(from: 0, to: height, by: 4) {
                for x in Swift.stride(from: 0, to: width, by: 4) {
                    let o = y * rowBytes + x * 4
                    sum += 0.299 * Float(px[o]) + 0.587 * Float(px[o + 1]) + 0.114 * Float(px[o + 2])
                    n += 1
                }
            }
            guard sum / n >= 40 else { return nil }
            // A fingertip over the lens shows as a pink blur along one edge. Skip any edge band (a fifth
            // of the frame) that's more than 8% skin-coloured; frames without one stayed under 5%.
            func skin(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Bool {
                var hits = 0, count = 0
                for y in Swift.stride(from: y0, to: y1, by: 3) {
                    for x in Swift.stride(from: x0, to: x1, by: 3) {
                        let o = y * rowBytes + x * 4
                        let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
                        if r > 120, r - g > 35, abs(g - b) < 30, r - b > 35 { hits += 1 }
                        count += 1
                    }
                }
                return count > 0 && Float(hits) / Float(count) > 0.08
            }
            let bw = width / 5, bh = height / 5
            cutRight = skin(width - bw, width, 0, height) ? Float(width - bw) : nil
            cutLeft = skin(0, bw, 0, height) ? Float(bw) : nil
            cutTop = skin(0, width, 0, bh) ? Float(bh) : nil
            cutBottom = skin(0, width, height - bh, height) ? Float(height - bh) : nil
            self.view = view
            pixels = px
            w = view.width
            h = view.height
            stride = rowBytes
        }

        private let cutRight, cutLeft, cutTop, cutBottom: Float?

        /// False where a fingertip was found along that edge.
        func usable(_ x: Float, _ y: Float) -> Bool {
            if let c = cutRight, x > c { return false }
            if let c = cutLeft, x < c { return false }
            if let c = cutTop, y < c { return false }
            if let c = cutBottom, y > c { return false }
            return true
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
