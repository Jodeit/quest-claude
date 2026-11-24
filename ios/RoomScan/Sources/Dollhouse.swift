import QuickLook
import RoomPlan
import SceneKit
import SwiftUI
import UIKit
import simd

/// The scan as a dollhouse: walls wearing their elevation photos, the floor, furniture as see-through
/// boxes with their spot names, and photo pins where each photo was taken. Walls are one-sided and
/// face the room, so any wall between you and the room is see-through from behind: turn the model
/// and you look in.
enum Dollhouse {
    struct Model {
        let scene: SCNScene
        let camera: SCNNode
        let center: SIMD3<Float>
    }

    /// One room's worth: the scan and what the app made from it.
    struct Part {
        let room: CapturedRoom
        let elevations: [(Elevation, URL)]
        let photos: [ScanPhoto]
        let names: [String: String]
        var floor: (WallElevations.FloorImage, URL)? = nil
    }

    /// One room, or every room of a home (they share coordinates, so they fit together). Tappable
    /// nodes are named "object:<room>:<index>" and "photo:<room>:<index>".
    static func build(_ parts: [Part]) -> Model {
        let scene = SCNScene()
        let all = parts.flatMap { $0.room.walls.map { simd_make_float3($0.transform.columns.3) } }
        let centre = all.isEmpty ? .zero : all.reduce(.zero, +) / Float(all.count)
        for (r, part) in parts.enumerated() { add(part, index: r, to: scene.rootNode) }

        // Look in from above one corner.
        let reach = all.map { simd_distance($0, centre) }.max() ?? 3
        let camera = SCNNode()
        camera.camera = SCNCamera()
        camera.camera?.zNear = 0.05
        camera.camera?.zFar = 300
        let r = Swift.max(3, reach * 2.4)
        camera.simdPosition = centre + SIMD3(r * 0.55, r * 0.9, r * 0.75)
        camera.simdLook(at: centre)
        scene.rootNode.addChildNode(camera)
        return Model(scene: scene, camera: camera, center: centre)
    }

