import CoreGraphics
import ImageIO
import SwiftUI
import UIKit
import simd

/// A quick 360 preview of each photo-real stop, made on the phone from the kept frames: an
/// equirectangular picture (heading across, the ceiling at the top, the floor at the bottom) with
/// whatever no frame saw left gray. It is what the twin's 360 view at that spot will have to work
/// with; the gray is what it will make up. Each pixel takes the frame that sees its direction most
/// centrally, as if everything were far away: no depth, so near things can sit a little off, but
/// the gaps are exactly where they will be.
struct SpotPreview: Identifiable {
    let id: Int              // the stop id
    let image: CGImage
    let seen: Float          // share of the sphere photographed (by solid angle)
    let floor: Float         // share of the lower 45 degrees (the floor round the feet)
    let ceiling: Float       // share of the upper 45 degrees
    let around: Float        // share of the band in between

    /// What's missing, worst first, in a few words; nil when the spot is well covered.
    var missing: String? {
        var parts: [(Float, String)] = []
        if floor < 0.7 { parts.append((floor, "the floor round your feet")) }
        if around < 0.85 { parts.append((around, "part of the way round")) }
        if ceiling < 0.6 { parts.append((ceiling, "the ceiling")) }
        guard !parts.isEmpty else { return nil }
        return parts.sorted { $0.0 < $1.0 }.map { $0.1 }.joined(separator: ", ")
    }

    static let width = 256, height = 128

    /// One preview per stop (frames carrying a stop id), from every kept frame within 1 m of the
    /// stop across the floor. Runs in a second or so; call it off the main thread.
    static func make(frames: [(Keyframe, Data)]) -> [SpotPreview] {
        var byStop: [Int: [Keyframe]] = [:]
        for (k, _) in frames { if let s = k.stop { byStop[s, default: []].append(k) } }
        guard !byStop.isEmpty else { return [] }
        var decoded: [String: Pixels] = [:]
        var out: [SpotPreview] = []
        for (id, members) in byStop.sorted(by: { $0.key < $1.key }) {
            let ps = members.map { simd_make_float3($0.pose.columns.3) }
            let spot = SIMD2(median(ps.map(\.x)), median(ps.map(\.z)))
            let near = frames.filter { k, _ in
                let p = simd_make_float3(k.pose.columns.3)
                return simd_distance(SIMD2(p.x, p.z), spot) < 1.0
            }
            var cams: [(Cam, Pixels)] = []
            for (k, data) in near {
                if decoded[k.file] == nil { decoded[k.file] = Pixels(jpeg: data, maxSide: 320) }
                if let px = decoded[k.file] { cams.append((Cam(k, scale: Float(px.w) / Float(k.width)), px)) }
            }
            // Centre the picture on the way the phone faced when the stop began.
            let first = members.first.map { -simd_make_float3($0.pose.columns.2) } ?? SIMD3(0, 0, -1)
            let startYaw = atan2(first.x, first.z)
            if let p = render(cams: cams, startYaw: startYaw, id: id) { out.append(p) }
        }
        return out
    }

    private static func render(cams: [(Cam, Pixels)], startYaw: Float, id: Int) -> SpotPreview? {
        let W = width, H = height
        var rgba = [UInt8](repeating: 0, count: W * H * 4)
        var wSeen: Float = 0, wAll: Float = 0
        var band: [(seen: Float, all: Float)] = [(0, 0), (0, 0), (0, 0)]  // floor, around, ceiling
        for v in 0..<H {
            let lat = Float.pi / 2 - (Float(v) + 0.5) / Float(H) * Float.pi
            let cl = cos(lat), sl = sin(lat)
            let b = lat < -Float.pi / 4 ? 0 : (lat > Float.pi / 4 ? 2 : 1)
            for u in 0..<W {
                // Left to right is turning right, which lowers the yaw (atan2(x, z), seen from above).
                let yaw = startYaw - ((Float(u) + 0.5) / Float(W) * 2 * Float.pi - Float.pi)
                let d = SIMD3(sin(yaw) * cl, sl, cos(yaw) * cl)
                var best: (Float, Int, Float, Float)? = nil  // off-centre, camera, x, y
                for (i, c) in cams.enumerated() {
                    guard let p = c.0.project(d) else { continue }
                    if best == nil || p.off < best!.0 { best = (p.off, i, p.x, p.y) }
                }
                let o = (v * W + u) * 4
                wAll += cl
                band[b].all += cl
                if let best {
                    let px = cams[best.1].1
                    let (r, g, bl) = px.at(best.2, best.3)
                    rgba[o] = r; rgba[o + 1] = g; rgba[o + 2] = bl
                    wSeen += cl
                    band[b].seen += cl
                } else {
                    // Gray, with a faint check so it reads as "nothing here" rather than a gray wall.
                    let g: UInt8 = ((u / 8 + v / 8) % 2 == 0) ? 120 : 132
                    rgba[o] = g; rgba[o + 1] = g; rgba[o + 2] = g
                }
                rgba[o + 3] = 255
            }
        }
        guard let provider = CGDataProvider(data: Data(rgba) as CFData),
              let image = CGImage(width: W, height: H, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: W * 4,
                                  space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                  bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                                  provider: provider, decode: nil, shouldInterpolate: true, intent: .defaultIntent)
        else { return nil }
        func share(_ x: (seen: Float, all: Float)) -> Float { x.all > 0 ? x.seen / x.all : 0 }
        return SpotPreview(id: id, image: image, seen: wAll > 0 ? wSeen / wAll : 0,
                           floor: share(band[0]), ceiling: share(band[2]), around: share(band[1]))
    }

