import Foundation
import simd

/// A photo taken while scanning, with where the camera was and which way it faced, in the same
/// ARKit world frame as the scan. That's what lets the plan put a pin where it was taken.
struct ScanPhoto: Codable, Hashable {
    var file: String       // in the scan's photos folder
    var date: Date
    var transform: [Float] // the camera's pose, 4x4 column-major

    init(file: String, date: Date, pose: simd_float4x4) {
        self.file = file
        self.date = date
        transform = pose.packed
    }

    var pose: simd_float4x4 { simd_float4x4(packed: transform) }
}

/// A frame the app kept from the scanning camera, for wall elevations: the image as the sensor
/// sees it (landscape, not turned upright), the camera's pose and its intrinsics for that image size.
struct Keyframe: Codable, Hashable {
    var file: String       // in the scan's frames folder
    var transform: [Float] // camera pose, 4x4 column-major
    var fx, fy, cx, cy: Float
    var width, height: Int
    /// Variance of the Laplacian of a small grayscale copy: higher is sharper (blur flattens it).
    var sharpness: Float? = nil

    var pose: simd_float4x4 { simd_float4x4(packed: transform) }
}

extension simd_float4x4 {
    /// Column-major, 16 numbers: how poses are kept in JSON.
    var packed: [Float] {
        [columns.0, columns.1, columns.2, columns.3].flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    init(packed t: [Float]) {
        guard t.count == 16 else {
            self = matrix_identity_float4x4
            return
        }
        self.init(SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                  SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15]))
    }
}
