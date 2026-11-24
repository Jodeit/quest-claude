import ARKit
import Foundation
import RoomPlan
import SceneKit
import UIKit
import simd

/// The room's real surface shape from the LiDAR (ARKit scene reconstruction), in world coordinates,
/// and the photo-textured model made from it: what RoomPlan's boxes can't be.
struct LiDARMesh {
    var positions: [SIMD3<Float>] = []
    var faces: [UInt32] = []  // three per triangle

    var triangleCount: Int { faces.count / 3 }

    /// Every mesh anchor the session has, joined into one mesh in world coordinates.
    static func harvest(_ session: ARSession) -> LiDARMesh? {
        guard let anchors = session.currentFrame?.anchors.compactMap({ $0 as? ARMeshAnchor }), !anchors.isEmpty else {
            return nil
        }
        var mesh = LiDARMesh()
        for anchor in anchors {
            let g = anchor.geometry
            let base = UInt32(mesh.positions.count)
            let v = g.vertices
            let vp = v.buffer.contents()
            for i in 0..<v.count {
                let p = vp.advanced(by: v.offset + v.stride * i).assumingMemoryBound(to: (Float, Float, Float).self).pointee
                let w = anchor.transform * SIMD4(p.0, p.1, p.2, 1)
                mesh.positions.append(SIMD3(w.x, w.y, w.z))
            }
            let f = g.faces
            let fp = f.buffer.contents()
            let n = f.count * f.indexCountPerPrimitive
            for i in 0..<n {
                let idx: UInt32 = f.bytesPerIndex == 4
                    ? fp.advanced(by: i * 4).assumingMemoryBound(to: UInt32.self).pointee
                    : UInt32(fp.advanced(by: i * 2).assumingMemoryBound(to: UInt16.self).pointee)
                mesh.faces.append(base + idx)
            }
        }
        return mesh.triangleCount > 0 ? mesh : nil
    }

    /// How many triangles the session has right now (cheap: no copying).
    static func triangles(in session: ARSession) -> Int {
        session.currentFrame?.anchors.compactMap { $0 as? ARMeshAnchor }.reduce(0) { $0 + $1.geometry.faces.count } ?? 0
    }

    // MARK: file: "RSM1", vertex count, face index count, then floats and indices (little-endian)

    func write(to url: URL) throws {
        var data = Data("RSM1".utf8)
        var nv = UInt32(positions.count), nf = UInt32(faces.count)
        data.append(Data(bytes: &nv, count: 4))
        data.append(Data(bytes: &nf, count: 4))
        positions.withUnsafeBufferPointer { buf in
            for p in buf { var x = p.x, y = p.y, z = p.z
                data.append(Data(bytes: &x, count: 4)); data.append(Data(bytes: &y, count: 4)); data.append(Data(bytes: &z, count: 4)) }
        }
        faces.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
        try data.write(to: url, options: .atomic)
    }

    static func read(from url: URL) -> LiDARMesh? {
        guard let data = try? Data(contentsOf: url), data.count >= 12, String(data: data.prefix(4), encoding: .utf8) == "RSM1"
        else { return nil }
        return data.withUnsafeBytes { raw -> LiDARMesh? in
            let nv = Int(raw.loadUnaligned(fromByteOffset: 4, as: UInt32.self))
            let nf = Int(raw.loadUnaligned(fromByteOffset: 8, as: UInt32.self))
            guard data.count >= 12 + nv * 12 + nf * 4 else { return nil }
            var mesh = LiDARMesh()
            mesh.positions.reserveCapacity(nv)
            for i in 0..<nv {
                let o = 12 + i * 12
                mesh.positions.append(SIMD3(raw.loadUnaligned(fromByteOffset: o, as: Float.self),
                                            raw.loadUnaligned(fromByteOffset: o + 4, as: Float.self),
                                            raw.loadUnaligned(fromByteOffset: o + 8, as: Float.self)))
            }
            let fo = 12 + nv * 12
            mesh.faces = (0..<nf).map { raw.loadUnaligned(fromByteOffset: fo + $0 * 4, as: UInt32.self) }
            return mesh
        }
    }

    // MARK: lining up with RoomPlan

    /// Just the turn about the vertical and the shift of a transform: ARKit's worlds are both
    /// gravity-aligned, so anything else is noise.
    static func yawTranslation(_ m: simd_float4x4) -> simd_float4x4 {
        let yaw = atan2(m.columns.2.x, m.columns.0.x)
        return rotationY(yaw, translation: simd_make_float3(m.columns.3))
    }

    static func rotationY(_ a: Float, translation t: SIMD3<Float>) -> simd_float4x4 {
        let c = cos(a), s = sin(a)
        return simd_float4x4(SIMD4(c, 0, -s, 0), SIMD4(0, 1, 0, 0), SIMD4(s, 0, c, 0), SIMD4(t.x, t.y, t.z, 1))
    }

    mutating func apply(_ m: simd_float4x4) {
        for i in positions.indices {
            let p = m * SIMD4(positions[i], 1)
            positions[i] = SIMD3(p.x, p.y, p.z)
        }
    }

