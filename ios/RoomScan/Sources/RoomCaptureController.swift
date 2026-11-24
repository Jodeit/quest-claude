import ARKit
import AVKit
import CoreImage
import RoomPlan
import SwiftUI
import UIKit

/// Apple's RoomCaptureView (the live scanning UI, coaching and the processed 3D result), with
/// hooks out: every interim model RoomPlan builds while scanning, the final processed room, and the
/// hardware shutter (Camera Control or a volume button). While scanning it also keeps keyframes:
/// still, sharp-ish frames from new viewpoints, for wall elevations.
final class RoomCaptureController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    var onLiveUpdate: ((CapturedRoom) -> Void)?
    var onFinished: ((Result<CapturedRoom, Error>) -> Void)?
    var onShutter: (() -> Void)?

    /// The frames kept so far: what's described, and the JPEG.
    private(set) var keyframes: [(Keyframe, Data)] = []
    private static let maxKeyframes = 150
    private static let keyframeWidth: CGFloat = 960
    private var pollTask: Task<Void, Never>?
    private var lastPoll: simd_float4x4?
    private var lastKey: simd_float4x4?
    private var encoding = false

    private var captureView: RoomCaptureView!
    private var running = false
    private let ciContext = CIContext()

    override func viewDidLoad() {
        super.viewDidLoad()
        captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        captureView.captureSession.delegate = self
        view.addSubview(captureView)
        // Camera Control and the volume buttons as a shutter. iOS may only send these to apps that
        // run their own camera session; RoomPlan runs it for us, so this is best effort.
        if #available(iOS 17.2, *) {
            let shutter = AVCaptureEventInteraction { [weak self] event in
                if event.phase == .ended { self?.onShutter?() }
            }
            view.addInteraction(shutter)
        }
    }

    override func viewDidAppear(_ animated: Bool) {
        super.viewDidAppear(animated)
        start()
    }

    override func viewWillDisappear(_ animated: Bool) {
        super.viewWillDisappear(animated)
        if running {
            captureView.captureSession.stop()
            running = false
        }
        stopKeyframes()
    }

    func start() {
        guard !running else { return }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        running = true
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollKeyframe()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Stop scanning; RoomPlan then processes the room and calls captureView(didPresent:error:).
    func finish() {
        guard running else { return }
        captureView.captureSession.stop()
        running = false
        stopKeyframes()
    }

    private func stopKeyframes() {
        pollTask?.cancel()
        pollTask = nil
    }

    // MARK: keyframes

    /// Four times a second: keep this frame if the phone isn't swinging fast (less blur) and it's a
    /// new view: moved 20 cm or turned 10 degrees since the last frame kept. (The first real scan
    /// kept only 21 frames with stricter limits, leaving gaps on the walls.)
    private func pollKeyframe() {
        guard running, !encoding, keyframes.count < Self.maxKeyframes,
              let frame = captureView.captureSession.arSession.currentFrame,
              case .normal = frame.camera.trackingState else { return }
        let pose = frame.camera.transform
        let previous = lastPoll
        lastPoll = pose
        guard let previous, Self.turn(previous, pose) < 0.07,
              simd_distance(previous.columns.3, pose.columns.3) < 0.06 else { return }
        if let k = lastKey, simd_distance(k.columns.3, pose.columns.3) < 0.2, Self.turn(k, pose) < 0.17 { return }
        lastKey = pose

        let buffer = frame.capturedImage
        let fullW = CGFloat(CVPixelBufferGetWidth(buffer)), fullH = CGFloat(CVPixelBufferGetHeight(buffer))
        let scale = Self.keyframeWidth / fullW
        let k = frame.camera.intrinsics
        let key = Keyframe(file: String(format: "F%03d.jpg", keyframes.count + 1), transform: pose.packed,
                           fx: k.columns.0.x * Float(scale), fy: k.columns.1.y * Float(scale),
                           cx: k.columns.2.x * Float(scale), cy: k.columns.2.y * Float(scale),
                           width: Int((fullW * scale).rounded()), height: Int((fullH * scale).rounded()))
        let context = ciContext
        encoding = true
        Task {
            let jpeg: Data? = await Task.detached(priority: .utility) {
                let image = CIImage(cvPixelBuffer: buffer).transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                return context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                  options: [quality: 0.75])
            }.value
            if let jpeg { keyframes.append((key, jpeg)) }
            encoding = false
        }
    }

    /// The angle between where two poses look, in radians.
    private static func turn(_ a: simd_float4x4, _ b: simd_float4x4) -> Float {
        let fa = -simd_make_float3(a.columns.2), fb = -simd_make_float3(b.columns.2)
        return acos(Swift.min(1, Swift.max(-1, simd_dot(simd_normalize(fa), simd_normalize(fb)))))
    }

    /// The camera's current frame as a JPEG, upright for how the phone is held, with the camera's
    /// pose in the scan's world frame. Nil when not scanning or before the first frame.
    func capturePhoto() async -> (jpeg: Data, pose: simd_float4x4)? {
        guard running, let frame = captureView.captureSession.arSession.currentFrame else { return nil }
        let pose = frame.camera.transform
        let buffer = frame.capturedImage
        let orientation = Self.imageOrientation(view.window?.windowScene?.interfaceOrientation ?? .portrait)
        let context = ciContext
        let jpeg: Data? = await Task.detached(priority: .userInitiated) {
            let image = CIImage(cvPixelBuffer: buffer).oriented(orientation)
            let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
            return context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                              options: [quality: 0.8])
        }.value
        guard let jpeg else { return nil }
        return (jpeg, pose)
    }

    /// The camera sensor is landscape (home side right); turn its frames to match the screen.
    private static func imageOrientation(_ o: UIInterfaceOrientation) -> CGImagePropertyOrientation {
        switch o {
        case .landscapeRight: return .up
        case .landscapeLeft: return .down
        case .portraitUpsideDown: return .left
        default: return .right
        }
    }

    // MARK: RoomCaptureSessionDelegate

    func captureSession(_ session: RoomCaptureSession, didUpdate room: CapturedRoom) {
        DispatchQueue.main.async { self.onLiveUpdate?(room) }
    }

    // MARK: RoomCaptureViewDelegate

    func captureView(shouldPresent roomDataForProcessing: CapturedRoomData, error: Error?) -> Bool {
        true
    }

    func captureView(didPresent processedResult: CapturedRoom, error: Error?) {
        DispatchQueue.main.async {
            if let error {
                self.onFinished?(.failure(error))
            } else {
                self.onFinished?(.success(processedResult))
            }
        }
    }
}

struct RoomCaptureRepresentable: UIViewControllerRepresentable {
    let controller: RoomCaptureController

    func makeUIViewController(context: Context) -> RoomCaptureController { controller }
    func updateUIViewController(_ controller: RoomCaptureController, context: Context) {}
}
