import ARKit
import CoreImage
import RoomPlan
import simd

/// What to tell the person scanning, most urgent first, from what went wrong in real scans: tracking
/// trouble, a fingertip over the lens, a dark room, moving too fast for sharp photos, and storage
/// units nobody has faced straight on yet (their shelf sizes come from that view).
struct CaptureHints {
    /// The camera picture right now: how bright, and whether an edge looks like a fingertip.
    struct Look { var brightness: Float; var fingertip: Bool }

    private var lastPose: simd_float4x4?
    private var lastTime: TimeInterval = 0
    private var speed: Float = 0, turnRate: Float = 0

    /// Called about four times a second.
    mutating func hint(frame: ARFrame, look: Look?, blurrySkipsRecently: Int, room: CapturedRoom?,
                       keyframes: [Keyframe], meshPass: Bool, inStop: Bool = false, stopHint: String? = nil) -> String? {
        let pose = frame.camera.transform
        if let last = lastPose, frame.timestamp > lastTime {
            let dt = Float(frame.timestamp - lastTime)
            let move = simd_distance(simd_make_float3(last.columns.3), simd_make_float3(pose.columns.3)) / dt
            let a = simd_normalize(-simd_make_float3(last.columns.2)), b = simd_normalize(-simd_make_float3(pose.columns.2))
            let turn = acos(Swift.min(1, Swift.max(-1, simd_dot(a, b)))) / dt
            speed = 0.6 * speed + 0.4 * move          // smoothed, metres per second
            turnRate = 0.6 * turnRate + 0.4 * turn    // radians per second
        }
        lastPose = pose
        lastTime = frame.timestamp

        switch frame.camera.trackingState {
        case .limited(.excessiveMotion): return "Slow down: the camera is losing its place."
        case .limited(.insufficientFeatures): return "Point at something with more detail: a blank wall gives the camera nothing to hold on to."
        case .limited(.relocalizing): return "Hold still and point back where you were: the camera is finding its place again."
        case .notAvailable: return "Tracking isn't available right now."
        default: break
        }
        if let look {
            if look.fingertip { return "Your finger is over the camera: hold the phone by its edges." }
            if look.brightness < 45 { return "It's dark here: turn on a light for better photos." }
        }
        // A deliberate slow spin on the spot (up to about 0.6 rad/s) is fine; only flag it above 1.0.
        let slowSpin = inStop && turnRate <= 0.7
        let tooFast = speed > 0.7 || turnRate > (inStop ? 1.0 : 1.2) || (blurrySkipsRecently >= 3 && !slowSpin)
        if tooFast { return "Slow down: photos are blurring." }
        if let stopHint { return stopHint }
        if let room, let missing = storageWithoutFront(room: room, keyframes: keyframes, from: pose) {
            return "Stand about a metre in front of the storage \(missing) and hold still: that's what gives shelf sizes."
        }
        return nil
    }

    /// The direction of a storage unit no kept frame has seen straight on from within 1.8 m, if any.
    private func storageWithoutFront(room: CapturedRoom, keyframes: [Keyframe], from pose: simd_float4x4) -> String? {
        let cams = keyframes.map { k -> (SIMD3<Float>, SIMD3<Float>) in
            let p = k.pose
            return (simd_make_float3(p.columns.3), simd_normalize(-simd_make_float3(p.columns.2)))
        }
        for o in room.objects where o.category == .storage {
            let c = simd_make_float3(o.transform.columns.3)
            var z = simd_make_float3(o.transform.columns.2); z.y = 0
            guard simd_length(z) > 1e-4 else { continue }
            z = simd_normalize(z)
            let seen = cams.contains { cam in
                let pos = cam.0, fwd = cam.1
                var to = c - pos; to.y = 0
                let d = simd_length(to)
                guard d > 0.3, d < 1.8 else { return false }
                return abs(simd_dot(-to / d, z)) > 0.8 && simd_dot(fwd, simd_normalize(c - pos)) > 0.8
            }
            if !seen { return direction(of: c, from: pose) }
        }
        return nil
    }

