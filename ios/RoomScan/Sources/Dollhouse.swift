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
        let eye: SIMD3<Float>          // standing in the middle of the room, for walk mode
        let start: simd_float4x4       // the dollhouse view's camera, to go back to
    }

    /// One room's worth: the scan and what the app made from it.
    struct Part {
        let room: CapturedRoom
        let elevations: [(Elevation, URL)]
        let photos: [ScanPhoto]
        let names: [String: String]
        var floor: (WallElevations.FloorImage, URL)? = nil
        /// The LiDAR mesh and the frames to paint it with: the photo-real model, when there is one.
        var mesh: LiDARMesh? = nil
        var frames: [(Keyframe, URL)] = []
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
        let floorY = parts.flatMap { $0.room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 } }.min() ?? centre.y - 1.2
        return Model(scene: scene, camera: camera, center: centre, eye: SIMD3(centre.x, floorY + 1.55, centre.z),
                     start: camera.simdTransform)
    }

    private static func add(_ part: Part, index r: Int, to root: SCNNode) {
        let room = part.room, elevations = part.elevations, photos = part.photos, names = part.names
        let wallCentres = room.walls.map { simd_make_float3($0.transform.columns.3) }
        let centroid = wallCentres.isEmpty ? .zero : wallCentres.reduce(.zero, +) / Float(wallCentres.count)
        let floorY = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0

        // The photo-real model replaces the photo-draped walls and floor when there is one.
        if let mesh = part.mesh {
            let node = mesh.texturedNode(frames: part.frames)
            node.name = "mesh:\(r)"
            root.addChildNode(node)
        } else {
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
            node.name = "floor:\(r)"
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
            node.name = "floor:\(r)"
            root.addChildNode(node)
        }

        }

        // Furniture and fixtures: see-through boxes, named as on the plan (barely there over the
        // photo-real model, but still tappable).
        for (i, o) in room.objects.enumerated() {
            let box = SCNBox(width: CGFloat(o.dimensions.x), height: CGFloat(o.dimensions.y),
                             length: CGFloat(o.dimensions.z), chamferRadius: 0.01)
            let m = SCNMaterial()
            m.diffuse.contents = UIColor(white: 1, alpha: part.mesh == nil ? 0.4 : 0.06)
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

    /// A measured distance: a line between two points, a dot at each end and its length on a tag.
    static func measureNode(_ a: SIMD3<Float>, _ b: SIMD3<Float>, text: String) -> SCNNode {
        let group = SCNNode()
        group.name = "measure"
        let red = UIColor(red: 0.85, green: 0.1, blue: 0.35, alpha: 1)
        for p in [a, b] {
            let dot = SCNNode(geometry: SCNSphere(radius: 0.015))
            dot.geometry?.firstMaterial?.diffuse.contents = red
            dot.geometry?.firstMaterial?.readsFromDepthBuffer = false
            dot.renderingOrder = 10
            dot.simdPosition = p
            group.addChildNode(dot)
        }
        let length = simd_distance(a, b)
        if length > 0.005 {
            let bar = SCNNode(geometry: SCNCylinder(radius: 0.005, height: CGFloat(length)))
            bar.geometry?.firstMaterial?.diffuse.contents = red
            bar.geometry?.firstMaterial?.readsFromDepthBuffer = false
            bar.renderingOrder = 10
            bar.simdPosition = (a + b) / 2
            let dir = simd_normalize(b - a)
            let up: SIMD3<Float> = abs(dir.y) > 0.95 ? SIMD3(1, 0, 0) : SIMD3(0, 1, 0)
            bar.simdLook(at: b, up: up, localFront: SIMD3(0, 1, 0))
            group.addChildNode(bar)
        }
        if !text.isEmpty, let tag = label(text) {
            tag.simdPosition = (a + b) / 2 + SIMD3(0, 0.08, 0)
            tag.renderingOrder = 11
            group.addChildNode(tag)
        }
        return group
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
    @State private var measuring = false
    @State private var walking = false
    @State private var firstPoint: (point: SIMD3<Float>, room: Int)?
    @State private var pending: (a: SIMD3<Float>, b: SIMD3<Float>, room: Int)?
    @State private var measureName = ""
    @State private var askName = false
    @State private var showMeasurements: SavedScan?

    var body: some View {
        NavigationStack {
            ZStack(alignment: .bottom) {
                if let model {
                    SceneViewer(model: model, walk: walking, preferSurface: measuring) { name, point in
                        if measuring { measureTap(name, point) } else if let name { tapped(name) }
                    }
                    .ignoresSafeArea(edges: .bottom)
                } else if let failure {
                    Text(failure).foregroundStyle(.secondary).padding()
                } else {
                    ProgressView("Building the dollhouse…")
                }
                Text(measuring ? (firstPoint == nil ? "Measuring: tap the first point." : "Now tap the second point.")
                     : info ?? (walking ? "Drag to look around; pinch or drag with two fingers to move."
                                : "Drag to turn, pinch to zoom. Tap a box or a photo pin."))
                    .font(.callout)
                    .padding(10)
                    .background(.ultraThinMaterial, in: RoundedRectangle(cornerRadius: 12))
                    .padding()
            }
            .navigationTitle(title)
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        measuring.toggle()
                        firstPoint = nil
                    } label: { Label(measuring ? "Stop measuring" : "Measure", systemImage: "ruler") }
                    .disabled(model == nil)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        walking.toggle()
                    } label: {
                        Label(walking ? "Dollhouse" : "Walk", systemImage: walking ? "cube.transparent" : "figure.walk")
                    }
                    .disabled(model == nil)
                }
                ToolbarItem(placement: .bottomBar) {
                    Button {
                        showMeasurements = scans.first
                    } label: { Label("Measurements", systemImage: "list.number") }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        if let model { usdzURL = Dollhouse.exportUSDZ(model, name: title) }
                    } label: { Label("Share 3D", systemImage: "square.and.arrow.up") }
                    .disabled(model == nil)
                }
            }
            .sheet(item: $usdzURL) { url in ShareSheet(items: [url]) }
            .quickLookPreview($photoURL)
            .sheet(item: $showMeasurements) { scan in MeasurementsView(scan: scan) }
            .alert("Save this measurement?", isPresented: $askName) {
                TextField("What it is (e.g. Pantry shelf width)", text: $measureName)
                Button("Save") { saveMeasure() }
                Button("Discard", role: .cancel) { clearPending() }
            } message: {
                if let p = pending { Text("≈ \(FloorPlanPDF.fine(simd_distance(p.a, p.b))) in the model. Add the tape measurement later under Measurements.") }
            }
            .task { await load() }
        }
    }

    private func load() async {
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
                                            names: library.names(for: scan), floor: library.floorImage(for: scan),
                                            mesh: library.mesh(for: scan), frames: library.keyframes(for: scan)))
            }
            let ready = parts
            // Painting a LiDAR mesh takes a few seconds; off the main thread.
            let built = await Task.detached(priority: .userInitiated) { Dollhouse.build(ready) }.value
            for scan in scans {
                for m in library.measurements(for: scan).custom where m.a.count == 3 && m.b.count == 3 {
                    let text = m.confirmed.map { "✓ " + FloorPlanPDF.fine($0) } ?? FloorPlanPDF.fine(m.length)
                    built.scene.rootNode.addChildNode(Dollhouse.measureNode(SIMD3(m.a[0], m.a[1], m.a[2]),
                                                                           SIMD3(m.b[0], m.b[1], m.b[2]), text: text))
                }
            }
            model = built
        } catch {
            failure = "Couldn't read the scan: \(error.localizedDescription)"
        }
    }

    /// Measuring: the first tap marks a point, the second draws the distance and asks to save it.
    private func measureTap(_ name: String?, _ point: SIMD3<Float>?) {
        guard let point, let model else { return }
        let room = name.flatMap { n -> Int? in
            let parts = n.split(separator: ":")
            return parts.count >= 2 ? Int(parts[1]) : nil
        } ?? 0
        if let first = firstPoint {
            let node = Dollhouse.measureNode(first.point, point, text: FloorPlanPDF.fine(simd_distance(first.point, point)))
            node.name = "measure:pending"
            model.scene.rootNode.addChildNode(node)
            pending = (first.point, point, first.room)
            firstPoint = nil
            measureName = ""
            askName = true
        } else {
            firstPoint = (point, min(room, scans.count - 1))
            let dot = Dollhouse.measureNode(point, point, text: "")
            dot.name = "measure:first"
            model.scene.rootNode.addChildNode(dot)
        }
    }

    private func saveMeasure() {
        guard let p = pending, p.room < scans.count else { return }
        let scan = scans[p.room]
        var m = library.measurements(for: scan)
        let label = measureName.trimmingCharacters(in: .whitespaces)
        m.custom.append(.init(label: label.isEmpty ? "Measurement \(m.custom.count + 1)" : label,
                              a: [p.a.x, p.a.y, p.a.z], b: [p.b.x, p.b.y, p.b.z], length: simd_distance(p.a, p.b)))
        library.setMeasurements(m, for: scan)
        model?.scene.rootNode.childNodes.filter { $0.name == "measure:pending" }.forEach { $0.name = "measure" }
        model?.scene.rootNode.childNodes.filter { $0.name == "measure:first" }.forEach { $0.removeFromParentNode() }
        pending = nil
    }

    private func clearPending() {
        model?.scene.rootNode.childNodes.filter { $0.name?.hasPrefix("measure:") == true }.forEach { $0.removeFromParentNode() }
        pending = nil
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
            var shelves = ""
            if let f = library.storageFronts(for: scan).first(where: { $0.0.object == i })?.0, !f.shelves.isEmpty {
                shelves = "\nShelf openings \(FloorPlanPDF.openingsText(f)) (estimates: check with a tape)"
            }
            info = (scans.count > 1 ? "\(scan.name) · " : "") + "\(place)\(shelves)\n\(what)"
        }
    }
}

