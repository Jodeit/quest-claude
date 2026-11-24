import Foundation
import RoomPlan
import SwiftUI
import simd

/// What the organizer measured: tape measurements that confirm (and replace) the scan's estimates,
/// and distances measured in the 3D model. Kept per scan in measurements.json.
struct ScanMeasurements: Codable {
    /// Estimate key -> the tape measurement, in metres. Keys: "Wall W2", "3 Storage|width",
    /// "3 Storage|depth", "3 Storage|height", "3 Storage|opening 2" (openings top first).
    var confirmed: [String: Float] = [:]
    var custom: [CustomMeasure] = []

    struct CustomMeasure: Codable, Identifiable, Hashable {
        var id = UUID()
        var label: String
        var a: [Float]  // the two ends, ARKit world coordinates
        var b: [Float]
        var length: Float
        var confirmed: Float?
    }

    static func objectKey(_ index: Int, _ category: CapturedRoom.Object.Category, _ field: String) -> String {
        "\(index + 1) \(FloorPlanPDF.objectLabel(category))|\(field)"
    }

    static var imperial: Bool { Locale.current.measurementSystem == .us }

    /// Reads a typed length: 15, 15.25, 15 1/4, 15¼, 15", 1' 3¼", 1 ft 3 in; or centimetres
    /// outside the US. Nil if it isn't one.
    static func parse(_ text: String) -> Float? {
        var t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return nil }
        if !imperial {
            t = t.replacingOccurrences(of: "cm", with: "").trimmingCharacters(in: .whitespaces)
            guard let cm = Float(t.replacingOccurrences(of: ",", with: ".")), cm > 0 else { return nil }
            return cm / 100
        }
        for (glyph, frac) in [("½", " 1/2"), ("¼", " 1/4"), ("¾", " 3/4"), ("⅛", " 1/8"), ("⅜", " 3/8"), ("⅝", " 5/8"), ("⅞", " 7/8")] {
            t = t.replacingOccurrences(of: glyph, with: frac)
        }
        var feet: Float = 0
        if let r = t.range(of: "'") ?? t.range(of: "ft") {
            guard let f = Float(t[..<r.lowerBound].trimmingCharacters(in: .whitespaces)) else { return nil }
            feet = f
            t = String(t[r.upperBound...])
        }
        t = t.replacingOccurrences(of: "\"", with: " ").replacingOccurrences(of: "in", with: " ")
        var inches: Float = 0
        for part in t.split(separator: " ") {
            if part.contains("/") {
                let f = part.split(separator: "/")
                guard f.count == 2, let n = Float(f[0]), let d = Float(f[1]), d != 0 else { return nil }
                inches += n / d
            } else {
                guard let v = Float(part) else { return nil }
                inches += v
            }
        }
        let total = feet * 12 + inches
        return total > 0 ? total * 0.0254 : nil
    }
}

extension ScanLibrary {
    func measurements(for s: SavedScan) -> ScanMeasurements {
        guard let data = try? Data(contentsOf: folder(s).appendingPathComponent("measurements.json")),
              let m = try? JSONDecoder().decode(ScanMeasurements.self, from: data) else { return ScanMeasurements() }
        return m
    }

    /// Saves them; the plan PDF is redrawn with them next time it's opened.
    func setMeasurements(_ m: ScanMeasurements, for s: SavedScan) {
        try? JSONEncoder().encode(m).write(to: folder(s).appendingPathComponent("measurements.json"), options: .atomic)
        try? FileManager.default.removeItem(at: planURL(s))
        objectWillChange.send()
    }
}

/// Every estimate the scan made, with a field for the tape measurement that confirms it.
struct MeasurementsView: View {
    @EnvironmentObject private var library: ScanLibrary
    @Environment(\.dismiss) private var dismiss
    let scan: SavedScan

    struct Row: Identifiable {
        let id: String   // the key
        let label: String
        let estimate: Float
    }