    /// Fits the mesh onto RoomPlan's walls and floor (point-to-plane least squares on the turn
    /// about the vertical and the shift; tried on a real scan, where it took a 3-7 cm misfit to
    /// about 2.5 cm, the rest being baseboards and clutter). Applies it and returns it, so frames
    /// taken with the mesh can be moved the same way.
    /// How far to move the mesh up to put its floor on RoomPlan's (the ceiling cross-checks). The
    /// switch into the LiDAR pass can shift the world vertically by tens of centimetres (42 cm on a
    /// real scan), more than the fit's search band. The floor is the lowest strong peak of
    /// upward-facing area by height, the ceiling the highest of downward-facing area.
    func levelOffset(floorY: Float, ceilingY: Float) -> Float {
        var ups: [(Float, Float)] = [], downs: [(Float, Float)] = []  // (height, area)
        for k in 0..<triangleCount {
            let a = positions[Int(faces[3 * k])], b = positions[Int(faces[3 * k + 1])], c = positions[Int(faces[3 * k + 2])]
            let n = simd_cross(b - a, c - a), len = simd_length(n)
            guard len > 1e-9 else { continue }
            let ny = n.y / len, y = (a.y + b.y + c.y) / 3
            if ny > 0.9 { ups.append((y, len / 2)) } else if ny < -0.9 { downs.append((y, len / 2)) }
        }
        func peak(_ items: [(Float, Float)], lowest: Bool) -> Float? {
            guard items.reduce(0, { $0 + $1.1 }) >= 0.5, let lo = items.map({ $0.0 }).min(), let hi = items.map({ $0.0 }).max() else { return nil }
            let bins = Int((hi - lo) / 0.02) + 1
            var h = [Float](repeating: 0, count: bins)
            for (y, area) in items { h[Swift.min(bins - 1, Int((y - lo) / 0.02))] += area }
            let top = h.max() ?? 0
            let strong = h.indices.filter { h[$0] >= Swift.max(0.25 * top, 0.3) }
            guard let i = lowest ? strong.first : strong.last else { return nil }
            let centre = lo + (Float(i) + 0.5) * 0.02
            let near = items.map({ $0.0 }).filter { abs($0 - centre) < 0.03 }.sorted()
            return near.isEmpty ? centre : near[near.count / 2]
        }
        guard let f = peak(ups, lowest: true) else { return 0 }
        let df = floorY - f
        if let c = peak(downs, lowest: false), abs(df - (ceilingY - c)) < 0.06 { return (df + ceilingY - c) / 2 }
        return df
    }

    mutating func fit(to room: CapturedRoom) -> simd_float4x4 {
        guard !positions.isEmpty, !room.walls.isEmpty else { return matrix_identity_float4x4 }
        struct Plane { var c, x, z: SIMD3<Float>; var hw, hh: Float }
        func flat(_ v: simd_float4) -> SIMD3<Float> {
            let h = SIMD3<Float>(v.x, 0, v.z), l = simd_length(h)
            return l > 1e-6 ? h / l : SIMD3(1, 0, 0)
        }
        let planes = room.walls.map { w in
            Plane(c: simd_make_float3(w.transform.columns.3), x: flat(w.transform.columns.0), z: flat(w.transform.columns.2),
                  hw: w.dimensions.x / 2, hh: w.dimensions.y / 2)
        }
        let floorY = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0
        let stride = Swift.max(1, positions.count / 60000)
        let sample = Swift.stride(from: 0, to: positions.count, by: stride).map { positions[$0] }
        let ceilingY = room.walls.map { $0.transform.columns.3.y + $0.dimensions.y / 2 }.max() ?? floorY + 2.4
        var yaw: Float = 0, t = SIMD3<Float>(0, levelOffset(floorY: floorY, ceilingY: ceilingY), 0)
        for iteration in 0..<10 {
            let band: Float = iteration < 4 ? 0.25 : 0.08
            let m = Self.rotationY(yaw, translation: t)
            // Normal equations for (yaw, tx, ty, tz).
            var ata = simd_float4x4(), atb = SIMD4<Float>(0, 0, 0, 0)
            func add(_ row: SIMD4<Float>, _ r: Float) {
                ata.columns.0 += row * row.x; ata.columns.1 += row * row.y
                ata.columns.2 += row * row.z; ata.columns.3 += row * row.w
                atb += row * r
            }
            for p0 in sample {
                let q = m * SIMD4(p0, 1)
                let p = SIMD3(q.x, q.y, q.z)
                if abs(p.y - floorY) < band {
                    add(SIMD4<Float>(0, 0, 1, 0), floorY - p.y)
                    continue
                }
                for w in planes {
                    let d = p - w.c
                    let off = simd_dot(d, w.z)
                    guard abs(off) < band, abs(simd_dot(d, w.x)) < w.hw - 0.1, abs(d.y) < w.hh - 0.15 else { continue }
                    let dp = SIMD3<Float>(p.z - t.z, 0, -(p.x - t.x))  // how p moves per radian of yaw
                    add(SIMD4<Float>(simd_dot(dp, w.z), w.z.x, 0, w.z.z), -off)
                    break
                }
            }
            // Keep it solvable when a direction has no constraint (e.g. no floor seen).
            for k in 0..<4 { ata[k][k] += 1e-3 }
            guard abs(ata.determinant) > 1e-9 else { break }
            let step = ata.inverse * atb
            yaw += step.x
            t += SIMD3(step.y, step.z, step.w)
        }
        let fix = Self.rotationY(yaw, translation: t)
        apply(fix)
        return fix
    }