    private static func add(_ part: Part, index r: Int, to root: SCNNode) {
        let room = part.room, elevations = part.elevations, photos = part.photos, names = part.names
        let wallCentres = room.walls.map { simd_make_float3($0.transform.columns.3) }
        let centroid = wallCentres.isEmpty ? .zero : wallCentres.reduce(.zero, +) / Float(wallCentres.count)
        let floorY = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0

        // Walls, facing the room.
        for (i, w) in room.walls.enumerated() {
            let elevation = elevations.first { $0.0.wall == i }
            let c = simd_make_float3(w.transform.columns.3)
            let z = simd_make_float3(w.transform.columns.2)
            let flipped = elevation?.0.flipped ?? (simd_dot(centroid - c, z) < 0)
            let plane = SCNPlane(width: CGFloat(w.dimensions.x), height: CGFloat(w.dimensions.y))
            let m = SCNMaterial()
            if let url = elevation?.1, let image = UIImage(contentsOfFile: url.path) {
                m.diffuse.contents = image
                m.lightingModel = .constant  // a photo already has its light
            } else {
                m.diffuse.contents = UIColor(white: 0.92, alpha: 1)
                m.lightingModel = .lambert
            }
            m.isDoubleSided = false
            plane.materials = [m]
            let node = SCNNode(geometry: plane)
            node.name = "wall:\(r):\(i)"
            node.simdTransform = flipped ? w.transform * simd_float4x4(simd_quatf(angle: .pi, axis: SIMD3(0, 1, 0)))
                : w.transform
            root.addChildNode(node)
        }

        // Floor: RoomPlan's outline, else the walls' bounding box.
        var outline: [SIMD2<Float>] = []
        if let f = room.floors.first, f.polygonCorners.count > 2 {
            outline = f.polygonCorners.map { p in
                let w = f.transform * SIMD4<Float>(p.x, p.y, p.z, 1)
                return SIMD2(w.x, w.z)
            }
        } else if !wallCentres.isEmpty {
            let xs = room.walls.flatMap { w -> [Float] in
                let c = simd_make_float3(w.transform.columns.3), x = simd_make_float3(w.transform.columns.0)
                return [c.x - x.x * w.dimensions.x / 2, c.x + x.x * w.dimensions.x / 2]
            }
            let zs = room.walls.flatMap { w -> [Float] in
                let c = simd_make_float3(w.transform.columns.3), x = simd_make_float3(w.transform.columns.0)
                return [c.z - x.z * w.dimensions.x / 2, c.z + x.z * w.dimensions.x / 2]
            }
            if let x0 = xs.min(), let x1 = xs.max(), let z0 = zs.min(), let z1 = zs.max() {
                outline = [SIMD2(x0, z0), SIMD2(x1, z0), SIMD2(x1, z1), SIMD2(x0, z1)]
            }
        }
        if outline.count > 2 {
            let path = UIBezierPath()
            path.move(to: CGPoint(x: CGFloat(outline[0].x), y: CGFloat(-outline[0].y)))
            for p in outline.dropFirst() { path.addLine(to: CGPoint(x: CGFloat(p.x), y: CGFloat(-p.y))) }
            path.close()
            let shape = SCNShape(path: path, extrusionDepth: 0.02)
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(red: 0.80, green: 0.74, blue: 0.66, alpha: 1)
            m.lightingModel = .lambert
            shape.materials = [m]
            let node = SCNNode(geometry: shape)
            // The path is drawn in x and -z; turn it to lie flat at the floor.
            node.eulerAngles.x = -.pi / 2
            node.position.y = floorY - 0.02
            root.addChildNode(node)
        }
        // The floor photo, laid on top: a plane over the floor's bounds, transparent outside it.
        if let floor = part.floor, let image = UIImage(contentsOfFile: floor.1.path) {
            let f = floor.0
            let plane = SCNPlane(width: CGFloat(f.maxX - f.minX), height: CGFloat(f.maxZ - f.minZ))
            let m = SCNMaterial()
            m.diffuse.contents = image
            m.lightingModel = .constant
            m.transparencyMode = .aOne
            plane.materials = [m]
            let node = SCNNode(geometry: plane)
            // Flat, facing up; the image's top edge lies toward -z, as it was drawn.
            node.eulerAngles.x = -.pi / 2
            node.simdPosition = SIMD3((f.minX + f.maxX) / 2, f.y + 0.002, (f.minZ + f.maxZ) / 2)
            root.addChildNode(node)
        }

        // Furniture and fixtures: see-through boxes, named as on the plan.
        for (i, o) in room.objects.enumerated() {
            let box = SCNBox(width: CGFloat(o.dimensions.x), height: CGFloat(o.dimensions.y),
                             length: CGFloat(o.dimensions.z), chamferRadius: 0.01)
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(white: 1, alpha: 0.4)
            m.transparencyMode = .dualLayer
            m.lightingModel = .lambert
            box.materials = [m]
            let node = SCNNode(geometry: box)
            node.name = "object:\(r):\(i)"
            node.simdTransform = o.transform
            root.addChildNode(node)
            let key = "\(i + 1) \(FloorPlanPDF.objectLabel(o.category))"
            if let tag = label(FloorPlanPDF.shown(key, names)) {
                tag.simdPosition = simd_make_float3(o.transform.columns.3) + SIMD3(0, o.dimensions.y / 2 + 0.12, 0)
                root.addChildNode(tag)
            }
        }

        // Photo pins: where each photo was taken.
        for (i, photo) in photos.enumerated() {
            let sphere = SCNSphere(radius: 0.05)
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(red: 0.6, green: 0.2, blue: 0.45, alpha: 1)
            sphere.materials = [m]
            let node = SCNNode(geometry: sphere)
            node.name = "photo:\(r):\(i)"
            node.simdPosition = simd_make_float3(photo.pose.columns.3)
            root.addChildNode(node)
        }
    }

    /// A name tag that always faces the viewer.
    private static func label(_ text: String) -> SCNNode? {
        let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 36, weight: .semibold),
                                                    .foregroundColor: UIColor.black]
        let size = (text as NSString).size(withAttributes: attrs)
        let pad: CGFloat = 14
        let box = CGSize(width: size.width + pad * 2, height: size.height + pad)
        let image = UIGraphicsImageRenderer(size: box).image { _ in
            UIColor(white: 1, alpha: 0.88).setFill()
            UIBezierPath(roundedRect: CGRect(origin: .zero, size: box), cornerRadius: box.height / 2).fill()
            (text as NSString).draw(at: CGPoint(x: pad, y: pad / 2), withAttributes: attrs)
        }
        let height: CGFloat = 0.11
        let plane = SCNPlane(width: height * box.width / box.height, height: height)
        let m = SCNMaterial()
        m.diffuse.contents = image
        m.lightingModel = .constant
        m.isDoubleSided = true
        plane.materials = [m]
        let node = SCNNode(geometry: plane)
        node.constraints = [SCNBillboardConstraint()]
        return node
    }

    /// The model as a USDZ file, which any iPhone, iPad or Mac opens (and shows in AR).
    static func exportUSDZ(_ model: Model, name: String) -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(name) dollhouse.usdz")
        try? FileManager.default.removeItem(at: url)
        return model.scene.write(to: url, options: nil, delegate: nil, progressHandler: nil) ? url : nil
    }
}