    @State private var sections: [(String, [Row])] = []
    @State private var typed: [String: String] = [:]
    @State private var custom: [ScanMeasurements.CustomMeasure] = []
    @State private var customTyped: [UUID: String] = [:]
    @State private var bad: Set<String> = []

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Text("Type a tape measurement next to any estimate (15¼, 15 1/4 or 1' 3¼\"). Measured values "
                         + "replace the estimates in the PDF, marked ✓.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                ForEach(sections, id: \.0) { title, rows in
                    Section(title) {
                        ForEach(rows) { row in
                            entry(row.label, estimate: row.estimate, text: binding(row.id), invalid: bad.contains(row.id))
                        }
                    }
                }
                if !custom.isEmpty {
                    Section("Measured in 3D") {
                        ForEach(custom) { m in
                            entry(m.label, estimate: m.length, text: customBinding(m.id), invalid: bad.contains(m.id.uuidString))
                        }
                        .onDelete { custom.remove(atOffsets: $0) }
                    }
                }
            }
            .navigationTitle("\(scan.name) measurements")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) { Button("Save") { save() } }
            }
            .onAppear(perform: load)
        }
    }

    private func entry(_ label: String, estimate: Float, text: Binding<String>, invalid: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(label)
                Text("Scan ≈ \(FloorPlanPDF.fine(estimate))").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            TextField("Tape", text: text)
                .keyboardType(.numbersAndPunctuation)
                .multilineTextAlignment(.trailing)
                .frame(maxWidth: 110)
                .foregroundStyle(invalid ? .red : .primary)
        }
    }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { typed[key] ?? "" }, set: { typed[key] = $0 })
    }

    private func customBinding(_ id: UUID) -> Binding<String> {
        Binding(get: { customTyped[id] ?? "" }, set: { customTyped[id] = $0 })
    }

    private func load() {
        guard sections.isEmpty, let data = try? library.json(for: scan),
              let room = try? JSONDecoder().decode(CapturedRoom.self, from: data) else { return }
        let names = library.names(for: scan)
        let saved = library.measurements(for: scan)
        let fronts = library.storageFronts(for: scan).map { $0.0 }
        var out: [(String, [Row])] = []
        out.append(("Walls", room.walls.indices.map { i in
            Row(id: "Wall W\(i + 1)", label: FloorPlanPDF.shown("Wall W\(i + 1)", names), estimate: room.walls[i].dimensions.x)
        }))
        for (i, o) in room.objects.enumerated() {
            let spot = "\(i + 1) \(FloorPlanPDF.objectLabel(o.category))"
            var rows = [Row(id: "\(spot)|width", label: "Width", estimate: o.dimensions.x),
                        Row(id: "\(spot)|depth", label: "Depth", estimate: o.dimensions.z),
                        Row(id: "\(spot)|height", label: "Height", estimate: o.dimensions.y)]
            if let f = fronts.first(where: { $0.object == i }), f.openings.count > 1 {
                for (k, h) in f.openings.reversed().enumerated() {
                    rows.append(Row(id: "\(spot)|opening \(k + 1)", label: "Shelf opening \(k + 1)\(k == 0 ? " (top)" : "")", estimate: h))
                }
            }
            out.append((FloorPlanPDF.shown(spot, names), rows))
        }
        sections = out
        for (k, v) in saved.confirmed { typed[k] = FloorPlanPDF.fine(v) }
        custom = saved.custom
        for m in custom { if let c = m.confirmed { customTyped[m.id] = FloorPlanPDF.fine(c) } }
    }

    private func save() {
        var m = library.measurements(for: scan)
        bad = []
        var confirmed: [String: Float] = [:]
        for (k, t) in typed where !t.trimmingCharacters(in: .whitespaces).isEmpty {
            if let v = ScanMeasurements.parse(t) { confirmed[k] = v } else { bad.insert(k) }
        }
        var list = custom
        for i in list.indices {
            let t = customTyped[list[i].id] ?? ""
            if t.trimmingCharacters(in: .whitespaces).isEmpty {
                list[i].confirmed = nil
            } else if let v = ScanMeasurements.parse(t) {
                list[i].confirmed = v
            } else {
                bad.insert(list[i].id.uuidString)
            }
        }
        guard bad.isEmpty else { return }  // leave the sheet open with the unreadable ones in red
        m.confirmed = confirmed
        m.custom = list
        library.setMeasurements(m, for: scan)
        dismiss()
    }
}
