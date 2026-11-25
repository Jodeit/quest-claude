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

    /// A 30 cm patch of wall (its corners in the world) and whether a kept frame has seen it.
    struct Cell {
        let corners: [SIMD3<Float>]
        let covered: Bool
    }

    var walls: [Wall]
    var cells: [Cell] = []
    var camera: SIMD2<Float>
    var heading: SIMD2<Float>  // where the phone points, top view, unit length
    var overall: Float         // length-weighted
    var hint: String?
    var weakWalls: Int         // longer than 60 cm and under 70% covered
    var label = "Wall photos"  // what the percentage is of
    /// Share of the floor within 2 m of the phone that some kept photo has seen, nil before any floor
    /// is known. The 360 views fill unseen floor by copying seen floor, which is where they go wrong.
    var floorNear: Float?
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
        var cells: [CoverageSnapshot.Cell] = []
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
            let du = f.width / Float(nu), dv = f.height / Float(nv)
            for a in 0..<nu {
                for b in 0..<nv {
                    let p = f.world(u: (Float(a) + 0.5) * du, v: (Float(b) + 0.5) * dv)
                    let seen = cams.contains(where: { $0.sees(p, normal: f.normal) })
                    if seen { covered += 1 }
                    // A hair off the wall, toward the room, so it's drawn in front of it.
                    let lift = f.normal * 0.01
                    let u0 = Float(a) * du, u1 = u0 + du, v0 = Float(b) * dv, v1 = v0 + dv
                    cells.append(.init(corners: [f.world(u: u0, v: v0) + lift, f.world(u: u1, v: v0) + lift,
                                                 f.world(u: u1, v: v1) + lift, f.world(u: u0, v: v1) + lift],
                                       covered: seen))
                }
            }
            let left = f.world(u: 0, v: 0), right = f.world(u: f.width, v: 0)
            walls.append(.init(id: i, a: SIMD2(left.x, left.z), b: SIMD2(right.x, right.z), length: f.width,
                               fraction: Float(covered) / Float(nu * nv)))
        }

        let floor = floorCells(room: room, cams: cams, around: camPos)
        cells += floor.cells

        let total = walls.reduce(Float(0)) { $0 + $1.length }
        let overall = total > 0 ? walls.reduce(Float(0)) { $0 + $1.fraction * $1.length } / total : 0
        // Tuned on a real scan: walls about 70% covered already showed clear gray gaps.
        let weak = walls.filter { $0.length > 0.6 && $0.fraction < 0.7 }
        var hint: String?
        if let worst = walls.filter({ $0.length > 0.6 && $0.fraction < 0.85 }).min(by: { $0.fraction < $1.fraction }) {
            hint = "Point at the red wall \(direction(of: (worst.a + worst.b) / 2, from: flatCam, heading: heading)) "
                + "(\(Int(worst.fraction * 100))%)"
        } else if let f = floor.fraction, f < floorHintBelow {
            hint = floorHint
        } else if !walls.isEmpty {
            hint = "Every wall is well covered."
        }
        return CoverageSnapshot(walls: walls, cells: cells, camera: flatCam, heading: heading, overall: overall, hint: hint,
                                weakWalls: weak.count, floorNear: floor.fraction)
    }

    /// For the photo-real pass: how much of each RoomPlan wall the LiDAR mesh has reached, on a 10 cm
    /// grid (a cell counts once a mesh vertex lies within 6 cm of the wall there; doors, windows and
    /// openings left out). On a real scan the closet walls came out 66-83% covered while the main walls
    /// were 86-100%: this is what points the scanner back at them. `points` in RoomPlan's coordinates.
    /// The floor around the phone is judged from the kept photos (`frames`), as in `compute`.
    static func fromMesh(room: CapturedRoom, points: [SIMD3<Float>], frames: [Keyframe], camera: simd_float4x4) -> CoverageSnapshot {
        let camPos = simd_make_float3(camera.columns.3)
        let flatCam = SIMD2(camPos.x, camPos.z)
        var heading = SIMD2(-camera.columns.2.x, -camera.columns.2.z)
        heading = simd_length(heading) > 1e-4 ? simd_normalize(heading) : SIMD2(0, -1)
        let centres = room.walls.map { simd_make_float3($0.transform.columns.3) }
        let centroid = centres.isEmpty ? SIMD3<Float>(0, 0, 0) : centres.reduce(.zero, +) / Float(centres.count)
        let holes = room.doors + room.windows + room.openings
        let step: Float = 0.1
        var walls: [CoverageSnapshot.Wall] = [], cells: [CoverageSnapshot.Cell] = []
        for (i, w) in room.walls.enumerated() where w.dimensions.x > 0.3 && w.dimensions.y > 0.3 {
            let c = simd_make_float3(w.transform.columns.3), z = simd_make_float3(w.transform.columns.2)
            let f = WallFrame(w, flipped: simd_dot(centroid - c, z) < 0)
            let nu = Swift.max(1, Int(f.width / step)), nv = Swift.max(1, Int(f.height / step))
            var hit = [Bool](repeating: false, count: nu * nv)
            for p in points {
                let l = f.local(p)
                guard abs(l.depth) < 0.06, l.u >= 0, l.u < f.width, l.v >= 0, l.v < f.height else { continue }
                hit[Swift.min(nv - 1, Int(l.v / step)) * nu + Swift.min(nu - 1, Int(l.u / step))] = true
            }
            var covered = 0, counted = 0
            for a in 0..<nu {
                for b in 0..<nv {
                    let u0 = Float(a) * f.width / Float(nu), u1 = u0 + f.width / Float(nu)
                    let v0 = Float(b) * f.height / Float(nv), v1 = v0 + f.height / Float(nv)
                    let mid = f.world(u: (u0 + u1) / 2, v: (v0 + v1) / 2)
                    let inHole = holes.contains { h in
                        let hc = simd_make_float3(h.transform.columns.3), hx = simd_normalize(simd_make_float3(h.transform.columns.0))
                        return abs(simd_dot(hc - c, f.normal)) < 0.3 && abs(simd_dot(mid - hc, hx)) < h.dimensions.x / 2
                            && abs(mid.y - hc.y) < h.dimensions.y / 2
                    }
                    if inHole { continue }
                    counted += 1
                    let seen = hit[b * nu + a]
                    if seen { covered += 1 }
                    let lift = f.normal * 0.01
                    cells.append(.init(corners: [f.world(u: u0, v: v0) + lift, f.world(u: u1, v: v0) + lift,
                                                 f.world(u: u1, v: v1) + lift, f.world(u: u0, v: v1) + lift], covered: seen))
                }
            }
            let left = f.world(u: 0, v: 0), right = f.world(u: f.width, v: 0)
            walls.append(.init(id: i, a: SIMD2(left.x, left.z), b: SIMD2(right.x, right.z), length: f.width,
                               fraction: counted > 0 ? Float(covered) / Float(counted) : 1))
        }
        let floor = floorCells(room: room, cams: frames.map(Cam.init), around: camPos)
        cells += floor.cells
        let total = walls.reduce(Float(0)) { $0 + $1.length }
        let overall = total > 0 ? walls.reduce(Float(0)) { $0 + $1.fraction * $1.length } / total : 0
        var hint: String?
        if let worst = walls.filter({ $0.length > 0.6 && $0.fraction < 0.85 }).min(by: { $0.fraction < $1.fraction }) {
            hint = "Fill in the wall \(direction(of: (worst.a + worst.b) / 2, from: flatCam, heading: heading)): "
                + "the 3D scan has gaps there (\(Int(worst.fraction * 100))%). Go closer, into corners and shelves."
        } else if let f = floor.fraction, f < floorHintBelow {
            hint = floorHint
        } else if !walls.isEmpty {
            hint = "The walls are well covered. Sweep any shelves and furniture you'll want to measure, then Finish."
        }
        return CoverageSnapshot(walls: walls, cells: cells, camera: flatCam, heading: heading, overall: overall, hint: hint,
                                weakWalls: walls.filter { $0.length > 0.6 && $0.fraction < 0.7 }.count, label: "3D scan",
                                floorNear: floor.fraction)
    }

    private static let floorReach: Float = 2
    private static let floorHintBelow: Float = 0.6
    private static let floorHint = "Tip the phone down and sweep the floor around you: it stays gray until a photo has seen it."

    /// 30 cm floor cells within `floorReach` of the phone (inside RoomPlan's floor outline, or the
    /// walls' box when there is none), each covered once a kept frame saw it from above; and the
    /// covered share, nil when there are no cells.
    private static func floorCells(room: CapturedRoom, cams: [Cam], around camPos: SIMD3<Float>)
        -> (cells: [CoverageSnapshot.Cell], fraction: Float?) {
        guard !room.walls.isEmpty else { return ([], nil) }
        let floorY = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0
        var outlines: [[SIMD2<Float>]] = []
        for f in room.floors where f.polygonCorners.count >= 3 {
            let t = f.transform
            let o = simd_make_float3(t.columns.3), ax = simd_make_float3(t.columns.0), ay = simd_make_float3(t.columns.1)
            outlines.append(f.polygonCorners.map { c in
                let w = o + c.x * ax + c.y * ay
                return SIMD2(w.x, w.z)
            })
        }
        var lo = SIMD2<Float>(repeating: .greatestFiniteMagnitude)
        var hi = -lo
        for w in room.walls {
            let c = simd_make_float3(w.transform.columns.3), x = simd_make_float3(w.transform.columns.0)
            for e in [c - x * w.dimensions.x / 2, c + x * w.dimensions.x / 2] {
                lo = simd_min(lo, SIMD2(e.x, e.z)); hi = simd_max(hi, SIMD2(e.x, e.z))
            }
        }
        func inside(_ p: SIMD2<Float>) -> Bool {
            if outlines.isEmpty { return p.x > lo.x && p.x < hi.x && p.y > lo.y && p.y < hi.y }
            return outlines.contains { poly in
                var inPoly = false
                var j = poly.count - 1
                for i in 0..<poly.count {
                    let a = poly[i], b = poly[j]
                    if (a.y > p.y) != (b.y > p.y), p.x < (b.x - a.x) * (p.y - a.y) / (b.y - a.y) + a.x { inPoly.toggle() }
                    j = i
                }
                return inPoly
            }
        }
        let up = SIMD3<Float>(0, 1, 0)
        let n = Int(ceil(floorReach / cell))
        let gx = (camPos.x / cell).rounded(.down), gz = (camPos.z / cell).rounded(.down)
        var cells: [CoverageSnapshot.Cell] = []
        var covered = 0
        for i in -n...n {
            for j in -n...n {
                let x0 = (gx + Float(i)) * cell, z0 = (gz + Float(j)) * cell
                let mid = SIMD2(x0 + cell / 2, z0 + cell / 2)
                guard simd_distance(mid, SIMD2(camPos.x, camPos.z)) < floorReach, inside(mid) else { continue }
                let p = SIMD3(mid.x, floorY, mid.y)
                let seen = cams.contains { $0.sees(p, normal: up) }
                if seen { covered += 1 }
                let y = floorY + 0.01  // a hair above the floor, so it's drawn over it
                cells.append(.init(corners: [SIMD3(x0, y, z0), SIMD3(x0 + cell, y, z0),
                                             SIMD3(x0 + cell, y, z0 + cell), SIMD3(x0, y, z0 + cell)], covered: seen))
            }
        }
        return (cells, cells.isEmpty ? nil : Float(covered) / Float(cells.count))
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
            Text("\(snapshot.label) \(Int(snapshot.overall * 100))%").font(.caption2.weight(.semibold))
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
    }
}

