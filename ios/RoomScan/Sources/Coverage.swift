import RoomPlan
import SwiftUI
import simd

/// How much of each wall the kept frames have seen, for guiding the scan: walls are cut into
/// 30 cm cells, and a cell counts once some frame saw it from the room side, reasonably head-on,
/// within 5 m. The same test the elevations depend on, without the occlusion check (it's live).
struct CoverageSnapshot {
    struct Wall: Identifiable {
        let id: Int
        let a, b: SIMD2<Float>  // ends on the floor, top view (ARKit x, z)
        let length: Float
        let fraction: Float
    }

    var walls: [Wall]
    var camera: SIMD2<Float>
    var heading: SIMD2<Float>  // where the phone points, top view, unit length
    var overall: Float         // length-weighted
    var hint: String?
    var weakWalls: Int         // longer than 60 cm and under 70% covered
}

enum Coverage {
    private static let cell: Float = 0.3

    static func compute(room: CapturedRoom, frames: [Keyframe], camera: simd_float4x4) -> CoverageSnapshot {
        let cams = frames.map(Cam.init)
        let camPos = simd_make_float3(camera.columns.3)
        let flatCam = SIMD2(camPos.x, camPos.z)
        var heading = SIMD2(-camera.columns.2.x, -camera.columns.2.z)
        heading = simd_length(heading) > 1e-4 ? simd_normalize(heading) : SIMD2(0, -1)

        var walls: [CoverageSnapshot.Wall] = []
        for (i, w) in room.walls.enumerated() where w.dimensions.x > 0.3 && w.dimensions.y > 0.3 {
            // The room side is where the cameras mostly were (as for the elevations).
            let c = simd_make_float3(w.transform.columns.3)
            let z = simd_make_float3(w.transform.columns.2)
            var side: Float = 0
            for k in cams where simd_distance(k.position, c) < 8 { side += simd_dot(k.position - c, z) > 0 ? 1 : -1 }
            if side == 0 { side = simd_dot(camPos - c, z) }
            let f = WallFrame(w, flipped: side < 0)
            let nu = Swift.max(1, Int(f.width / cell)), nv = Swift.max(1, Int(f.height / cell))
            var covered = 0
            for a in 0..<nu {
                for b in 0..<nv {
                    let p = f.world(u: (Float(a) + 0.5) * f.width / Float(nu), v: (Float(b) + 0.5) * f.height / Float(nv))
                    if cams.contains(where: { $0.sees(p, normal: f.normal) }) { covered += 1 }
                }
            }
            let left = f.world(u: 0, v: 0), right = f.world(u: f.width, v: 0)
            walls.append(.init(id: i, a: SIMD2(left.x, left.z), b: SIMD2(right.x, right.z), length: f.width,
                               fraction: Float(covered) / Float(nu * nv)))
        }

        let total = walls.reduce(Float(0)) { $0 + $1.length }
        let overall = total > 0 ? walls.reduce(Float(0)) { $0 + $1.fraction * $1.length } / total : 0
        // Tuned on a real scan: walls about 70% covered already showed clear gray gaps.
        let weak = walls.filter { $0.length > 0.6 && $0.fraction < 0.7 }
        var hint: String?
        if let worst = walls.filter({ $0.length > 0.6 && $0.fraction < 0.85 }).min(by: { $0.fraction < $1.fraction }) {
            hint = "Point at the red wall \(direction(of: (worst.a + worst.b) / 2, from: flatCam, heading: heading)) "
                + "(\(Int(worst.fraction * 100))%)"
        } else if !walls.isEmpty {
            hint = "Every wall is well covered."
        }
        return CoverageSnapshot(walls: walls, camera: flatCam, heading: heading, overall: overall, hint: hint,
                                weakWalls: weak.count)
    }

    /// "ahead", "to your left", "to your right" or "behind you", as the phone points now.
    private static func direction(of p: SIMD2<Float>, from cam: SIMD2<Float>, heading: SIMD2<Float>) -> String {
        let d = p - cam
        guard simd_length(d) > 1e-3 else { return "here" }
        let u = simd_normalize(d)
        let ahead = simd_dot(u, heading)
        // Top view with x right and z toward the viewer: positive cross is clockwise, to the right.
        let cross = heading.x * u.y - heading.y * u.x
        if ahead > 0.8 { return "ahead" }
        if ahead < -0.35 { return "behind you" }
        return cross > 0 ? "to your right" : "to your left"
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

        func sees(_ p: SIMD3<Float>, normal: SIMD3<Float>) -> Bool {
            let toCam = position - p
            let dist = simd_length(toCam)
            guard dist > 0.3, dist < 5, simd_dot(toCam / dist, normal) > 0.25 else { return false }
            let c = inverse * SIMD4(p, 1)
            let depth = -c.z
            guard depth > 0.3 else { return false }
            let x = cx + fx * c.x / depth, y = cy - fy * c.y / depth
            return x > w * 0.04 && x < w * 0.96 && y > h * 0.04 && y < h * 0.96
        }
    }
}

/// The walls from above, turned so the way the phone points is up, coloured by coverage.
struct CoverageMap: View {
    let snapshot: CoverageSnapshot

    var body: some View {
        VStack(spacing: 4) {
            Canvas { ctx, size in
                let s = snapshot
                // Turn so the heading points up the screen, and fit the walls around the phone.
                let angle = atan2(s.heading.y, s.heading.x)
                let phi = -Float.pi / 2 - angle
                let cs = cos(phi), sn = sin(phi)
                func rel(_ p: SIMD2<Float>) -> SIMD2<Float> {
                    let d = p - s.camera
                    return SIMD2(cs * d.x - sn * d.y, sn * d.x + cs * d.y)
                }
                let reach = s.walls.flatMap { [rel($0.a), rel($0.b)] }.map { Swift.max(abs($0.x), abs($0.y)) }.max() ?? 3
                let scale = CGFloat(Float(Swift.min(size.width, size.height)) / 2 / Swift.max(1.5, Swift.min(reach, 7)) * 0.92)
                let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                func pt(_ p: SIMD2<Float>) -> CGPoint {
                    let r = rel(p)
                    return CGPoint(x: mid.x + CGFloat(r.x) * scale, y: mid.y + CGFloat(r.y) * scale)
                }
                for w in s.walls {
                    var path = Path()
                    path.move(to: pt(w.a))
                    path.addLine(to: pt(w.b))
                    let hue = Double(Swift.min(1, w.fraction / 0.9)) * 0.33  // red .. green at 90%
                    ctx.stroke(path, with: .color(Color(hue: hue, saturation: 0.9, brightness: 0.95)),
                               style: StrokeStyle(lineWidth: 4, lineCap: .round))
                }
                var wedge = Path()
                wedge.move(to: mid)
                wedge.addLine(to: CGPoint(x: mid.x - 9, y: mid.y - 18))
                wedge.addLine(to: CGPoint(x: mid.x + 9, y: mid.y - 18))
                wedge.closeSubpath()
                ctx.fill(wedge, with: .color(.white.opacity(0.5)))
                ctx.fill(Path(ellipseIn: CGRect(x: mid.x - 4, y: mid.y - 4, width: 8, height: 8)), with: .color(.white))
            }
            .frame(width: 130, height: 130)
            Text("Wall photos \(Int(snapshot.overall * 100))%").font(.caption2.weight(.semibold))
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}
