import ARKit
import Foundation
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

    // MARK: texturing

    /// The mesh painted with the kept frames: each triangle takes the frame that sees it most
    /// head-on and closest, unless something in the mesh stands between them (checked by marching
    /// through a 5 cm grid of the mesh), so a chair isn't painted onto the wall behind it. One
    /// geometry element per frame, with that frame as its texture; triangles no frame saw are gray.
    func texturedNode(frames: [(Keyframe, URL)]) -> SCNNode {
        let cams = frames.map { Cam($0.0) }
        let tri = triangleCount
        guard tri > 0 else { return SCNNode() }

        // Occupancy grid.
        let cell: Float = 0.05
        let lo = positions.reduce(SIMD3<Float>(repeating: .greatestFiniteMagnitude)) { simd_min($0, $1) } - cell
        let hi = positions.reduce(SIMD3<Float>(repeating: -.greatestFiniteMagnitude)) { simd_max($0, $1) } + cell
        let dims = SIMD3<Int>(Int((hi.x - lo.x) / cell) + 1, Int((hi.y - lo.y) / cell) + 1, Int((hi.z - lo.z) / cell) + 1)
        var grid = [Bool](repeating: false, count: dims.x * dims.y * dims.z)
        func index(_ p: SIMD3<Float>) -> Int? {
            let q = (p - lo) / cell
            let x = Int(q.x), y = Int(q.y), z = Int(q.z)
            guard x >= 0, y >= 0, z >= 0, x < dims.x, y < dims.y, z < dims.z else { return nil }
            return (z * dims.y + y) * dims.x + x
        }
        for t in 0..<tri {
            let a = positions[Int(faces[t * 3])], b = positions[Int(faces[t * 3 + 1])], c = positions[Int(faces[t * 3 + 2])]
            for p in [a, b, c, (a + b + c) / 3, (a + b) / 2, (b + c) / 2, (a + c) / 2] {
                if let i = index(p) { grid[i] = true }
            }
        }
        func clear(from p: SIMD3<Float>, to cam: SIMD3<Float>) -> Bool {
            let d = cam - p, len = simd_length(d)
            guard len > 0.2 else { return true }
            let step = d / len * (cell * 0.8)
            var q = p + d / len * 0.08  // start off the surface itself
            var travelled: Float = 0.08
            while travelled < len - 0.1 {
                if let i = index(q), grid[i] { return false }
                q += step
                travelled += cell * 0.8
            }
            return true
        }

        // Choose a frame per triangle.
        var choice = [Int](repeating: -1, count: tri)
        var uv = [SIMD2<Float>](repeating: .zero, count: tri * 3)
        for t in 0..<tri {
            let a = positions[Int(faces[t * 3])], b = positions[Int(faces[t * 3 + 1])], c = positions[Int(faces[t * 3 + 2])]
            let centre = (a + b + c) / 3
            var n = simd_cross(b - a, c - a)
            let nl = simd_length(n)
            guard nl > 1e-9 else { continue }
            n /= nl
            var ranked: [(Int, Float, [SIMD2<Float>])] = []
            for (k, cam) in cams.enumerated() {
                let toCam = cam.position - centre
                let dist = simd_length(toCam)
                guard dist > 0.2, dist < 6 else { continue }
                let facing = abs(simd_dot(toCam / dist, n))
                guard facing > 0.2, let pa = cam.project(a), let pb = cam.project(b), let pc = cam.project(c) else { continue }
                ranked.append((k, facing * facing / dist, [pa, pb, pc]))
            }
            ranked.sort { $0.1 > $1.1 }
            for (k, _, pts) in ranked.prefix(4) where clear(from: centre, to: cams[k].position) {
                choice[t] = k
                for j in 0..<3 { uv[t * 3 + j] = SIMD2(pts[j].x / cams[k].w, pts[j].y / cams[k].h) }
                break
            }
        }

        // Geometry: three vertices per triangle (a vertex can sit in two frames' textures).
        var verts = [SCNVector3](), coords = [CGPoint]()
        verts.reserveCapacity(tri * 3); coords.reserveCapacity(tri * 3)
        for t in 0..<tri {
            for j in 0..<3 {
                let p = positions[Int(faces[t * 3 + j])]
                verts.append(SCNVector3(p.x, p.y, p.z))
                let u = uv[t * 3 + j]
                coords.append(CGPoint(x: CGFloat(u.x), y: CGFloat(u.y)))
            }
        }
        var groups = [Int: [UInt32]]()
        for t in 0..<tri {
            let base = UInt32(t * 3)
            groups[choice[t], default: []].append(contentsOf: [base, base + 1, base + 2])
        }
        var elements: [SCNGeometryElement] = [], materials: [SCNMaterial] = []
        for (k, idx) in groups.sorted(by: { $0.key < $1.key }) {
            elements.append(SCNGeometryElement(indices: idx, primitiveType: .triangles))
            let m = SCNMaterial()
            if k >= 0, let image = UIImage(contentsOfFile: frames[k].1.path) {
                m.diffuse.contents = image
            } else {
                m.diffuse.contents = UIColor(white: 0.82, alpha: 1)
            }
            m.lightingModel = .constant
            m.isDoubleSided = true
            materials.append(m)
        }
        let geometry = SCNGeometry(sources: [SCNGeometrySource(vertices: verts), SCNGeometrySource(textureCoordinates: coords)],
                                   elements: elements)
        geometry.materials = materials
        return SCNNode(geometry: geometry)
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