    /// Vertices within `within` of a RoomPlan wall (inside its extent, away from doors, windows and
    /// openings) move onto it, so walls read flat instead of LiDAR-wavy. Returns how many moved.
    @discardableResult
    mutating func snapToWalls(_ room: CapturedRoom, within: Float = 0.04) -> Int {
        struct Panel { var c, x, z: SIMD3<Float>; var hw, hh: Float }
        func flat(_ v: simd_float4) -> SIMD3<Float> {
            let h = SIMD3<Float>(v.x, 0, v.z), l = simd_length(h)
            return l > 1e-6 ? h / l : SIMD3(1, 0, 0)
        }
        func panel(_ s: CapturedRoom.Surface) -> Panel {
            Panel(c: simd_make_float3(s.transform.columns.3), x: flat(s.transform.columns.0), z: flat(s.transform.columns.2),
                  hw: s.dimensions.x / 2, hh: s.dimensions.y / 2)
        }
        let walls = room.walls.map(panel)
        let holes = (room.doors + room.windows + room.openings).map(panel)
        var moved = 0
        for i in positions.indices {
            let p = positions[i]
            for w in walls {
                let d = p - w.c
                let off = simd_dot(d, w.z)
                guard abs(off) < within, abs(simd_dot(d, w.x)) < w.hw, abs(d.y) < w.hh else { continue }
                let inHole = holes.contains { h in
                    abs(simd_dot(h.c - w.c, w.z)) < 0.3 && abs(simd_dot(p - h.c, h.x)) < h.hw + 0.05 && abs(p.y - h.c.y) < h.hh + 0.05
                }
                if !inHole {
                    positions[i] = p - w.z * off
                    moved += 1
                }
                break
            }
        }
        return moved
    }

    /// Checks shelf edges found in each unit's front photo against the mesh: a shelf is a flat,
    /// upward-facing surface inside the unit's box, so peaks in the area-weighted height histogram of
    /// those triangles confirm an edge within 4 cm. The mesh misses shelves under bins (it sees their
    /// tops), and the photo can take a box edge for a shelf, so edges are flagged, not replaced (on a
    /// real closet they agreed within an inch where both found one). Returns the fronts with flags.
    func confirmShelves(_ fronts: [StorageFront], room: CapturedRoom) -> [StorageFront] {
        var out = fronts
        for fi in out.indices where out[fi].object < room.objects.count && !out[fi].shelves.isEmpty {
            let o = room.objects[out[fi].object]
            let c = simd_make_float3(o.transform.columns.3)
            let x = simd_normalize(simd_make_float3(o.transform.columns.0)), z = simd_normalize(simd_make_float3(o.transform.columns.2))
            let w = o.dimensions.x, h = o.dimensions.y, d = o.dimensions.z
            let bins = Int((h + 0.06) / 0.01) + 1
            var hist = [Float](repeating: 0, count: bins)
            for t in 0..<triangleCount {
                let a = positions[Int(faces[t * 3])], b = positions[Int(faces[t * 3 + 1])], cc = positions[Int(faces[t * 3 + 2])]
                let n = simd_cross(b - a, cc - a), l = simd_length(n)
                guard l > 1e-9, n.y / l > 0.9 else { continue }
                let ctr = (a + b + cc) / 3, r = ctr - c
                guard abs(simd_dot(r, x)) < w / 2 - 0.03, abs(simd_dot(r, z)) < d / 2 + 0.03, abs(r.y) < h / 2 + 0.02 else { continue }
                let k = Int(((r.y + h / 2) + 0.02) / 0.01)
                if k >= 0, k < bins { hist[k] += l / 2 }
            }
            var smooth = hist
            for k in 1..<(bins - 1) { smooth[k] = 0.25 * hist[k - 1] + 0.5 * hist[k] + 0.25 * hist[k + 1] }
            let total = smooth.reduce(0, +) + 1e-9
            var peaks: [Int] = []
            for k in smooth.indices.sorted(by: { smooth[$0] > smooth[$1] }) {
                guard smooth[k] >= 0.04 * total else { break }
                if peaks.allSatisfy({ abs($0 - k) > 6 }) { peaks.append(k) }
            }
            let tops = peaks.map { Float($0) * 0.01 - 0.02 + 0.005 }
            out[fi].confirmed = out[fi].shelves.map { s in tops.contains { abs($0 - s) < 0.04 } }
        }
        return out
    }

    // MARK: texturing