    private func direction(of p: SIMD3<Float>, from pose: simd_float4x4) -> String {
        let cam = simd_make_float3(pose.columns.3)
        var fwd = -simd_make_float3(pose.columns.2); fwd.y = 0
        var to = p - cam; to.y = 0
        guard simd_length(fwd) > 1e-4, simd_length(to) > 0.2 else { return "unit here" }
        fwd = simd_normalize(fwd); to = simd_normalize(to)
        let ahead = simd_dot(to, fwd)
        let cross = fwd.x * to.z - fwd.z * to.x  // top view, x right and z toward you: positive is to the right
        if ahead > 0.8 { return "unit ahead" }
        if ahead < -0.35 { return "unit behind you" }
        return cross > 0 ? "unit to your right" : "unit to your left"
    }

    /// Brightness and a fingertip check on a 64-pixel-wide copy of the camera image: an edge band (a
    /// fifth of the picture) more than 15% skin-coloured, the same colour test the elevations use.
    static func look(_ buffer: CVPixelBuffer, context: CIContext) -> Look {
        let image = CIImage(cvPixelBuffer: buffer)
        let s = 64 / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 8, h > 8 else { return Look(brightness: 128, fingertip: false) }
        var px = [UInt8](repeating: 0, count: w * h * 4)
        context.render(small, toBitmap: &px, rowBytes: w * 4, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .RGBA8, colorSpace: CGColorSpace(name: CGColorSpace.sRGB))
        var sum: Float = 0
        func skin(_ x0: Int, _ x1: Int, _ y0: Int, _ y1: Int) -> Bool {
            var hits = 0, n = 0
            for y in y0..<y1 { for x in x0..<x1 {
                let o = (y * w + x) * 4
                let r = Int(px[o]), g = Int(px[o + 1]), b = Int(px[o + 2])
                if r > 120, r - g > 35, abs(g - b) < 30, r - b > 35 { hits += 1 }
                n += 1
            } }
            return n > 0 && Float(hits) / Float(n) > 0.15
        }
        for i in Swift.stride(from: 0, to: px.count, by: 4) {
            sum += 0.299 * Float(px[i]) + 0.587 * Float(px[i + 1]) + 0.114 * Float(px[i + 2])
        }
        let bw = w / 5, bh = h / 5
        let finger = skin(0, bw, 0, h) || skin(w - bw, w, 0, h) || skin(0, w, 0, bh) || skin(0, w, h - bh, h)
        return Look(brightness: sum / Float(w * h), fingertip: finger)
    }
}

/// Matterport-style stops for the photo-real pass: staying put (under 45 cm across the floor for
/// 1.5 s; height is ignored, so raising, lowering or swinging the phone round at arm's length keeps
/// the stop) starts a stop with the next id, or the earlier id when it is back within 60 cm of an
/// earlier stop; while it lasts, the heading is tracked in 30-degree sectors so the person
/// can be told how far round they have turned. Frames kept during a stop carry its id.
/// Where a stop stands, for the ring on the scan screen: the 30-degree sectors turned through (of
/// `StopTracker.sectorCount`), whether the floor and the ceiling have been looked at, and the
/// phone's heading now (radians, the same zero as the sectors).
struct StopProgress: Equatable {
    var id: Int
    var sectors: Set<Int>
    var up: Bool
    var down: Bool
    var yaw: Float
    var percent: Int
    var complete: Bool
}

struct StopTracker {
    private(set) var stopId = 0
    private(set) var inStop = false
    private var anchor: SIMD3<Float>?
    private var stopSpots: [(id: Int, at: SIMD2<Float>)] = []
    private var anchorTime: TimeInterval = 0
    private var sectors = Set<Int>()
    private var sweptUp = false
    private var sweptDown = false
    private var yaw: Float = 0
    private var offLevel = 0
    private var tiltHintShown = false
    private var tiltHintUntil: TimeInterval = 0