/// SceneKit's view with orbit controls, reporting the name of what's tapped.
private struct SceneViewer: UIViewRepresentable {
    let model: Dollhouse.Model
    var walk = false
    var preferSurface = false
    /// The name of what was tapped (photo, object, wall, floor, mesh; nil for unnamed) and where on it.
    let onTap: (String?, SIMD3<Float>?) -> Void

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

    /// Walk: stand in the room at eye height and fly the camera (drag to look, pinch or two fingers
    /// to move). Dollhouse: back to turning the model from outside.
    func updateUIView(_ view: SCNView, context: Context) {
        context.coordinator.preferSurface = preferSurface
        guard context.coordinator.walking != walk else { return }
        context.coordinator.walking = walk
        let camera = model.camera
        if walk {
            camera.simdPosition = model.eye
            camera.simdLook(at: model.eye + SIMD3(0, -0.1, -1))
            view.defaultCameraController.interactionMode = .fly
        } else {
            camera.simdTransform = model.start
            view.defaultCameraController.interactionMode = .orbitTurntable
            view.defaultCameraController.target = SCNVector3(model.center.x, model.center.y, model.center.z)
        }
        view.pointOfView = camera
    }

    final class Coordinator: NSObject {
        let onTap: (String?, SIMD3<Float>?) -> Void
        var walking = false
        var preferSurface = false
        init(onTap: @escaping (String?, SIMD3<Float>?) -> Void) { self.onTap = onTap }

        /// Reports the first named thing hit (skipping tags and measurement marks), with the point
        /// on its surface.
        @objc func tap(_ g: UITapGestureRecognizer) {
            guard let view = g.view as? SCNView else { return }
            var named: [(String, SIMD3<Float>)] = []
            for hit in view.hitTest(g.location(in: view), options: nil) {
                var node: SCNNode? = hit.node
                while let n = node {
                    if let name = n.name {
                        if name.hasPrefix("measure") { break }
                        if ["photo:", "object:", "wall:", "floor:", "mesh:"].contains(where: { name.hasPrefix($0) }) {
                            named.append((name, hit.simdWorldCoordinates))
                            break
                        }
                    }
                    node = n.parent
                }
            }
            // Measuring lands on the real surface (the mesh) rather than a RoomPlan box in front of it.
            if preferSurface, let surface = named.first(where: { $0.0.hasPrefix("mesh:") }) {
                onTap(surface.0, surface.1)
            } else if let first = named.first {
                onTap(first.0, first.1)
            } else {
                onTap(nil, nil)
            }
        }
    }
}