    /// The painted model. Each triangle takes the frame that sees it most head-on and closest,
    /// among frames where it's the nearest surface: each frame gets a quarter-size depth buffer
    /// from the mesh's vertices, and a triangle counts as visible if its centre is within a few
    /// centimetres of it (tried on a real scan: 95% of triangles painted, where a grid march left
    /// most of them gray). Triangles are wound to face the frame that painted them and drawn
    /// one-sided, so walls between you and the room vanish from outside. Triangles near the
    /// ceiling go in a separate node (hidden in the dollhouse view), and anything outside `bounds`
    /// (other rooms' scraps) is dropped.
    func texturedNodes(frames: [(Keyframe, URL)], ceilingY: Float?, bounds: (SIMD3<Float>, SIMD3<Float>)?)
        -> (model: SCNNode, ceiling: SCNNode) {
        let cams = frames.map { Cam($0.0) }
        let tri = triangleCount
        guard tri > 0, !cams.isEmpty else { return (SCNNode(), SCNNode()) }
        // Blurrier frames count for less (as in roomscan): sharpness relative to the median.
        let sharp = frames.compactMap { $0.0.sharpness }.sorted()
        let medianSharp = sharp.isEmpty ? 1 : Swift.max(1e-3, sharp[sharp.count / 2])
        let weight = frames.map { f -> Float in
            guard let s = f.0.sharpness else { return 1 }
            return Swift.min(1.5, Swift.max(0.3, s / medianSharp))
        }
        var centre = [SIMD3<Float>](repeating: .zero, count: tri)
        var normal = [SIMD3<Float>](repeating: .zero, count: tri)
        var keep = [Bool](repeating: true, count: tri)
        for t in 0..<tri {
            let a = positions[Int(faces[t * 3])], b = positions[Int(faces[t * 3 + 1])], c = positions[Int(faces[t * 3 + 2])]
            let ctr = (a + b + c) / 3
            centre[t] = ctr
            let n = simd_cross(b - a, c - a), l = simd_length(n)
            normal[t] = l > 1e-9 ? n / l : SIMD3(0, 1, 0)
            if let b = bounds, ctr.x < b.0.x || ctr.z < b.0.z || ctr.x > b.1.x || ctr.z > b.1.z || ctr.y < b.0.y || ctr.y > b.1.y {
                keep[t] = false
            }
        }

        let choice = Self.frameChoices(positions: positions, cams: cams, weight: weight, centre: centre, normal: normal, keep: keep,
                                       faces: faces)

        // Two nodes' worth of geometry: three vertices per triangle (vertices sit in different
        // frames' textures), wound to face the camera that painted them.
        struct Build { var verts = [SCNVector3](), coords = [CGPoint](), groups = [Int: [UInt32]]() }
        var model = Build(), ceiling = Build()
        for t in 0..<tri where keep[t] {
            let k = choice[t]
            var ids = [Int(faces[t * 3]), Int(faces[t * 3 + 1]), Int(faces[t * 3 + 2])]
            var toward = normal[t]
            if k >= 0 { toward = cams[k].position - centre[t] } else if let cy = ceilingY, centre[t].y > cy - 0.3 { toward = SIMD3(0, -1, 0) }
            if simd_dot(normal[t], toward) < 0 { ids.swapAt(1, 2) }
            let isCeiling = ceilingY.map { centre[t].y > $0 - 0.3 && abs(normal[t].y) > 0.7 } ?? false
            let base = UInt32(isCeiling ? ceiling.verts.count : model.verts.count)
            for id in ids {
                let p = positions[id]
                var uv = CGPoint.zero
                if k >= 0, let px = cams[k].pixelUnclamped(p) { uv = CGPoint(x: CGFloat(px.x / cams[k].w), y: CGFloat(px.y / cams[k].h)) }
                if isCeiling {
                    ceiling.verts.append(SCNVector3(p.x, p.y, p.z)); ceiling.coords.append(uv)
                } else {
                    model.verts.append(SCNVector3(p.x, p.y, p.z)); model.coords.append(uv)
                }
            }
            if isCeiling { ceiling.groups[k, default: []].append(contentsOf: [base, base + 1, base + 2]) }
            else { model.groups[k, default: []].append(contentsOf: [base, base + 1, base + 2]) }
        }
        var images = [Int: UIImage]()
        func node(_ b: Build) -> SCNNode {
            guard !b.verts.isEmpty else { return SCNNode() }
            var elements: [SCNGeometryElement] = [], materials: [SCNMaterial] = []
            for (k, idx) in b.groups.sorted(by: { $0.key < $1.key }) {
                elements.append(SCNGeometryElement(indices: idx, primitiveType: .triangles))
                let m = SCNMaterial()
                if k >= 0 {
                    if images[k] == nil { images[k] = UIImage(contentsOfFile: frames[k].1.path) }
                    m.diffuse.contents = images[k] ?? UIColor(white: 0.82, alpha: 1)
                } else {
                    m.diffuse.contents = UIColor(white: 0.82, alpha: 1)
                }
                m.lightingModel = .constant
                m.isDoubleSided = false
                materials.append(m)
            }
            let g = SCNGeometry(sources: [SCNGeometrySource(vertices: b.verts), SCNGeometrySource(textureCoordinates: b.coords)],
                                elements: elements)
            g.materials = materials
            return SCNNode(geometry: g)
        }
        return (node(model), node(ceiling))
    }