    static let sectorCount = 12
    static let levelLimit: Float = 35 * Float.pi / 180

    /// Share of the full turn covered so far, 0...100.
    var percent: Int { Swift.min(100, sectors.count * 100 / StopTracker.sectorCount) }
    /// 300 degrees (ten sectors) turned through, and the floor and ceiling looked at: the 360 view
    /// at a spot invents whatever its photos missed, and the floor around the feet is the usual gap.
    var turned: Bool { sectors.count >= 10 }
    var complete: Bool { turned && sweptUp && sweptDown }

    /// The ring's state, nil when not at a stop.
    var progress: StopProgress? {
        guard inStop else { return nil }
        return StopProgress(id: stopId, sectors: sectors, up: sweptUp, down: sweptDown, yaw: yaw, percent: percent,
                            complete: complete)
    }

    mutating func reset() {
        stopId = 0
        endStop()
        anchor = nil
        stopSpots = []
    }

    mutating func endStop() {
        inStop = false
        sectors = Set<Int>()
        sweptUp = false
        sweptDown = false
        offLevel = 0
        tiltHintShown = false
        tiltHintUntil = 0
    }

    /// Camera yaw (radians, any consistent zero) and pitch (up positive) from a pose.
    static func yawPitch(_ pose: simd_float4x4) -> (yaw: Float, pitch: Float) {
        let f = simd_normalize(-simd_make_float3(pose.columns.2))
        return (atan2(f.x, f.z), asin(Swift.min(1, Swift.max(-1, f.y))))
    }

    /// Called about four times a second with the camera pose and the frame's timestamp.
    mutating func update(pose: simd_float4x4, time: TimeInterval) {
        let pos = simd_make_float3(pose.columns.3)
        guard let a = anchor else {
            anchor = pos
            anchorTime = time
            return
        }
        if simd_distance(SIMD2(a.x, a.z), SIMD2(pos.x, pos.z)) > 0.45 {
            if inStop { endStop() }
            anchor = pos
            anchorTime = time
            return
        }
        if !inStop {
            guard time - anchorTime >= 1.5 else { return }
            let here = SIMD2(a.x, a.z)
            if let back = stopSpots.first(where: { simd_distance($0.at, here) < 0.6 }) {
                stopId = back.id
            } else {
                stopId = (stopSpots.map(\.id).max() ?? 0) + 1
                stopSpots.append((stopId, here))
            }
            inStop = true
        }
        let yp = StopTracker.yawPitch(pose)
        yaw = yp.yaw
        if yp.pitch > StopTracker.levelLimit {
            sweptUp = true
            offLevel += 1
        } else if yp.pitch < -StopTracker.levelLimit {
            sweptDown = true
            offLevel += 1
        } else {
            // Only roughly level frames count toward the turn.
            let sector = Int(floor((yp.yaw + Float.pi) / (2 * Float.pi) * Float(StopTracker.sectorCount)))
            sectors.insert(((sector % StopTracker.sectorCount) + StopTracker.sectorCount) % StopTracker.sectorCount)
        }
        if !tiltHintShown, !(sweptUp && sweptDown), sectors.count >= 6 || offLevel >= 12 {
            tiltHintShown = true
            tiltHintUntil = time + 4
        }
    }

    /// What to say now, or nil when not at a stop.
    func message(time: TimeInterval) -> String? {
        guard inStop else { return nil }
        if complete { return "Good. Walk to the next spot, about 4 steps" }
        if turned {
            let missing = [sweptDown ? nil : "down at the floor round your feet", sweptUp ? nil : "up at the ceiling"]
                .compactMap { $0 }.joined(separator: " and ")
            return "All the way round. Now tilt \(missing)."
        }
        if time < tiltHintUntil { return "Tilt up a little to catch the ceiling and down for the floor." }
        return "Turn slowly on the spot: \(percent)% around"
    }
}
