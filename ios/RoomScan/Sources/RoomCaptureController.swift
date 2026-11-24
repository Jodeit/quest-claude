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
    var onCoverage: ((CoverageSnapshot) -> Void)?
    var onHint: ((String?) -> Void)?
    private var hints = CaptureHints()
    private var look: CaptureHints.Look?
    private var lookTime = Date.distantPast
    private var lookBusy = false
    private var blurrySkipTimes: [Date] = []

    /// The frames kept so far: what's described, and the JPEG.
    private(set) var keyframes: [(Keyframe, Data)] = []
    private static let maxKeyframes = 150
    private static let keyframeWidth: CGFloat = 960
    /// The photo-real pass keeps bigger frames: they paint the mesh, close up.
    private static let meshFrameWidth: CGFloat = 1440
    /// Recent frames' sharpness, to judge a new one against.
    private var recentSharpness: [Float] = []
    private(set) var blurryFramesSkipped = 0
    private var pollTask: Task<Void, Never>?
    private var lastPoll: simd_float4x4?
    private var lastKey: simd_float4x4?
    private var encoding = false
    private var latestRoom: CapturedRoom?
    private var lastCoverage = Date.distantPast
    private var computingCoverage = false

    private var captureView: RoomCaptureView!
    private var overlay: CoverageOverlay!

    /// Gray where the walls haven't been photographed yet; on by default, a button on the scan screen.
    var showsGray = true {
        didSet { overlay?.isHidden = !showsGray }
    }
    private var running = false
    private let ciContext = CIContext()

    /// Most LiDAR mesh triangles seen in the session during the RoomPlan scan (does RoomPlan
    /// reconstruct a mesh we can use? this answers it), and the mesh taken as the scan ended.
    private(set) var meshTrianglesSeen = 0
    private(set) var roomMesh: LiDARMesh?
    /// The photo-real pass: ARKit's own mesh reconstruction after RoomPlan, in the same session.
    private(set) var meshPass = false
    private var meshView: MeshPassView?
    /// Starting ARKit's mesh mode moves the world origin (on a real scan, 3.5 m sideways). The
    /// phone's pose just before and just after gives the move back to RoomPlan's coordinates.
    private var preSwitchPose: simd_float4x4?
    private var switchTime: TimeInterval = 0
    private var meshJump: simd_float4x4?
    private var arSession: ARSession { captureView.captureSession.arSession }

    override func viewDidLoad() {
        super.viewDidLoad()
        captureView = RoomCaptureView(frame: view.bounds)
        captureView.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        captureView.delegate = self
        captureView.captureSession.delegate = self
        view.addSubview(captureView)
        overlay = CoverageOverlay(frame: view.bounds)
        overlay.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        overlay.session = captureView.captureSession.arSession
        overlay.isHidden = !showsGray
        view.addSubview(overlay)
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
        captureView.captureSession.arSession.pause()  // it's kept running between rooms
        stopKeyframes()
    }

    func start() {
        guard !running else { return }
        captureView.captureSession.run(configuration: RoomCaptureSession.Configuration())
        running = true
        overlay.start()
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollKeyframe()
                self?.updateCoverage()
                self?.updateHint()
                if let self { self.meshTrianglesSeen = Swift.max(self.meshTrianglesSeen, LiDARMesh.triangles(in: self.arSession)) }
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
    }

    /// Stop scanning; RoomPlan then processes the room and calls captureView(didPresent:error:).
    /// The camera session keeps running, so a next room continues in the same coordinates.
    func finish() {
        guard running else { return }
        roomMesh = LiDARMesh.harvest(arSession)
        captureView.captureSession.stop(pauseARSession: false)
        running = false
        stopKeyframes()
    }

    /// Scan another room in the same camera session: the rooms come out in one coordinate system,
    /// so they can be drawn together.
    func startNextRoom() {
        guard !running else { return }
        keyframes = []
        roomMesh = nil
        meshTrianglesSeen = 0
        latestRoom = nil
        lastKey = nil
        lastPoll = nil
        start()
    }

    /// After a room is saved: run ARKit's mesh reconstruction in the same session (so the mesh lines
    /// up with the room) and show it building over the camera, keeping frames as before. False if
    /// the device can't reconstruct a mesh.
    func startMeshPass() -> Bool {
        guard !running, !meshPass, ARWorldTrackingConfiguration.supportsSceneReconstruction(.mesh) else { return false }
        let config = ARWorldTrackingConfiguration()
        config.sceneReconstruction = .mesh
        preSwitchPose = arSession.currentFrame?.camera.transform
        switchTime = ProcessInfo.processInfo.systemUptime
        meshJump = nil
        arSession.run(config)
        let v = MeshPassView(session: arSession)
        v.frame = view.bounds
        v.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.insertSubview(v, belowSubview: overlay)
        meshView = v
        meshPass = true
        lastKey = nil
        lastPoll = nil
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                self?.pollKeyframe()
                self?.updateHint()
                self?.updateCoverage()
                try? await Task.sleep(nanoseconds: 250_000_000)
            }
        }
        overlay.start()  // gray where the 3D scan hasn't reached yet
        return true
    }

    /// Ends the photo-real pass: the mesh, joined in world coordinates.
    func finishMeshPass() -> LiDARMesh? {
        guard meshPass else { return nil }
        var mesh = LiDARMesh.harvest(arSession)
        if let jump = meshJump { mesh?.apply(jump) }
        meshPass = false
        pollTask?.cancel()
        pollTask = nil
        overlay.stop()
        meshView?.removeFromSuperview()
        meshView = nil
        return mesh
    }

    private func stopKeyframes() {
        pollTask?.cancel()
        pollTask = nil
        overlay?.stop()
    }

    // MARK: keyframes

    /// Four times a second: keep this frame if the phone isn't swinging fast (less blur) and it's a
    /// new view: moved 20 cm or turned 10 degrees since the last frame kept. (The first real scan
    /// kept only 21 frames with stricter limits, leaving gaps on the walls.)
    private func pollKeyframe() {
        guard running || meshPass, !encoding, keyframes.count < Self.maxKeyframes + (meshPass ? 150 : 0),
              let frame = captureView.captureSession.arSession.currentFrame,
              case .normal = frame.camera.trackingState else { return }
        if meshPass, meshJump == nil {
            guard frame.timestamp > switchTime + 0.05, let pre = preSwitchPose else { return }
            meshJump = LiDARMesh.yawTranslation(pre * frame.camera.transform.inverse)
        }
        let pose = meshPass ? (meshJump ?? matrix_identity_float4x4) * frame.camera.transform : frame.camera.transform
        let previous = lastPoll
        lastPoll = pose
        guard let previous, Self.turn(previous, pose) < 0.07,
              simd_distance(previous.columns.3, pose.columns.3) < 0.06 else { return }
        if let k = lastKey, simd_distance(k.columns.3, pose.columns.3) < 0.2, Self.turn(k, pose) < 0.17 { return }
        lastKey = pose

        let buffer = frame.capturedImage
        let fullW = CGFloat(CVPixelBufferGetWidth(buffer)), fullH = CGFloat(CVPixelBufferGetHeight(buffer))
        let scale = (meshPass ? Self.meshFrameWidth : Self.keyframeWidth) / fullW
        let k = frame.camera.intrinsics
        let key = Keyframe(file: String(format: meshPass ? "M%03d.jpg" : "F%03d.jpg", keyframes.count + 1), transform: pose.packed,
                           fx: k.columns.0.x * Float(scale), fy: k.columns.1.y * Float(scale),
                           cx: k.columns.2.x * Float(scale), cy: k.columns.2.y * Float(scale),
                           width: Int((fullW * scale).rounded()), height: Int((fullH * scale).rounded()))
        let context = ciContext
        encoding = true
        let previousKey = lastKey
        Task {
            let result: (Data?, Float) = await Task.detached(priority: .utility) {
                let source = CIImage(cvPixelBuffer: buffer)
                let sharp = Self.sharpness(source, context: context)
                let image = source.transformed(by: CGAffineTransform(scaleX: scale, y: scale))
                let quality = CIImageRepresentationOption(rawValue: kCGImageDestinationLossyCompressionQuality as String)
                return (context.jpegRepresentation(of: image, colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                                                   options: [quality: 0.8]), sharp)
            }.value
            // Skip a frame much blurrier than the ones just before it (motion blur, focus hunting);
            // the next steady moment from about here gets another chance.
            let sorted = recentSharpness.sorted()
            let median = sorted.isEmpty ? 0 : sorted[sorted.count / 2]
            recentSharpness.append(result.1)
            if recentSharpness.count > 30 { recentSharpness.removeFirst() }
            if sorted.count >= 5, result.1 < 0.45 * median {
                blurryFramesSkipped += 1
                blurrySkipTimes.append(Date())
                lastKey = previousKey
            } else if let jpeg = result.0 {
                var k = key
                k.sharpness = result.1
                keyframes.append((k, jpeg))
            }
            encoding = false
        }
    }

    /// Four times a second: the most useful thing to tell the person scanning (see CaptureHints).
    private func updateHint() {
        guard running || meshPass, let frame = arSession.currentFrame else { return }
        if !lookBusy, Date().timeIntervalSince(lookTime) > 1 {
            lookBusy = true
            lookTime = Date()
            let buffer = frame.capturedImage, context = ciContext
            Task {
                let l = await Task.detached(priority: .utility) { CaptureHints.look(buffer, context: context) }.value
                look = l
                lookBusy = false
            }
        }
        blurrySkipTimes.removeAll { Date().timeIntervalSince($0) > 4 }
        let text = hints.hint(frame: frame, look: look, blurrySkipsRecently: blurrySkipTimes.count,
                              room: meshPass ? nil : latestRoom, keyframes: keyframes.map { $0.0 }, meshPass: meshPass)
        onHint?(text)
    }

    /// About once a second: how well the kept frames cover each wall RoomPlan has found so far.
    private func updateCoverage() {
        if meshPass { updateMeshCoverage(); return }
        guard running, !computingCoverage, Date().timeIntervalSince(lastCoverage) > 1,
              let room = latestRoom, let pose = lastPoll else { return }
        computingCoverage = true
        lastCoverage = Date()
        let frames = keyframes.map { $0.0 }
        Task {
            let snapshot = await Task.detached(priority: .utility) {
                Coverage.compute(room: room, frames: frames, camera: pose)
            }.value
            computingCoverage = false
            if running {
                overlay.snapshot = snapshot
                onCoverage?(snapshot)
            }
        }
    }

    /// Every two seconds in the photo-real pass: how much of each wall the LiDAR mesh has reached, for the
    /// map, the gray overlay and the hint.
    private func updateMeshCoverage() {
        guard !computingCoverage, Date().timeIntervalSince(lastCoverage) > 2,
              let room = latestRoom, let pose = lastPoll, let jump = meshJump, let mesh = LiDARMesh.harvest(arSession) else { return }
        computingCoverage = true
        lastCoverage = Date()
        Task {
            let snapshot = await Task.detached(priority: .utility) { () -> CoverageSnapshot in
                // Undo the switch's jump, then level the floor onto RoomPlan's: the jump can leave
                // the mesh tens of centimetres high, which would misplace it against the walls.
                var m = mesh
                m.apply(jump)
                let floorY = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0
                let ceilingY = room.walls.map { $0.transform.columns.3.y + $0.dimensions.y / 2 }.max() ?? floorY + 2.4
                let dy = m.levelOffset(floorY: floorY, ceilingY: ceilingY)
                let stride = Swift.max(1, m.positions.count / 120_000)
                let points = Swift.stride(from: 0, to: m.positions.count, by: stride).map { m.positions[$0] + SIMD3<Float>(0, dy, 0) }
                return Coverage.fromMesh(room: room, points: points, camera: pose)
            }.value
            computingCoverage = false
            if meshPass {
                overlay.snapshot = snapshot
                onCoverage?(snapshot)
            }
        }
    }

    /// Variance of the Laplacian on a 160-pixel-wide grayscale copy: a cheap measure of how much fine
    /// detail survived (the same measure roomscan uses to prefer sharp frames).
    nonisolated private static func sharpness(_ image: CIImage, context: CIContext) -> Float {
        let s = 160 / image.extent.width
        let small = image.transformed(by: CGAffineTransform(scaleX: s, y: s))
        let w = Int(small.extent.width), h = Int(small.extent.height)
        guard w > 4, h > 4 else { return 0 }
        var gray = [UInt8](repeating: 0, count: w * h)
        context.render(small, toBitmap: &gray, rowBytes: w, bounds: CGRect(x: 0, y: 0, width: w, height: h),
                       format: .L8, colorSpace: nil)
        var sum: Float = 0, sumSq: Float = 0, n: Float = 0
        for y in 1..<(h - 1) {
            for x in 1..<(w - 1) {
                let c = Float(gray[y * w + x]) * 4
                let lap = c - Float(gray[y * w + x - 1]) - Float(gray[y * w + x + 1]) - Float(gray[(y - 1) * w + x])
                    - Float(gray[(y + 1) * w + x])
                sum += lap; sumSq += lap * lap; n += 1
            }
        }
        let mean = sum / n
        return sumSq / n - mean * mean
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
        DispatchQueue.main.async {
            self.latestRoom = room
            self.onLiveUpdate?(room)
        }
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