    /// For each triangle (where `keep`), the frame that sees it most head-on and closest, weighted by
    /// sharpness, among frames where it's the nearest surface (a quarter-size depth buffer per frame
    /// from the vertices). -1 where none does.
    private static func frameChoices(positions: [SIMD3<Float>], cams: [Cam], weight: [Float], centre: [SIMD3<Float>],
                                     normal: [SIMD3<Float>], keep: [Bool], faces: [UInt32]? = nil) -> [Int] {
        let tri = centre.count
        // The three best (score, frame) per triangle, for smoothing below.
        var top = [[(Float, Int)]](repeating: [(-1, -1), (-1, -1), (-1, -1)], count: tri)
        let ds: Float = 4
        for (k, cam) in cams.enumerated() {
            let bw = Int(cam.w / ds), bh = Int(cam.h / ds)
            var zbuf = [Float](repeating: .infinity, count: bw * bh)
            for p in positions {
                let c = cam.inverse * SIMD4(p, 1)
                let d = -c.z
                guard d > 0.1 else { continue }
                let x = Int((cam.cx + cam.fx * c.x / d) / ds), y = Int((cam.cy - cam.fy * c.y / d) / ds)
                guard x >= 0, y >= 0, x < bw - 1, y < bh - 1 else { continue }
                for (ox, oy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                    let i = (y + oy) * bw + x + ox
                    if d < zbuf[i] { zbuf[i] = d }
                }
            }
            for t in 0..<tri where keep[t] {
                let c = cam.inverse * SIMD4(centre[t], 1)
                let d = -c.z
                guard d > 0.2, d < 6 else { continue }
                let x = cam.cx + cam.fx * c.x / d, y = cam.cy - cam.fy * c.y / d
                guard x > 8, y > 8, x < cam.w - 8, y < cam.h - 8 else { continue }
                let zi = Int(y / ds) * bw + Int(x / ds)
                guard d <= zbuf[zi] + 0.04 + 0.02 * d else { continue }
                let toCam = cam.position - centre[t]
                let dist = simd_length(toCam)
                let facing = abs(simd_dot(toCam / dist, normal[t]))
                guard facing > 0.2 else { continue }
                let score = facing * facing / dist * weight[k]
                if score > top[t][2].0 {
                    top[t][2] = (score, k)
                    if top[t][2].0 > top[t][1].0 { top[t].swapAt(1, 2) }
                    if top[t][1].0 > top[t][0].0 { top[t].swapAt(0, 1) }
                }
            }
        }
        var choice = top.map { $0[0].1 }
        guard let faces, faces.count == tri * 3 else { return choice }
        // Smooth, like texturing tools' label smoothing: neighbouring triangles painted from different
        // frames make speckle, so a triangle takes the frame most of its edge neighbours use, among its
        // top three scoring at least 60% of its best (on a real scan this took out most of the speckle).
        var neighbours = [[Int]](repeating: [], count: tri)
        var firstByEdge = [UInt64: Int]()
        for t in 0..<tri {
            for (a, b) in [(faces[t * 3], faces[t * 3 + 1]), (faces[t * 3 + 1], faces[t * 3 + 2]), (faces[t * 3 + 2], faces[t * 3])] {
                let key = UInt64(Swift.min(a, b)) << 32 | UInt64(Swift.max(a, b))
                if let other = firstByEdge[key] { neighbours[t].append(other); neighbours[other].append(t) } else { firstByEdge[key] = t }
            }
        }
        for _ in 0..<3 {
            var next = choice
            for t in 0..<tri where top[t][0].1 >= 0 {
                var bestVotes = -1.0, pick = top[t][0].1
                for (score, k) in top[t] where k >= 0 && score >= 0.6 * top[t][0].0 {
                    let votes = Double(neighbours[t].filter { choice[$0] == k }.count) + 1e-3 * Double(score)
                    if votes > bestVotes { bestVotes = votes; pick = k }
                }
                next[t] = pick
            }
            choice = next
        }
        return choice
    }

    /// A frame's depth buffer from the mesh's vertices, a quarter of the frame's size.
    private static func depthBuffer(_ positions: [SIMD3<Float>], _ cam: Cam, ds: Float = 4) -> (z: [Float], w: Int) {
        let bw = Int(cam.w / ds), bh = Int(cam.h / ds)
        var z = [Float](repeating: .infinity, count: bw * bh)
        for p in positions {
            let c = cam.inverse * SIMD4(p, 1)
            let d = -c.z
            guard d > 0.1 else { continue }
            let x = Int((cam.cx + cam.fx * c.x / d) / ds), y = Int((cam.cy - cam.fy * c.y / d) / ds)
            guard x >= 0, y >= 0, x < bw - 1, y < bh - 1 else { continue }
            for (ox, oy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let i = (y + oy) * bw + x + ox
                if d < z[i] { z[i] = d }
            }
        }
        return (z, bw)
    }