/// The photo-real pass's stop as a ring that turns with the phone (the way it points is up): the
/// 30-degree sectors already photographed in green, and whether the floor and ceiling have been
/// looked at. Done only when all three are.
struct StopRing: View {
    let progress: StopProgress

    var body: some View {
        VStack(spacing: 6) {
            ZStack {
                Canvas { ctx, size in
                    let n = StopTracker.sectorCount
                    let mid = CGPoint(x: size.width / 2, y: size.height / 2)
                    let radius = Swift.min(size.width, size.height) / 2 - 7
                    // Same top view as the coverage map (x right, z down the screen), turned so the
                    // phone's heading points up. A yaw of y faces (sin y, cos y) there.
                    let h = SIMD2(sin(progress.yaw), cos(progress.yaw))
                    let phi = -Float.pi / 2 - atan2(h.y, h.x)
                    let cs = cos(phi), sn = sin(phi)
                    let half = Angle.degrees(180 / Double(n) - 2)
                    for s in 0..<n {
                        let yaw = (Float(s) + 0.5) / Float(n) * 2 * Float.pi - Float.pi
                        let d = SIMD2(sin(yaw), cos(yaw))
                        let r = SIMD2(cs * d.x - sn * d.y, sn * d.x + cs * d.y)
                        let a = Angle.radians(Double(atan2(r.y, r.x)))
                        var arc = Path()
                        arc.addArc(center: mid, radius: radius, startAngle: a - half, endAngle: a + half, clockwise: false)
                        let done = progress.sectors.contains(s)
                        ctx.stroke(arc, with: .color(done ? .green : .white.opacity(0.3)),
                                   style: StrokeStyle(lineWidth: 10, lineCap: .butt))
                    }
                    var wedge = Path()
                    wedge.move(to: CGPoint(x: mid.x, y: mid.y - radius + 9))
                    wedge.addLine(to: CGPoint(x: mid.x - 7, y: mid.y - radius + 22))
                    wedge.addLine(to: CGPoint(x: mid.x + 7, y: mid.y - radius + 22))
                    wedge.closeSubpath()
                    ctx.fill(wedge, with: .color(.white))
                }
                VStack(spacing: 0) {
                    Text("Spot \(progress.id)").font(.caption2.weight(.semibold))
                    Text(progress.complete ? "Done" : "\(progress.percent)%").font(.caption.weight(.bold))
                        .foregroundStyle(progress.complete ? Color.green : Color.primary)
                }
            }
            .frame(width: 110, height: 110)
            HStack(spacing: 8) {
                Label("Floor", systemImage: progress.down ? "checkmark.circle.fill" : "arrow.down.circle")
                    .foregroundStyle(progress.down ? Color.green : Color.primary)
                Label("Ceiling", systemImage: progress.up ? "checkmark.circle.fill" : "arrow.up.circle")
                    .foregroundStyle(progress.up ? Color.green : Color.primary)
            }
            .font(.caption2.weight(.semibold))
            .labelStyle(.titleAndIcon)
        }
        .padding(8)
        .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 14))
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Spot \(progress.id): \(progress.percent)% of the way round, floor \(progress.down ? "done" : "not yet"), "
                            + "ceiling \(progress.up ? "done" : "not yet")")
    }
}
