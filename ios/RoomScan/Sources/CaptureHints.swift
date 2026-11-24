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
                       keyframes: [Keyframe], meshPass: Bool) -> String? {
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
        if speed > 0.7 || turnRate > 1.2 || blurrySkipsRecently >= 3 { return "Slow down: photos are blurring." }
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