    /// Per-frame RGB corrections so frames that saw the same surface agree on its colour (exposure and
    /// white balance drift as the phone moves): for a sample of triangles, each frame's log colour where
    /// it's the nearest surface; per pair of frames the median difference; then corrections c with
    /// c_b - c_a matching those, solved by Gauss-Seidel and centred on zero. As in roomscan, where the
    /// office scan's corrections ran from 0.5x to 1.7x. Returns multipliers.
    private static func exposureCorrections(positions: [SIMD3<Float>], cams: [Cam], frames: [(Keyframe, URL)],
                                            centre: [SIMD3<Float>], normal: [SIMD3<Float>], keep: [Bool]) -> [SIMD3<Float>] {
        let n = cams.count
        guard n > 1 else { return [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: n) }
        let candidates = keep.indices.filter { keep[$0] }
        guard !candidates.isEmpty else { return [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: n) }
        let step = Swift.max(1, candidates.count / 4000)
        let sample = Swift.stride(from: 0, to: candidates.count, by: step).map { candidates[$0] }
        var seen = [[(Int, SIMD3<Float>)]](repeating: [], count: sample.count)  // per sample: (frame, log colour)
        for (k, cam) in cams.enumerated() {
            let (z, bw) = depthBuffer(positions, cam)
            var hits: [(Int, SIMD2<Float>)] = []
            for (si, t) in sample.enumerated() {
                let c = cam.inverse * SIMD4(centre[t], 1)
                let d = -c.z
                guard d > 0.2, d < 6 else { continue }
                let x = cam.cx + cam.fx * c.x / d, y = cam.cy - cam.fy * c.y / d
                guard x > 8, y > 8, x < cam.w - 8, y < cam.h - 8, d <= z[Int(y / 4) * bw + Int(x / 4)] + 0.04 + 0.02 * d else { continue }
                let toCam = cam.position - centre[t]
                guard abs(simd_dot(toCam / simd_length(toCam), normal[t])) > 0.3 else { continue }
                hits.append((si, SIMD2(x, y)))
            }
            guard !hits.isEmpty, let img = RGBImage(url: frames[k].1) else { continue }
            for (si, px) in hits {
                let col = img.sample(px.x * Float(img.width) / cam.w, px.y * Float(img.height) / cam.h)
                seen[si].append((k, SIMD3(log(Swift.max(col.x, 4)), log(Swift.max(col.y, 4)), log(Swift.max(col.z, 4)))))
            }
        }
        var pairs = [Int: [SIMD3<Float>]]()  // a * n + b (a < b) -> log(a) - log(b) samples
        for obs in seen where obs.count > 1 {
            for i in 0..<obs.count { for j in (i + 1)..<obs.count {
                let (a, la) = obs[i], (b, lb) = obs[j]
                if a < b { pairs[a * n + b, default: []].append(la - lb) } else { pairs[b * n + a, default: []].append(lb - la) }
            } }
        }
        var edges: [(a: Int, b: Int, d: SIMD3<Float>, w: Float)] = []
        for (key, diffs) in pairs where diffs.count >= 20 {
            func median(_ v: [Float]) -> Float { let s = v.sorted(); return s[s.count / 2] }
            edges.append((key / n, key % n, SIMD3(median(diffs.map { $0.x }), median(diffs.map { $0.y }), median(diffs.map { $0.z })),
                          Float(diffs.count).squareRoot()))
        }
        guard !edges.isEmpty else { return [SIMD3<Float>](repeating: SIMD3(1, 1, 1), count: n) }
        var c = [SIMD3<Float>](repeating: .zero, count: n)
        for _ in 0..<60 {
            var num = [SIMD3<Float>](repeating: .zero, count: n), den = [Float](repeating: 0.01, count: n)
            for e in edges {  // c_b - c_a = d
                num[e.a] += (c[e.b] - e.d) * e.w; den[e.a] += e.w
                num[e.b] += (c[e.a] + e.d) * e.w; den[e.b] += e.w
            }
            for k in 0..<n { c[k] = num[k] / den[k] }
            let mean = c.reduce(.zero, +) / Float(n)
            for k in 0..<n { c[k] -= mean }
        }
        return c.map { v in SIMD3(exp(Swift.min(0.7, Swift.max(-0.7, v.x))), exp(Swift.min(0.7, Swift.max(-0.7, v.y))),
                                  exp(Swift.min(0.7, Swift.max(-0.7, v.z)))) }
    }

    /// The photo-textured mesh for the team twin page (RTW2), as roomscan twin makes it: trimmed to
    /// `bounds`, shrunk by vertex clustering, long slivers dropped, each triangle given the frame that
    /// sees it best (smoothed), wound to face it, with texture coordinates in that frame (v up, as
    /// WebGL samples it); plus each frame's exposure correction, to bake into its photo.
    func texturedExport(frames: [(Keyframe, URL)], ceilingY: Float, bounds: (SIMD3<Float>, SIMD3<Float>), cell: Float = 0.03)
        -> (corners: [SIMD3<Float>], uv: [SIMD2<Float>], choice: [Int], ceiling: [Bool], gains: [SIMD3<Float>]) {
        // Cluster the vertices inside the bounds.
        var index = [SIMD3<Int32>: Int](), sum: [SIMD3<Float>] = [], n: [Float] = []
        var remap = [Int](repeating: -1, count: positions.count)
        for (i, p) in positions.enumerated() {
            guard p.x > bounds.0.x - 0.2, p.z > bounds.0.z - 0.2, p.x < bounds.1.x + 0.2, p.z < bounds.1.z + 0.2 else { continue }
            let key = SIMD3<Int32>(Int32(((p.x - bounds.0.x) / cell).rounded(.down)), Int32(((p.y - bounds.0.y) / cell).rounded(.down)),
                                   Int32(((p.z - bounds.0.z) / cell).rounded(.down)))
            if let j = index[key] { sum[j] += p; n[j] += 1; remap[i] = j } else { index[key] = sum.count; remap[i] = sum.count; sum.append(p); n.append(1) }
        }
        let P = zip(sum, n).map { $0 / $1 }
        var F: [UInt32] = []
        for t in 0..<triangleCount {
            let ids = (0..<3).map { remap[Int(faces[t * 3 + $0])] }
            guard !ids.contains(-1), ids[0] != ids[1], ids[1] != ids[2], ids[0] != ids[2] else { continue }
            let a = P[ids[0]], b = P[ids[1]], c = P[ids[2]], ctr = (a + b + c) / 3
            guard ctr.x > bounds.0.x, ctr.z > bounds.0.z, ctr.y > bounds.0.y, ctr.x < bounds.1.x, ctr.z < bounds.1.z, ctr.y < bounds.1.y,
                  Swift.max(simd_distance(a, b), simd_distance(b, c), simd_distance(c, a)) <= 0.12 else { continue }
            F += ids.map { UInt32($0) }
        }
        let tri = F.count / 3
        var centre = [SIMD3<Float>](repeating: .zero, count: tri), normal = centre
        for t in 0..<tri {
            let a = P[Int(F[t * 3])], b = P[Int(F[t * 3 + 1])], c = P[Int(F[t * 3 + 2])]
            centre[t] = (a + b + c) / 3
            let nn = simd_cross(b - a, c - a), l = simd_length(nn)
            normal[t] = l > 1e-9 ? nn / l : SIMD3(0, 1, 0)
        }
        let cams = frames.map { Cam($0.0) }
        let sharp = frames.compactMap { $0.0.sharpness }.sorted()
        let medianSharp = sharp.isEmpty ? 1 : Swift.max(1e-3, sharp[sharp.count / 2])
        let weight = frames.map { f -> Float in f.0.sharpness.map { Swift.min(1.5, Swift.max(0.3, $0 / medianSharp)) } ?? 1 }
        let keep = [Bool](repeating: true, count: tri)
        let choice = cams.isEmpty ? [Int](repeating: -1, count: tri)
            : Self.frameChoices(positions: P, cams: cams, weight: weight, centre: centre, normal: normal, keep: keep, faces: F)
        let gains = Self.exposureCorrections(positions: P, cams: cams, frames: frames, centre: centre, normal: normal, keep: keep)
        var corners: [SIMD3<Float>] = [], uv: [SIMD2<Float>] = [], ceiling: [Bool] = []
        corners.reserveCapacity(tri * 3); uv.reserveCapacity(tri * 3)
        for t in 0..<tri {
            let k = choice[t]
            var ids = [Int(F[t * 3]), Int(F[t * 3 + 1]), Int(F[t * 3 + 2])]
            let toward = k >= 0 ? cams[k].position - centre[t] : SIMD3<Float>(0, 1, 0)
            if simd_dot(normal[t], toward) < 0 { ids.swapAt(1, 2) }
            for id in ids {
                corners.append(P[id])
                if k >= 0, let px = cams[k].pixelUnclamped(P[id]) { uv.append(SIMD2(px.x / cams[k].w, 1 - px.y / cams[k].h)) }
                else { uv.append(.zero) }
            }
            ceiling.append(centre[t].y > ceilingY - 0.3 && abs(normal[t].y) > 0.7)
        }
        return (corners, uv, choice, ceiling, gains)
    }

