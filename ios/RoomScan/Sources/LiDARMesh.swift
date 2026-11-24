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
        var yaw: Float = 0, t = SIMD3<Float>(0, 0, 0)
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

        var best = [Float](repeating: -1, count: tri)
        var choice = [Int](repeating: -1, count: tri)
        var pixel = [SIMD2<Float>](repeating: .zero, count: tri)
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
                let score = facing * facing / dist
                if score > best[t] {
                    best[t] = score
                    choice[t] = k
                    pixel[t] = SIMD2(x, y)
                }
            }
        }

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
