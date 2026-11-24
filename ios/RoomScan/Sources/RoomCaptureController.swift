import ARKit
import CoreImage
import RoomPlan
import SwiftUI
import UIKit

/// Apple's RoomCaptureView (the live scanning UI, coaching and the processed 3D result), with two
/// hooks out: every interim model RoomPlan builds while scanning, and the final processed room.
final class RoomCaptureController: UIViewController, RoomCaptureViewDelegate, RoomCaptureSessionDelegate {
    var onLiveUpdate: ((CapturedRoom) -> Void)?
    var onFinished: ((Result<CapturedRoom, Error>) -> Void)?

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
    }

    func start() {
        guard !running else { return }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        running = true
    }

    /// Stop scanning; RoomPlan then processes the room and calls captureView(didPresent:error:).
    func finish() {
        guard running else { return }
        captureView.captureSession.stop()
        running = false
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