    /// The mesh for the team twin page: trimmed to `bounds`, each vertex coloured from the frames
    /// that painted its triangles, triangles wound to face their frame, then shrunk by vertex
    /// clustering (`cell` metres). Ceiling triangles flagged so the page can hide them.
    func webMesh(frames: [(Keyframe, URL)], ceilingY: Float, bounds: (SIMD3<Float>, SIMD3<Float>), cell: Float = 0.025)
        -> (positions: [SIMD3<Float>], colors: [SIMD3<UInt8>], faces: [UInt32], ceiling: [Bool]) {
        let cams = frames.map { Cam($0.0) }
        let tri = triangleCount
        var centre = [SIMD3<Float>](repeating: .zero, count: tri), normal = centre
        var keep = [Bool](repeating: false, count: tri)
        for t in 0..<tri {
            let a = positions[Int(faces[t * 3])], b = positions[Int(faces[t * 3 + 1])], c = positions[Int(faces[t * 3 + 2])]
            let ctr = (a + b + c) / 3
            centre[t] = ctr
            let n = simd_cross(b - a, c - a), l = simd_length(n)
            normal[t] = l > 1e-9 ? n / l : SIMD3(0, 1, 0)
            keep[t] = ctr.x > bounds.0.x && ctr.z > bounds.0.z && ctr.y > bounds.0.y
                && ctr.x < bounds.1.x && ctr.z < bounds.1.z && ctr.y < bounds.1.y
        }
        let sharp = frames.compactMap { $0.0.sharpness }.sorted()
        let medianSharp = sharp.isEmpty ? 1 : Swift.max(1e-3, sharp[sharp.count / 2])
        let weight = frames.map { f -> Float in f.0.sharpness.map { Swift.min(1.5, Swift.max(0.3, $0 / medianSharp)) } ?? 1 }
        let choice = cams.isEmpty ? [Int](repeating: -1, count: tri)
            : Self.frameChoices(positions: positions, cams: cams, weight: weight, centre: centre, normal: normal, keep: keep)
        let gains = Self.exposureCorrections(positions: positions, cams: cams, frames: frames, centre: centre, normal: normal,
                                             keep: keep)

        // Vertex colours: each kept triangle's corners sampled in its frame, averaged per vertex.
        var acc = [SIMD3<Float>](repeating: .zero, count: positions.count)
        var cnt = [Float](repeating: 0, count: positions.count)
        var byFrame = [Int: [Int]]()
        for t in 0..<tri where keep[t] && choice[t] >= 0 { byFrame[choice[t], default: []].append(t) }
        for (k, tris) in byFrame {
            guard let img = RGBImage(url: frames[k].1) else { continue }
            let cam = cams[k]
            for t in tris {
                for j in 0..<3 {
                    let v = Int(faces[t * 3 + j])
                    guard let px = cam.pixelUnclamped(positions[v]) else { continue }
                    acc[v] += img.sample(px.x * Float(img.width) / cam.w, px.y * Float(img.height) / cam.h) * gains[k]
                    cnt[v] += 1
                }
            }
        }
        // Cluster vertices on a grid; average positions and colours.
        var index = [SIMD3<Int32>: Int]()
        var outP: [SIMD3<Float>] = [], outC: [SIMD3<Float>] = [], outN: [Float] = []
        var remap = [Int](repeating: -1, count: positions.count)
        let lo = bounds.0
        for (i, p) in positions.enumerated() {
            let key = SIMD3<Int32>(Int32(((p.x - lo.x) / cell).rounded(.down)), Int32(((p.y - lo.y) / cell).rounded(.down)),
                                   Int32(((p.z - lo.z) / cell).rounded(.down)))
            let colour = cnt[i] > 0 ? acc[i] / cnt[i] : SIMD3<Float>(205, 205, 205)
            if let j = index[key] {
                outP[j] += p; outC[j] += colour; outN[j] += 1; remap[i] = j
            } else {
                index[key] = outP.count; remap[i] = outP.count
                outP.append(p); outC.append(colour); outN.append(1)
            }
        }
        for j in outP.indices { outP[j] /= outN[j]; outC[j] /= outN[j] }
        var outF: [UInt32] = [], ceiling: [Bool] = []
        for t in 0..<tri where keep[t] {
            var ids = [remap[Int(faces[t * 3])], remap[Int(faces[t * 3 + 1])], remap[Int(faces[t * 3 + 2])]]
            guard ids[0] != ids[1], ids[1] != ids[2], ids[0] != ids[2] else { continue }
            let toward = choice[t] >= 0 ? cams[choice[t]].position - centre[t] : SIMD3<Float>(0, 1, 0)
            if simd_dot(normal[t], toward) < 0 { ids.swapAt(1, 2) }
            outF += ids.map { UInt32($0) }
            ceiling.append(centre[t].y > ceilingY - 0.3 && abs(normal[t].y) > 0.7)
        }
        let colours = outC.map { SIMD3<UInt8>(UInt8(Swift.min(255, $0.x)), UInt8(Swift.min(255, $0.y)), UInt8(Swift.min(255, $0.z))) }
        return (outP, colours, outF, ceiling)
    }