struct DollhouseView: View {
    @EnvironmentObject private var library: ScanLibrary
    @Environment(\.dismiss) private var dismiss
    /// One room, or a home's rooms (scanned in one session).
    let scans: [SavedScan]
    var title: String { scans.count == 1 ? scans[0].name : "Home" }

    @State private var model: Dollhouse.Model?
    @State private var failure: String?
    @State private var info: String?
    @State private var photoURL: URL?
    @State private var usdzURL: URL?
    @State private var spots: [[String]] = []  // per room: each object's plan label

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if let model {
                    SceneViewer(model: model) { tapped($0) }.ignoresSafeArea(edges: .bottom)
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary).padding()
                } else {
                    ProgressView("Building the dollhouse…")
                }
                Text(info ?? "Drag to turn, pinch to zoom. Tap a box or a photo pin.")
                    .font(.callout)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let model { usdzURL = Dollhouse.exportUSDZ(model, name: title) }
                    } label: { Label("Share 3D", systemImage: "square.and.arrow.up") }
                    .disabled(model == nil)
                }
            }
            .sheet(item: $usdzURL) { url in ShareSheet(items: [url]) }
            .quickLookPreview($photoURL)
            .task { load() }
        }
    }

    private func load() {
        guard model == nil else { return }
        do {
            var parts: [Dollhouse.Part] = []
            spots = []
            for scan in scans {
                let room = try JSONDecoder().decode(CapturedRoom.self, from: library.json(for: scan))
                spots.append(room.objects.enumerated().map {
                    "\($0.offset + 1) \(FloorPlanPDF.objectLabel($0.element.category))"
                })
                parts.append(Dollhouse.Part(room: room, elevations: library.elevations(for: scan),
                                            photos: library.photos(for: scan).map { $0.0 },
                                            names: library.names(for: scan), floor: library.floorImage(for: scan)))
            }
            model = Dollhouse.build(parts)
        } catch {
            failure = "Couldn't read the scan: \(error.localizedDescription)"
        }
    }

    private func tapped(_ name: String) {
        let parts = name.split(separator: ":")
        guard parts.count == 3, let r = Int(parts[1]), let i = Int(parts[2]), r < scans.count else { return }
        let scan = scans[r]
        if parts[0] == "photo" {
            let photos = library.photos(for: scan)
            if i < photos.count { photoURL = photos[i].1 }
        } else if parts[0] == "object", r < spots.count, i < spots[r].count {
            let key = spots[r][i]
            let here = library.products(for: scan).filter { $0.location == key }
            let what = here.isEmpty ? "No products here yet."
                : here.map { "\($0.qty) × \($0.product)" }.joined(separator: "\n")
            let place = FloorPlanPDF.shown(key, library.names(for: scan))
            info = (scans.count > 1 ? "\(scan.name) · " : "") + "\(place)\n\(what)"
        }
    }
}

/// SceneKit's view with orbit controls, reporting the name of what's tapped.
private struct SceneViewer: UIViewRepresentable {
    let model: Dollhouse.Model
    let onTap: (String) -> Void

    func makeCoordinator() -> Coordinator { Coordinator(onTap: onTap) }

    func makeUIView(context: Context) -> SCNView {
        let view = SCNView()
        view.scene = model.scene
        view.pointOfView = model.camera
        view.allowsCameraControl = true
        view.defaultCameraController.interactionMode = .orbitTurntable
        view.defaultCameraController.target = SCNVector3(model.center.x, model.center.y, model.center.z)
        view.autoenablesDefaultLighting = true
        view.antialiasingMode = .multisampling4X
        view.backgroundColor = .systemGroupedBackground
        let tap = UITapGestureRecognizer(target: context.coordinator, action: #selector(Coordinator.tap(_:)))
        view.addGestureRecognizer(tap)
        return view
    }

    func updateUIView(_ view: SCNView, context: Context) {}

    final class Coordinator: NSObject {
        let onTap: (String) -> Void
        init(onTap: @escaping (String) -> Void) { self.onTap = onTap }

        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? SCNView else { return }
            for hit in view.hitTest(g.location(in: view), options: nil) {
                var node: SCNNode? = hit.node
                while let n = node {
                    if let name = n.name, name.hasPrefix("photo:") || name.hasPrefix("object:") {
                        onTap(name)
                        return
                    }
                    node = n.parent
                }
            }
        }
    }
}
