import ARKit
import CoreImage
import UIKit
import simd

/// Paints the parts of the walls no kept frame has photographed yet in black and white over the
/// live camera, so the room colours in as you scan. About 15 times a second: projects the uncovered
/// 30 cm cells from the latest coverage onto the screen as a mask, and fills it with a grayscale
/// copy of the same camera frame, laid out the way the camera view shows it.
final class CoverageOverlay: UIView {
    var snapshot: CoverageSnapshot?
    weak var session: ARSession?

    private let gray = CALayer()
    private let mask = CAShapeLayer()
    private var link: CADisplayLink?
    private let context = CIContext(options: [.cacheIntermediates: false])
    private var busy = false

    override init(frame: CGRect) {
        super.init(frame: frame)
        isUserInteractionEnabled = false
        gray.contentsGravity = .resize
        gray.mask = mask
        layer.addSublayer(gray)
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    override func layoutSubviews() {
        super.layoutSubviews()
        gray.frame = bounds
        mask.frame = bounds
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
        mask.path = nil
        snapshot = nil
    }

    @objc private func tick() {
        guard !isHidden, !busy, let frame = session?.currentFrame, let snapshot else { return }
        let size = bounds.size
        guard size.width > 0, size.height > 0 else { return }
        let orientation = window?.windowScene?.interfaceOrientation ?? .portrait
        let camera = frame.camera
        let position = simd_make_float3(camera.transform.columns.3)
        let forward = -simd_make_float3(camera.transform.columns.2)

        let path = UIBezierPath()
        for cell in snapshot.cells where !cell.covered {
            // Only cells wholly in front of the camera and within 6 m (others project wrongly or don't matter).
            guard cell.corners.allSatisfy({ simd_dot($0 - position, forward) > 0.15 }),
                  simd_distance(cell.corners[0], position) < 6 else { continue }
            let pts = cell.corners.map { camera.projectPoint($0, orientation: orientation, viewportSize: size) }
            path.move(to: pts[0])
            for p in pts.dropFirst() { path.addLine(to: p) }
            path.close()
        }
        CATransaction.begin()
        CATransaction.setDisableActions(true)
        mask.path = path.cgPath
        CATransaction.commit()
        if path.isEmpty {
            gray.contents = nil
            return
        }

        // The same frame in gray, mapped onto the screen as the camera view shows it.
        busy = true
        let buffer = frame.capturedImage
        let display = frame.displayTransform(for: orientation, viewportSize: size)
        let portrait = orientation.isPortrait
        let ctx = context
        Task.detached(priority: .userInitiated) { [weak self] in
            let w = CGFloat(CVPixelBufferGetWidth(buffer)), h = CGFloat(CVPixelBufferGetHeight(buffer))
            let normalize = CGAffineTransform(scaleX: 1 / w, y: 1 / h)
            let flip = portrait ? CGAffineTransform(scaleX: -1, y: -1).translatedBy(x: -1, y: -1) : .identity
            let toView = CGAffineTransform(scaleX: size.width, y: size.height)
            let image = CIImage(cvPixelBuffer: buffer)
                .applyingFilter("CIPhotoEffectMono")
                .transformed(by: normalize.concatenating(flip).concatenating(display).concatenating(toView))
                .cropped(to: CGRect(origin: .zero, size: size))
            let cg = ctx.createCGImage(image, from: CGRect(origin: .zero, size: size))
            await MainActor.run {
                guard let self else { return }
                CATransaction.begin()
                CATransaction.setDisableActions(true)
                self.gray.contents = cg
                CATransaction.commit()
                self.busy = false
            }
        }
    }
}