    private struct Cam {
        let inverse: simd_float4x4
        let position: SIMD3<Float>
        let fx, fy, cx, cy, w, h: Float

        init(_ k: Keyframe) {
            let pose = k.pose
            inverse = pose.inverse
            position = simd_make_float3(pose.columns.3)
            fx = k.fx; fy = k.fy; cx = k.cx; cy = k.cy
            w = Float(k.width); h = Float(k.height)
        }

        /// Pixel in the frame (sensor orientation), even a little outside it; nil if behind.
        func pixelUnclamped(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            let c = inverse * SIMD4(p, 1)
            let depth = -c.z
            guard depth > 0.05 else { return nil }
            return SIMD2(cx + fx * c.x / depth, cy - fy * c.y / depth)
        }

        /// Pixel in the frame (sensor orientation), with a small margin; nil if out of view.
        func project(_ p: SIMD3<Float>) -> SIMD2<Float>? {
            let c = inverse * SIMD4(p, 1)
            let depth = -c.z
            guard depth > 0.1 else { return nil }
            let x = cx + fx * c.x / depth, y = cy - fy * c.y / depth
            guard x > 2, y > 2, x < w - 2, y < h - 2 else { return nil }
            return SIMD2(x, y)
        }
    }
}

/// The camera with the LiDAR mesh drawn over it as it builds, for the photo-real pass.
final class MeshPassView: UIView, ARSCNViewDelegate {
    private let scnView = ARSCNView()

    init(session: ARSession) {
        super.init(frame: .zero)
        scnView.session = session
        scnView.delegate = self
        scnView.automaticallyUpdatesLighting = false
        scnView.frame = bounds
        scnView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        addSubview(scnView)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func renderer(_ renderer: SCNSceneRenderer, nodeFor anchor: ARAnchor) -> SCNNode? {
        guard let mesh = anchor as? ARMeshAnchor else { return nil }
        let node = SCNNode(geometry: Self.geometry(mesh.geometry))
        return node
    }

    func renderer(_ renderer: SCNSceneRenderer, didUpdate node: SCNNode, for anchor: ARAnchor) {
        guard let mesh = anchor as? ARMeshAnchor else { return }
        node.geometry = Self.geometry(mesh.geometry)
    }

    private static func geometry(_ g: ARMeshGeometry) -> SCNGeometry {
        let v = g.vertices, f = g.faces
        let vs = SCNGeometrySource(buffer: v.buffer, vertexFormat: v.format, semantic: .vertex, vertexCount: v.count,
                                   dataOffset: v.offset, dataStride: v.stride)
        let data = Data(bytesNoCopy: f.buffer.contents(), count: f.buffer.length, deallocator: .none)
        let fe = SCNGeometryElement(data: data, primitiveType: .triangles, primitiveCount: f.count,
                                    bytesPerIndex: f.bytesPerIndex)
        let geometry = SCNGeometry(sources: [vs], elements: [fe])
        let m = SCNMaterial()
        m.fillMode = .lines
        m.diffuse.contents = UIColor(red: 0.3, green: 0.9, blue: 1, alpha: 0.7)
        m.lightingModel = .constant
        geometry.materials = [m]
        return geometry
    }
}
