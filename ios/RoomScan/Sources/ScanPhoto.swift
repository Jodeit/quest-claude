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
        transform = [pose.columns.0, pose.columns.1, pose.columns.2, pose.columns.3]
            .flatMap { [$0.x, $0.y, $0.z, $0.w] }
    }

    var pose: simd_float4x4 {
        guard transform.count == 16 else { return matrix_identity_float4x4 }
        let t = transform
        return simd_float4x4(SIMD4(t[0], t[1], t[2], t[3]), SIMD4(t[4], t[5], t[6], t[7]),
                             SIMD4(t[8], t[9], t[10], t[11]), SIMD4(t[12], t[13], t[14], t[15]))
    }
}