    private static func median(_ a: [Float]) -> Float {
        let s = a.sorted()
        return s.isEmpty ? 0 : s[s.count / 2]
    }

    /// A frame's camera at the decoded size: which pixel a world direction lands on, if any.
    private struct Cam {
        let rt: simd_float3x3  // world to camera
        let fx, fy, cx, cy, w, h: Float

        init(_ k: Keyframe, scale: Float) {
            let p = k.pose
            rt = simd_float3x3(simd_make_float3(p.columns.0), simd_make_float3(p.columns.1), simd_make_float3(p.columns.2)).transpose
            fx = k.fx * scale; fy = k.fy * scale; cx = k.cx * scale; cy = k.cy * scale
            w = Float(k.width) * scale; h = Float(k.height) * scale
        }

        func project(_ d: SIMD3<Float>) -> (x: Float, y: Float, off: Float)? {
            let c = rt * d
            guard c.z < -0.05 else { return nil }  // the camera looks down -z
            let x = cx + fx * c.x / -c.z, y = cy - fy * c.y / -c.z
            guard x >= 1, y >= 1, x < w - 2, y < h - 2 else { return nil }
            let off = Swift.max(abs(x - w / 2) / w, abs(y - h / 2) / h)
            return (x, y, off)
        }
    }

    /// A JPEG decoded small, as RGBA bytes.
    private struct Pixels {
        let w, h: Int
        let bytes: [UInt8]

        init?(jpeg: Data, maxSide: Int) {
            guard let src = CGImageSourceCreateWithData(jpeg as CFData, nil),
                  let img = CGImageSourceCreateThumbnailAtIndex(src, 0, [
                      kCGImageSourceCreateThumbnailFromImageAlways: true,
                      kCGImageSourceThumbnailMaxPixelSize: maxSide,
                      kCGImageSourceCreateThumbnailWithTransform: false,
                  ] as CFDictionary) else { return nil }
            w = img.width; h = img.height
            guard let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { return nil }
            ctx.draw(img, in: CGRect(x: 0, y: 0, width: w, height: h))
            guard let data = ctx.data else { return nil }
            bytes = Array(UnsafeBufferPointer(start: data.assumingMemoryBound(to: UInt8.self), count: w * h * 4))
        }

        func at(_ x: Float, _ y: Float) -> (UInt8, UInt8, UInt8) {
            let i = (Swift.min(h - 1, Int(y)) * w + Swift.min(w - 1, Int(x))) * 4
            return (bytes[i], bytes[i + 1], bytes[i + 2])
        }
    }
}

/// After the photo-real pass: each stop's 360 preview, gray where the twin will have to make it
/// up, and a button back into the pass to fill the gaps.
struct SpotPreviews: View {
    @ObservedObject var session: ScanSession

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("360 preview").font(.subheadline.weight(.semibold))
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 10) {
                    ForEach(session.previews) { p in
                        VStack(alignment: .leading, spacing: 3) {
                            Image(decorative: p.image, scale: 1)
                                .resizable()
                                .interpolation(.medium)
                                .frame(width: 240, height: 120)
                                .clipShape(RoundedRectangle(cornerRadius: 8))
                            Text("Spot \(p.id) · \(Int(p.seen * 100))% photographed").font(.caption.weight(.semibold))
                            Text(p.missing.map { "Gray: \($0)" } ?? "Well covered")
                                .font(.caption2)
                                .foregroundStyle(p.missing == nil ? Color.green : Color.orange)
                                .lineLimit(2)
                                .frame(width: 240, alignment: .leading)
                        }
                        .accessibilityElement(children: .combine)
                    }
                }
            }
            if session.previews.contains(where: { $0.missing != nil }) {
                HStack {
                    Text("Gray is made up in the 3D twin's 360 view.").font(.caption2).foregroundStyle(.secondary)
                    Spacer()
                    Button("Fill the gaps") { session.startMeshPass() }
                        .buttonStyle(.bordered)
                        .font(.caption)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
