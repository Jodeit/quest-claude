import ARKit
import CoreImage
import UIKit
import simd

/// Paints the parts of the walls no kept frame has photographed yet in black and white over the
/// live camera, so the room colours in as you scan. About 15 times a second: projects the uncovered
/// 30 cm cells from the latest coverage onto the screen as a mask, and fills it with a grayscale
/// copy of the same camera frame, laid out the way the camera view shows it.
///
/// It shares the phone with RoomPlan, so each tick is kept cheap: one view-projection matrix per
/// frame instead of a projection call per corner, no arrays per cell, cells off screen or behind
/// the phone dropped before they reach the mask, a frame already drawn skipped, and the gray copy
/// read back as one 8-bit channel with no colour management. The mask and the gray image are put
/// on screen together, both from the same camera frame, so the gray never lags the walls.
final class CoverageOverlay: UIView {
    var snapshot: CoverageSnapshot?
    weak var session: ARSession?

    private let gray = CALayer()
    private let shape = CAShapeLayer()
    private var link: CADisplayLink?
    private let context = CIContext(options: [.cacheIntermediates: false, .workingColorSpace: NSNull(),
                                              .outputColorSpace: NSNull(), .priorityRequestLow: true])
    private let grayColorSpace = CGColorSpaceCreateDeviceGray()
    private var busy = false
    private var lastTimestamp: TimeInterval = -1

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gray.contentsGravity = .resize
        gray.mask = shape
        layer.addSublayer(gray)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gray.frame = bounds
        shape.frame = bounds
    }

    func start() {
        guard link == nil else { return }
        let l = CADisplayLink(target: self, selector: #selector(tick))
        l.preferredFrameRateRange = CAFrameRateRange(minimum: 10, maximum: 15, preferred: 15)
        l.add(to: .main, forMode: .common)
        link = l
    }

    func stop() {
        link?.invalidate()
        link = nil
        gray.contents = nil
        shape.path = nil
        snapshot = nil
        lastTimestamp = -1
    }

    @objc private func tick() {
        guard !isHidden, !busy, let frame = session?.currentFrame, frame.timestamp != lastTimestamp,
              let snapshot else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        lastTimestamp = frame.timestamp
        let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
        let camera = frame.camera
        let position = simd_make_float3(camera.transform.columns.3)
        let view = camera.viewMatrix(for: orientation)
        let viewProjection = camera.projectionMatrix(for: orientation, viewportSize: size, zNear: 0.05, zFar: 20) * view
        let w = Float(size.width), h = Float(size.height)

        let path = CGMutablePath()
        for gap in snapshot.gaps {
            // Within 6 m, wholly in front of the camera (others project wrongly or don't matter)...
            guard simd_distance_squared(gap.a, position) < 36 else { continue }
            let pa = viewProjection * SIMD4(gap.a, 1), pb = viewProjection * SIMD4(gap.b, 1)
            let pc = viewProjection * SIMD4(gap.c, 1), pd = viewProjection * SIMD4(gap.d, 1)
            // (clip w is the depth in front of the camera)
            guard pa.w > 0.15, pb.w > 0.15, pc.w > 0.15, pd.w > 0.15 else { continue }
            let sa = Self.screen(pa, w, h), sb = Self.screen(pb, w, h), sc = Self.screen(pc, w, h), sd = Self.screen(pd, w, h)
            // ...and on screen.
            let lo = simd_min(simd_min(sa, sb), simd_min(sc, sd)), hi = simd_max(simd_max(sa, sb), simd_max(sc, sd))
            guard hi.x > 0, hi.y > 0, lo.x < w, lo.y < h else { continue }
            path.move(to: CGPoint(x: CGFloat(sa.x), y: CGFloat(sa.y)))
            path.addLine(to: CGPoint(x: CGFloat(sb.x), y: CGFloat(sb.y)))
            path.addLine(to: CGPoint(x: CGFloat(sc.x), y: CGFloat(sc.y)))
            path.addLine(to: CGPoint(x: CGFloat(sd.x), y: CGFloat(sd.y)))
            path.closeSubpath()
        }
        if path.isEmpty {
            CATransaction.begin()
            CATransaction.setDisableActions(true)
            shape.path = nil
            gray.contents = nil
            CATransaction.commit()
            return
        }

        // The same frame in gray, mapped onto the screen as the camera view shows it.
        busy = true
        let buffer = frame.capturedImage
        let display = frame.displayTransform(for: orientation, viewportSize: size)
        let portrait = orientation.isPortrait
        let ctx = context, space = grayColorSpace
        let mask = path.copy()
        Task.detached(priority: .userInitiated) { [weak self] in
            let bw = CGFloat(CVPixelBufferGetWidth(buffer)), bh = CGFloat(CVPixelBufferGetHeight(buffer))
            let normalize = CGAffineTransform(scaleX: 1 / bw, y: 1 / bh)
            let flip = portrait ? CGAffineTransform(scaleX: -1, y: -1).translatedBy(x: -1, y: -1) : .identity
            let toView = CGAffineTransform(scaleX: size.width, y: size.height)
            let rect = CGRect(origin: .zero, size: size)
            let image = CIImage(cvPixelBuffer: buffer)
                .applyingFilter("CIPhotoEffectMono")
                .transformed(by: normalize.concatenating(flip).concatenating(display).concatenating(toView))
                .cropped(to: rect)
            let cg = ctx.createCGImage(image, from: rect, format: .L8, colorSpace: space)
            await MainActor.run {
                guard let self else { return }
                self.busy = false
                guard self.link != nil else { return }  // stopped meanwhile
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.shape.path = mask
                self.gray.contents = cg
                CATransaction.commit()
            }
        }
    }

    /// Clip space to view points (y down).
    private static func screen(_ p: SIMD4<Float>, _ w: Float, _ h: Float) -> SIMD2<Float> {
        SIMD2((p.x / p.w + 1) / 2 * w, (1 - p.y / p.w) / 2 * h)
    }
}
