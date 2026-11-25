import RoomPlan
import UIKit
import simd

/// A dimensioned floor plan of a scan, drawn on the phone (no server), in Graceful Spaces colours:
/// page 1 is the plan to scale (walls with their lengths, doors, windows, furniture footprints, floor
/// area, ceiling height), page 2 a summary (spots, products, subtotals), a page per spot (front photo,
/// Scan / Tape table with blank tape boxes, products), then an elevation of each wall (when the scan kept frames), a list of every measurement, and the
/// photos taken while scanning, each pinned on the plan where it was taken. Feet and inches where
/// the phone's region uses them.
enum FloorPlanPDF {
    static func write(_ room: CapturedRoom, name: String, date: Date, photos: [(ScanPhoto, URL)] = [],
                      elevations: [(Elevation, URL)] = [], products: [ProductLine] = [],
                      names: [String: String] = [:], fronts: [(StorageFront, URL)] = [],
                      measured: ScanMeasurements = ScanMeasurements(), prices: [String: Double]? = nil,
                      to url: URL) throws {
        try render(room, name: name, date: date, photos: photos, elevations: elevations, products: products,
                   names: names, fronts: fronts, measured: measured, prices: prices).write(to: url, options: .atomic)
    }

    /// To the nearest half inch (or centimetre), as estimates and tape measurements are shown.
    static func fine(_ m: Float) -> String { Units(imperial: ScanMeasurements.imperial).fine(m) }

    /// Shelf openings, top first, for a line of text: "≈ 15½", 14½", 24"".
    static func openingsText(_ f: StorageFront) -> String {
        let units = Units(imperial: Locale.current.measurementSystem == .us)
        return "≈ " + f.openings.reversed().map(units.fine).joined(separator: ", ")
    }

    /// A spot's label with the name the organizer gave it: "3 Storage" named "Coffee station" shows
    /// as "3 Coffee station", "Wall W2" named "Coffee bar" as "W2 Coffee bar". Unnamed: as is.
    static func shown(_ key: String, _ names: [String: String]) -> String {
        guard let n = names[key]?.trimmingCharacters(in: .whitespaces), !n.isEmpty else { return key }
        if key.hasPrefix("Wall ") { return "\(key.dropFirst(5)) \(n)" }
        if key == ProductLine.wholeRoom { return n }
        return "\(key.split(separator: " ").first ?? "") \(n)"
    }

    /// "washerDryer" -> "Washer dryer": how objects are named on the plan and in product locations.
    static func objectLabel(_ c: CapturedRoom.Object.Category) -> String { Plan.label(c) }

    static func render(_ room: CapturedRoom, name: String, date: Date, photos: [(ScanPhoto, URL)] = [],
                       elevations: [(Elevation, URL)] = [], products productsIn: [ProductLine] = [],
                       names: [String: String] = [:], fronts: [(StorageFront, URL)] = [],
                       measured: ScanMeasurements = ScanMeasurements(), prices: [String: Double]? = nil) -> Data {
        // One price source for every total: the catalog's price table (Catalog.priceTable), as the
        // product screen and CSV use. Callers without a catalog fall back to the prices saved on the
        // lines, so totals can differ from the app until they pass `prices`.
        var table: [String: Double] = [:]
        if let given = prices {
            table = given
        } else {
            for l in productsIn {
                if let p = l.price, table[l.product] == nil { table[l.product] = p }
            }
        }
        let products: [ProductLine] = ProductExport.repriced(productsIn, prices: table)
        var plan = Plan(room, photos: photos.map { $0.0 })
        plan.names = names
        let units = Units(imperial: Locale.current.measurementSystem == .us)
        let page = plan.size.x > plan.size.y * 1.1
            ? CGRect(x: 0, y: 0, width: 792, height: 612)   // US Letter, landscape
            : CGRect(x: 0, y: 0, width: 612, height: 792)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "\(name) floor plan",
                               kCGPDFContextCreator as String: "RoomScan",
                               kCGPDFContextAuthor as String: "Graceful Spaces"]
        let pager = Pager(room: name)
        return UIGraphicsPDFRenderer(bounds: page, format: format).pdfData { pdf in
            begin(pdf, pager, page)
            drawPlan(plan, units: units, name: name, date: date, page: page, ctx: pdf.cgContext)
            let photoFiles = photos.map { $0.1 }
            func photosOf(_ subject: Plan.Subject) -> [(Int, URL)] {
                plan.pins.indices.filter { plan.pins[$0].subject == subject && $0 < photoFiles.count }.map { ($0, photoFiles[$0]) }
            }
            // A page per spot that matters: storage, or named, or with products or photos.
            func keyOf(_ i: Int) -> String { "\(i + 1) \(Plan.label(room.objects[i].category))" }
            var spotIndexes: [Int] = []
            for (i, o) in room.objects.enumerated() {
                let key = keyOf(i)
                let hasFront: Bool = fronts.contains { $0.0.object == i }
                let hasProducts: Bool = products.contains { $0.location == key }
                let hasPhotos: Bool = !photosOf(.item(i)).isEmpty
                guard hasFront || hasProducts || hasPhotos || names[key] != nil || o.category == .storage else { continue }
                spotIndexes.append(i)
            }
            // The summary page: totals, then each spot and other location with its products.
            var summary: [SpotSummary] = []
            var seen: [String] = []
            for i in spotIndexes {
                let key = keyOf(i)
                let here: [ProductLine] = products.filter { $0.location == key }
                let d = room.objects[i].dimensions
                summary.append(SpotSummary(label: shown(key, names),
                                           size: "\(units.ftIn(d.x)) × \(units.ftIn(d.z)) × \(units.ftIn(d.y))",
                                           qty: here.reduce(0) { $0 + $1.qty }, subtotal: subtotal(here)))
                seen.append(key)
            }
            var others: [String] = []
            for l in products where !seen.contains(l.location) && !others.contains(l.location) { others.append(l.location) }
            for loc in others {
                let here: [ProductLine] = products.filter { $0.location == loc }
                summary.append(SpotSummary(label: shown(loc, names), size: "",
                                           qty: here.reduce(0) { $0 + $1.qty }, subtotal: subtotal(here)))
            }
            drawSummary(plan, units: units, name: name, date: date, room: room, rows: summary,
                        spotCount: spotIndexes.count, products: products, prices: table, photoCount: photos.count,
                        page: page, pdf: pdf, pager: pager)
            for i in spotIndexes {
                let o = room.objects[i]
                let key = keyOf(i)
                let front = fronts.first { $0.0.object == i }
                let here: [ProductLine] = products.filter { $0.location == key }
                drawSpot(key: key, label: shown(key, names), size: o.dimensions, front: front, products: here,
                         photos: photosOf(.item(i)), units: units, name: name, measured: measured, page: page,
                         pdf: pdf, pager: pager)
            }
            for (e, url) in elevations.sorted(by: { $0.0.wall < $1.0.wall }) where e.wall < room.walls.count {
                let key = "Wall W\(e.wall + 1)"
                drawElevation(e, image: url, room: room, units: units, name: name, names: names,
                              products: products.filter { $0.location == key }, photos: photosOf(.wall(e.wall)),
                              page: page, pdf: pdf, pager: pager)
            }
            drawList(plan, units: units, name: name, page: page, pdf: pdf, pager: pager, fronts: fronts.map { $0.0 },
                     measured: measured)
            drawProducts(products, name: name, names: names, page: page, pdf: pdf, pager: pager)
            drawPhotos(plan, files: photos.map { $0.1 }, name: name, page: page, pdf: pdf, pager: pager)
        }
    }

    // MARK: page 1, the plan

    private static let margin: CGFloat = 40
    // Graceful Spaces: warm gold (#A6884F), grey (#7B7C7C), soft charcoal ink, a warm paper tint.
    private static let ink = UIColor(red: 0.13, green: 0.13, blue: 0.13, alpha: 1)
    private static let faint = UIColor(red: 0.482, green: 0.486, blue: 0.486, alpha: 1)
    private static let gold = UIColor(red: 0.651, green: 0.533, blue: 0.310, alpha: 1)
    private static let paper = UIColor(red: 0.973, green: 0.961, blue: 0.941, alpha: 1)
    private static let doorColor = UIColor(red: 0.55, green: 0.33, blue: 0.15, alpha: 1)
    private static let windowColor = UIColor(red: 0.15, green: 0.4, blue: 0.75, alpha: 1)
    private static let photoColor = UIColor(red: 0.6, green: 0.2, blue: 0.45, alpha: 1)

    /// Starts a page and puts the brand footer on it: the room's name and the page number.
    private static func begin(_ pdf: UIGraphicsPDFRendererContext, _ pager: Pager, _ page: CGRect) {
        pdf.beginPage()
        pager.number += 1
        let y: CGFloat = page.height - 24
        line(pdf.cgContext, CGPoint(x: margin, y: y - 9), CGPoint(x: page.width - margin, y: y - 9),
             width: 0.5, color: gold, cap: .butt)
        text("GRACEFUL SPACES  ·  \(pager.room)", at: CGPoint(x: margin, y: y), size: 7, color: faint, anchor: .left)
        text("\(pager.number)", at: CGPoint(x: page.width - margin, y: y), size: 8, color: faint, anchor: .right)
    }

    /// A big figure over a small gold label.
    private static func stat(_ label: String, _ value: String, in r: CGRect) {
        text(value, at: CGPoint(x: r.minX, y: r.minY), size: 20, anchor: .topLeft, serif: true)
        text(label.uppercased(), at: CGPoint(x: r.minX, y: r.minY + 30), size: 7.5, weight: .semibold,
             color: gold, anchor: .topLeft)
    }

    private static func money(_ v: Double) -> String {
        let f = NumberFormatter()
        f.numberStyle = .currency
        f.currencyCode = "USD"
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: v)) ?? String(format: "$%.2f", v)
    }

    /// Price times quantity over the lines that have a price.
    private static func subtotal(_ lines: [ProductLine]) -> Double {
        var table: [String: Double] = [:]
        for l in lines {
            if let p = l.price { table[l.product] = p }
        }
        return ProductExport.subtotal(lines, prices: table)
    }

    private static func drawPlan(_ plan: Plan, units: Units, name: String, date: Date,
                                 page: CGRect, ctx: CGContext) {
        // Title block.
        text(name, at: CGPoint(x: margin, y: margin), size: 20, anchor: .topLeft, serif: true)
        line(ctx, CGPoint(x: margin, y: margin + 44), CGPoint(x: margin + 40, y: margin + 44), width: 1.5,
             color: gold, cap: .butt)
        var facts = [date.formatted(date: .long, time: .omitted)]
        if let a = plan.area { facts.append("Floor area \(units.area(a))") }
        if let h = plan.ceiling { facts.append("Ceiling \(units.length(h))") }
        text(facts.joined(separator: "  ·  "), at: CGPoint(x: margin, y: margin + 27), size: 10,
             color: faint, anchor: .topLeft)

        // Drawing area, leaving room around the walls for the dimension lines.
        let header: CGFloat = 60, footer: CGFloat = 48
        let box = CGRect(x: margin, y: margin + header, width: page.width - 2 * margin,
                         height: page.height - 2 * margin - header - footer).insetBy(dx: 34, dy: 34)
        let size = SIMD2<Float>(Swift.max(plan.size.x, 0.5), Swift.max(plan.size.y, 0.5))
        let scale = CGFloat(Swift.min(Float(box.width) / size.x, Float(box.height) / size.y))
        let mid = (plan.lo + plan.hi) / 2
        func pt(_ p: SIMD2<Float>) -> CGPoint {
            CGPoint(x: box.midX + CGFloat(p.x - mid.x) * scale, y: box.midY + CGFloat(p.y - mid.y) * scale)
        }

        // Floor.
        for poly in plan.floors where poly.count > 2 {
            ctx.beginPath()
            ctx.addLines(between: poly.map(pt))
            ctx.closePath()
            ctx.setFillColor(paper.cgColor)
            ctx.fillPath()
        }

        // Furniture and fixtures as footprints, numbered to match the list.
        for (i, item) in plan.items.enumerated() {
            ctx.beginPath()
            ctx.addLines(between: item.corners.map(pt))
            ctx.closePath()
            ctx.setFillColor(UIColor.white.cgColor)
            ctx.setStrokeColor(faint.cgColor)
            ctx.setLineWidth(0.75)
            ctx.drawPath(using: .fillStroke)
            let c = pt(item.center)
            let fits = CGFloat(Swift.min(item.width, item.depth)) * scale > 26
            text(fits ? shown("\(i + 1) \(item.name)", plan.names) : "\(i + 1)", at: c, size: fits ? 7 : 6.5,
                 color: faint)
        }

        // Walls.
        for wall in plan.walls {
            line(ctx, pt(wall.a), pt(wall.b), width: 4, color: ink, cap: .square)
        }

        // Openings cut the wall; doors get jambs, windows a double line.
        func gap(_ o: Plan.Opening) { line(ctx, pt(o.a), pt(o.b), width: 6, color: .white, cap: .butt) }
        for o in plan.openings { gap(o) }
        for o in plan.windows {
            gap(o)
            let n = cg(o.out) * 1.6
            line(ctx, pt(o.a) + n, pt(o.b) + n, width: 0.8, color: windowColor)
            line(ctx, pt(o.a) - n, pt(o.b) - n, width: 0.8, color: windowColor)
        }
        for (i, o) in plan.doors.enumerated() {
            gap(o)
            let n = cg(o.out) * 3
            line(ctx, pt(o.a) - n, pt(o.a) + n, width: 1.2, color: doorColor)
            line(ctx, pt(o.b) - n, pt(o.b) + n, width: 1.2, color: doorColor)
            let at = (pt(o.a) + pt(o.b)) * 0.5 - cg(o.out) * 10
            text("D\(i + 1) \(units.length(o.width))", at: at, size: 6.5, color: doorColor,
                 angle: upright(pt(o.b) - pt(o.a)))
        }
        for (i, o) in plan.windows.enumerated() {
            let at = (pt(o.a) + pt(o.b)) * 0.5 - cg(o.out) * 10
            text("Win\(i + 1) \(units.length(o.width))", at: at, size: 6.5, color: windowColor,
                 angle: upright(pt(o.b) - pt(o.a)))
        }

        // Each wall's length on a dimension line outside it, and its number inside, a quarter of the
        // way along (the middle is where door and window labels go). A wall with floor on both sides
        // (between two scanned spaces) has no outside, so its length goes with its number instead.
        for (i, wall) in plan.walls.enumerated() {
            let a = pt(wall.a), b = pt(wall.b), n = cg(wall.out)
            let tagAt = a + (b - a) * 0.25 - n * 9
            if wall.interior {
                text("W\(i + 1) · \(units.length(wall.length))", at: tagAt, size: 6.5, color: faint,
                     angle: upright(b - a))
                continue
            }
            let off: CGFloat = 14
            let da = a + n * off, db = b + n * off
            line(ctx, a + n * 4, da + n * 3, width: 0.4, color: faint)
            line(ctx, b + n * 4, db + n * 3, width: 0.4, color: faint)
            line(ctx, da, db, width: 0.6, color: ink)
            let u = unit(b - a)
            for e in [da, db] { line(ctx, e - (u + n) * 3, e + (u + n) * 3, width: 0.9, color: ink) }
            let angle = upright(b - a)
            text(units.length(wall.length), at: (da + db) * 0.5 + n * 7, size: 8.5, weight: .medium,
                 angle: angle)
            text("W\(i + 1)", at: tagAt, size: 6, color: faint, angle: angle)
        }

        // Photo pins: where each photo was taken, with a wedge the way it faced.
        for (i, pin) in plan.pins.enumerated() {
            let at = pt(pin.at), f = cg(pin.facing)
            let spread: CGFloat = 0.45, reach: CGFloat = 20
            func turned(_ a: CGFloat) -> CGPoint {
                CGPoint(x: f.x * cos(a) - f.y * sin(a), y: f.x * sin(a) + f.y * cos(a))
            }
            ctx.beginPath()
            ctx.move(to: at)
            ctx.addLine(to: at + turned(-spread) * reach)
            ctx.addLine(to: at + turned(spread) * reach)
            ctx.closePath()
            ctx.setFillColor(photoColor.withAlphaComponent(0.22).cgColor)
            ctx.fillPath()
            ctx.setFillColor(photoColor.cgColor)
            ctx.fillEllipse(in: CGRect(x: at.x - 7.5, y: at.y - 7.5, width: 15, height: 15))
            text("P\(i + 1)", at: at, size: 6, weight: .bold, color: .white)
        }

        // Scale bar and a note on where the numbers come from.
        let barY = page.height - margin - 26
        let step = units.scaleStep(maxMetres: Float(box.width / 4 / scale))
        let barLen = CGFloat(step.metres) * scale
        let x0 = margin
        line(ctx, CGPoint(x: x0, y: barY), CGPoint(x: x0 + barLen, y: barY), width: 1.2, color: ink)
        for x in [x0, x0 + barLen] {
            line(ctx, CGPoint(x: x, y: barY - 4), CGPoint(x: x, y: barY + 4), width: 1, color: ink)
        }
        text(step.label, at: CGPoint(x: x0 + barLen + 6, y: barY), size: 8, anchor: .left)
        text("Measured with iPhone LiDAR (Apple RoomPlan). Furniture is shown as boxes. "
             + "Check critical dimensions before ordering or building.",
             at: CGPoint(x: margin, y: page.height - margin - 6), size: 7, color: faint, anchor: .left)
    }

    // MARK: summary page

    private static func drawSummary(_ plan: Plan, units: Units, name: String, date: Date, room: CapturedRoom,
                                    rows: [SpotSummary], spotCount: Int, products: [ProductLine], prices: [String: Double],
                                    photoCount: Int,
                                    page: CGRect, pdf: UIGraphicsPDFRendererContext, pager: Pager) {
        begin(pdf, pager, page)
        let ctx = pdf.cgContext
        text("ROOM SUMMARY", at: CGPoint(x: margin, y: margin), size: 8, weight: .semibold, color: gold, anchor: .topLeft)
        text(name, at: CGPoint(x: margin, y: margin + 14), size: 24, anchor: .topLeft, serif: true)
        line(ctx, CGPoint(x: margin, y: margin + 52), CGPoint(x: margin + 48, y: margin + 52), width: 1.5,
             color: gold, cap: .butt)
        text(date.formatted(date: .long, time: .omitted), at: CGPoint(x: margin, y: margin + 62), size: 10,
             color: faint, anchor: .topLeft)

        let items: Int = products.reduce(0) { $0 + $1.qty }
        let total: Double = subtotal(products)
        var tiles: [(String, String)] = []
        tiles.append(("Floor area", plan.area.map { units.area($0) } ?? "n/a"))
        tiles.append(("Ceiling", plan.ceiling.map { units.length($0) } ?? "n/a"))
        tiles.append(("Spots", "\(spotCount)"))
        tiles.append(("Doors · windows", "\(room.doors.count) · \(room.windows.count)"))
        tiles.append(("Products", "\(items)"))
        tiles.append(("Subtotal", items == 0 ? "n/a" : money(total)))
        let top: CGFloat = margin + 92
        let colW: CGFloat = (page.width - 2 * margin) / 3
        for (k, t) in tiles.enumerated() {
            let col = CGFloat(k % 3), r = CGFloat(k / 3)
            stat(t.0, t.1, in: CGRect(x: margin + col * colW, y: top + r * 60, width: colW, height: 52))
        }

        let xr: CGFloat = page.width - margin
        var y: CGFloat = top + 2 * 60 + 14
        func header() {
            text("SPOT OR LOCATION", at: CGPoint(x: margin + 4, y: y), size: 7.5, weight: .semibold, color: gold, anchor: .left)
            text("SIZE (W × D × H)", at: CGPoint(x: margin + 210, y: y), size: 7.5, weight: .semibold, color: gold, anchor: .left)
            text("ITEMS", at: CGPoint(x: xr - 80, y: y), size: 7.5, weight: .semibold, color: gold, anchor: .right)
            text("SUBTOTAL", at: CGPoint(x: xr - 4, y: y), size: 7.5, weight: .semibold, color: gold, anchor: .right)
            y += 10
            line(pdf.cgContext, CGPoint(x: margin, y: y), CGPoint(x: xr, y: y), width: 0.6, color: gold, cap: .butt)
            y += 3
        }
        header()
        let rowH: CGFloat = 19
        for (k, r) in rows.enumerated() {
            if y + rowH > page.height - margin - 24 {
                begin(pdf, pager, page)
                y = margin + 10
                header()
            }
            if k % 2 == 0 {
                pdf.cgContext.setFillColor(paper.cgColor)
                pdf.cgContext.fill(CGRect(x: margin, y: y, width: xr - margin, height: rowH))
            }
            let cy = y + rowH / 2
            textBox(r.label, in: CGRect(x: margin + 4, y: cy - 7, width: 196, height: 14), size: 9.5)
            textBox(r.size, in: CGRect(x: margin + 210, y: cy - 7, width: xr - 80 - 40 - (margin + 210), height: 14),
                    size: 9, color: faint)
            text(r.qty == 0 ? "" : "\(r.qty)", at: CGPoint(x: xr - 80, y: cy), size: 9.5, anchor: .right)
            text(r.qty == 0 ? "" : money(r.subtotal), at: CGPoint(x: xr - 4, y: cy), size: 9.5, anchor: .right)
            y += rowH
        }
        if rows.isEmpty {
            text("No spots or products yet.", at: CGPoint(x: margin + 4, y: y + 10), size: 9, color: faint, anchor: .left)
            y += rowH
        }
        if y + 40 > page.height - margin - 24 {
            begin(pdf, pager, page)
            y = margin + 10
        }
        y += 6
        line(pdf.cgContext, CGPoint(x: margin, y: y), CGPoint(x: xr, y: y), width: 0.8, color: gold, cap: .butt)
        y += 14
        text("Room total", at: CGPoint(x: margin + 4, y: y), size: 11, weight: .semibold, anchor: .left, serif: true)
        text("\(items)", at: CGPoint(x: xr - 80, y: y), size: 10.5, weight: .semibold, anchor: .right)
        text(money(total), at: CGPoint(x: xr - 4, y: y), size: 10.5, weight: .semibold, anchor: .right)
        y += 20
        let unpriced: Int = ProductExport.unpricedCount(products, prices: prices)
        var notes: [String] = []
        if unpriced > 0 { notes.append("\(unpriced) product line\(unpriced == 1 ? "" : "s") without a price left out of subtotals.") }
        if photoCount > 0 { notes.append("\(photoCount) photo\(photoCount == 1 ? "" : "s") taken while scanning, pinned on the plan.") }
        for n in notes {
            text(n, at: CGPoint(x: margin + 4, y: y), size: 8.5, color: faint, anchor: .left)
            y += 13
        }
    }

    // MARK: page 2+, the measurements

    private static func drawList(_ plan: Plan, units: Units, name: String, page: CGRect,
                                 pdf: UIGraphicsPDFRendererContext, pager: Pager, fronts: [StorageFront] = [],
                                 measured: ScanMeasurements = ScanMeasurements()) {
        func tape(_ key: String) -> String {
            measured.confirmed[key].map { "; ✓ measured \(units.fine($0))" } ?? ""
        }
        func tapeDims(_ spot: String) -> String {
            let parts = [("w", "width"), ("d", "depth"), ("h", "height")].compactMap { short, field in
                measured.confirmed["\(spot)|\(field)"].map { "\(units.fine($0)) \(short)" }
            }
            return parts.isEmpty ? "" : "; ✓ measured " + parts.joined(separator: " × ")
        }
        func shelvesIn(_ i: Int) -> String {
            guard let f = fronts.first(where: { $0.object == i }), !f.shelves.isEmpty else { return "" }
            return "; \(f.shelves.count) shel\(f.shelves.count == 1 ? "f" : "ves"), openings \(openingsText(f))"
        }
        func seenIn(_ subject: Plan.Subject) -> String {
            let shots = plan.pins.indices.filter { plan.pins[$0].subject == subject }.map { "P\($0 + 1)" }
            return shots.isEmpty ? "" : "; photos \(shots.joined(separator: ", "))"
        }
        var rows: [(String, String, String)] = []
        for (i, w) in plan.walls.enumerated() {
            rows.append(("W\(i + 1)", plan.names["Wall W\(i + 1)"] ?? "Wall", "\(units.length(w.length)) long, \(units.length(w.height)) high"
                         + tape("Wall W\(i + 1)") + seenIn(.wall(i))))
        }
        for (i, d) in plan.doors.enumerated() {
            rows.append(("D\(i + 1)", "Door", "\(units.ftIn(d.width)) wide, \(units.ftIn(d.height)) high"))
        }
        for (i, w) in plan.windows.enumerated() {
            rows.append(("Win\(i + 1)", "Window", "\(units.ftIn(w.width)) wide, \(units.ftIn(w.height)) high, "
                         + "sill \(units.ftIn(w.sill)) above the floor"))
        }
        for o in plan.openings {
            rows.append(("", "Opening", "\(units.ftIn(o.width)) wide, \(units.ftIn(o.height)) high"))
        }
        for (i, item) in plan.items.enumerated() {
            rows.append(("\(i + 1)", plan.names["\(i + 1) \(item.name)"].map { "\($0) (\(item.name))" } ?? item.name, "\(units.length(item.width)) wide × "
                         + "\(units.length(item.depth)) deep × \(units.length(item.height)) high"
                         + tapeDims("\(i + 1) \(item.name)") + shelvesIn(i) + seenIn(.item(i))))
        }
        for (k, m) in measured.custom.enumerated() {
            rows.append(("M\(k + 1)", m.label, "measured in 3D ≈ \(units.fine(m.length))"
                         + (m.confirmed.map { "; ✓ tape \(units.fine($0))" } ?? "")))
        }
        guard !rows.isEmpty else { return }

        let rowH: CGFloat = 17
        var y = page.height  // forces a new page on the first row
        for (i, row) in rows.enumerated() {
            if y + rowH > page.height - margin {
                begin(pdf, pager, page)
                text("\(name): measurements", at: CGPoint(x: margin, y: margin), size: 16, anchor: .topLeft,
                     serif: true)
                y = margin + 34
            }
            if i % 2 == 0 {
                pdf.cgContext.setFillColor(paper.cgColor)
                pdf.cgContext.fill(CGRect(x: margin - 4, y: y, width: page.width - 2 * margin + 8, height: rowH))
            }
            let cy = y + rowH / 2
            text(row.0, at: CGPoint(x: margin, y: cy), size: 9, weight: .medium, anchor: .left)
            text(row.1, at: CGPoint(x: margin + 36, y: cy), size: 9, anchor: .left)
            text(row.2, at: CGPoint(x: margin + 150, y: cy), size: 9, anchor: .left)
            y += rowH
        }
    }

    // MARK: home plan

    /// Every room of a home on one page, where they are relative to each other (they were scanned in
    /// one camera session, so they share coordinates): walls, doors and windows, each room's name
    /// and floor area. Each room's own PDF has the dimensions.
    static func renderHome(_ rooms: [(name: String, room: CapturedRoom)], title: String, date: Date) -> Data {
        guard let first = rooms.first else { return Data() }
        let angle = Plan(first.room).angle
        let plans = rooms.map { (name: $0.name, plan: Plan($0.room, angle: angle)) }
        let points = plans.flatMap { [$0.plan.lo, $0.plan.hi] }
        let lo = points.dropFirst().reduce(points[0]) { simd_min($0, $1) }
        let hi = points.dropFirst().reduce(points[0]) { simd_max($0, $1) }
        let size = SIMD2<Float>(Swift.max(hi.x - lo.x, 0.5), Swift.max(hi.y - lo.y, 0.5))
        let page = size.x > size.y * 1.1 ? CGRect(x: 0, y: 0, width: 792, height: 612)
            : CGRect(x: 0, y: 0, width: 612, height: 792)
        let units = Units(imperial: Locale.current.measurementSystem == .us)
        let format = UIGraphicsPDFRendererFormat()
        format.documentInfo = [kCGPDFContextTitle as String: "\(title) plan", kCGPDFContextCreator as String: "RoomScan",
                               kCGPDFContextAuthor as String: "Graceful Spaces"]
        let pager = Pager(room: title)
        return UIGraphicsPDFRenderer(bounds: page, format: format).pdfData { pdf in
            drawHomeCover(rooms: rooms, plans: plans, title: title, date: date, units: units, page: page, pdf: pdf,
                          pager: pager)
            begin(pdf, pager, page)
            let ctx = pdf.cgContext
            let total = plans.compactMap { $0.plan.area }.reduce(0, +)
            text(title, at: CGPoint(x: margin, y: margin), size: 20, anchor: .topLeft, serif: true)
            text("\(date.formatted(date: .long, time: .omitted))  ·  \(rooms.count) rooms  ·  "
                 + "\(units.area(total)) scanned", at: CGPoint(x: margin, y: margin + 27), size: 10,
                 color: faint, anchor: .topLeft)
            let box = CGRect(x: margin, y: margin + 60, width: page.width - 2 * margin,
                             height: page.height - 2 * margin - 60 - 30).insetBy(dx: 10, dy: 10)
            let scale = CGFloat(Swift.min(Float(box.width) / size.x, Float(box.height) / size.y))
            let mid = (lo + hi) / 2
            func pt(_ p: SIMD2<Float>) -> CGPoint {
                CGPoint(x: box.midX + CGFloat(p.x - mid.x) * scale, y: box.midY + CGFloat(p.y - mid.y) * scale)
            }
            let tints: [UIColor] = [UIColor(red: 0.93, green: 0.95, blue: 0.97, alpha: 1),
                                    UIColor(red: 0.96, green: 0.94, blue: 0.91, alpha: 1),
                                    UIColor(red: 0.93, green: 0.96, blue: 0.93, alpha: 1),
                                    UIColor(red: 0.96, green: 0.93, blue: 0.95, alpha: 1)]
            for (k, entry) in plans.enumerated() {
                for poly in entry.plan.floors where poly.count > 2 {
                    ctx.beginPath()
                    ctx.addLines(between: poly.map(pt))
                    ctx.closePath()
                    ctx.setFillColor(tints[k % tints.count].cgColor)
                    ctx.fillPath()
                }
            }
            for entry in plans {
                let plan = entry.plan
                for wall in plan.walls { line(ctx, pt(wall.a), pt(wall.b), width: 3, color: ink, cap: .square) }
                for o in plan.openings + plan.doors { line(ctx, pt(o.a), pt(o.b), width: 5, color: .white, cap: .butt) }
                for o in plan.doors {
                    let n = cg(o.out) * 2.5
                    line(ctx, pt(o.a) - n, pt(o.a) + n, width: 1, color: doorColor)
                    line(ctx, pt(o.b) - n, pt(o.b) + n, width: 1, color: doorColor)
                }
                for o in plan.windows { line(ctx, pt(o.a), pt(o.b), width: 2, color: windowColor, cap: .butt) }
            }
            for entry in plans {
                let plan = entry.plan
                let pts = plan.floors.first ?? plan.walls.flatMap { [$0.a, $0.b] }
                guard !pts.isEmpty else { continue }
                let c = pts.reduce(SIMD2<Float>(0, 0), +) / Float(pts.count)
                text(entry.name, at: pt(c) - CGPoint(x: 0, y: 6), size: 10, weight: .semibold)
                if let a = plan.area { text(units.area(a), at: pt(c) + CGPoint(x: 0, y: 7), size: 8, color: faint) }
            }
            text("Rooms scanned one after another in one session, so they sit where they are in the home. "
                 + "Each room's own plan has its dimensions.",
                 at: CGPoint(x: margin, y: page.height - margin - 6), size: 7, color: faint, anchor: .left)
        }
    }

    /// The home's cover: its name, the totals, and each room with its floor area.
    private static func drawHomeCover(rooms: [(name: String, room: CapturedRoom)],
                                      plans: [(name: String, plan: Plan)], title: String, date: Date, units: Units,
                                      page: CGRect, pdf: UIGraphicsPDFRendererContext, pager: Pager) {
        begin(pdf, pager, page)
        let ctx = pdf.cgContext
        text("GRACEFUL SPACES", at: CGPoint(x: margin, y: margin), size: 8, weight: .semibold, color: gold, anchor: .topLeft)
        text(title, at: CGPoint(x: margin, y: margin + 16), size: 28, anchor: .topLeft, serif: true)
        line(ctx, CGPoint(x: margin, y: margin + 62), CGPoint(x: margin + 48, y: margin + 62), width: 1.5,
             color: gold, cap: .butt)
        text(date.formatted(date: .long, time: .omitted), at: CGPoint(x: margin, y: margin + 72), size: 10,
             color: faint, anchor: .topLeft)

        let area: Float = plans.compactMap { $0.plan.area }.reduce(0, +)
        let storage: Int = rooms.reduce(0) { $0 + $1.room.objects.filter { $0.category == .storage }.count }
        var tiles: [(String, String)] = []
        tiles.append(("Rooms", "\(rooms.count)"))
        tiles.append(("Floor area", units.area(area)))
        tiles.append(("Storage spots", "\(storage)"))
        let top: CGFloat = margin + 108
        let colW: CGFloat = (page.width - 2 * margin) / 3
        for (k, t) in tiles.enumerated() {
            stat(t.0, t.1, in: CGRect(x: margin + CGFloat(k) * colW, y: top, width: colW, height: 52))
        }

        let xr: CGFloat = page.width - margin
        var y: CGFloat = top + 76
        func header() {
            text("ROOM", at: CGPoint(x: margin + 4, y: y), size: 7.5, weight: .semibold, color: gold, anchor: .left)
            text("FLOOR AREA", at: CGPoint(x: margin + 210, y: y), size: 7.5, weight: .semibold, color: gold, anchor: .left)
            text("STORAGE", at: CGPoint(x: xr - 90, y: y), size: 7.5, weight: .semibold, color: gold, anchor: .right)
            text("DOORS · WINDOWS", at: CGPoint(x: xr - 4, y: y), size: 7.5, weight: .semibold, color: gold, anchor: .right)
            y += 10
            line(pdf.cgContext, CGPoint(x: margin, y: y), CGPoint(x: xr, y: y), width: 0.6, color: gold, cap: .butt)
            y += 3
        }
        header()
        let rowH: CGFloat = 20
        for (k, entry) in rooms.enumerated() {
            if y + rowH > page.height - margin - 24 {
                begin(pdf, pager, page)
                y = margin + 10
                header()
            }
            if k % 2 == 0 {
                pdf.cgContext.setFillColor(paper.cgColor)
                pdf.cgContext.fill(CGRect(x: margin, y: y, width: xr - margin, height: rowH))
            }
            let cy = y + rowH / 2
            let a: String = k < plans.count ? (plans[k].plan.area.map { units.area($0) } ?? "") : ""
            let n: Int = entry.room.objects.filter { $0.category == .storage }.count
            textBox(entry.name, in: CGRect(x: margin + 4, y: cy - 7, width: 196, height: 14), size: 10)
            text(a, at: CGPoint(x: margin + 210, y: cy), size: 10, anchor: .left)
            text("\(n)", at: CGPoint(x: xr - 90, y: cy), size: 10, anchor: .right)
            text("\(entry.room.doors.count) · \(entry.room.windows.count)", at: CGPoint(x: xr - 4, y: cy), size: 10,
                 anchor: .right)
            y += rowH
        }
    }

    // MARK: spot pages

    /// Everything about one spot (a storage unit, or anything named, holding products or photographed)
    /// on one page, leading with its front: the front to scale with the shelves found, then a Scan /
    /// Tape table (the scan's estimates beside empty boxes for the tape measurement), the products
    /// that go there with quantities and a subtotal, and the photos of it.
    private static func drawSpot(key: String, label: String, size: SIMD3<Float>, front: (StorageFront, URL)?,
                                 products: [ProductLine], photos: [(Int, URL)], units: Units, name: String,
                                 measured: ScanMeasurements, page: CGRect, pdf: UIGraphicsPDFRendererContext,
                                 pager: Pager) {
        begin(pdf, pager, page)
        let ctx = pdf.cgContext
        let accent = UIColor(red: 0.85, green: 0.1, blue: 0.35, alpha: 1)
        let green = UIColor(red: 0.1, green: 0.5, blue: 0.25, alpha: 1)
        text(name.uppercased(), at: CGPoint(x: margin, y: margin), size: 8, weight: .semibold, color: gold, anchor: .topLeft)
        text(label, at: CGPoint(x: margin, y: margin + 13), size: 20, anchor: .topLeft, serif: true)
        line(ctx, CGPoint(x: margin, y: margin + 46), CGPoint(x: margin + 40, y: margin + 46), width: 1.5,
             color: gold, cap: .butt)
        text("Scan sizes are estimates (about ±1\"). Write the tape measurement in each box; ✓ marks one already entered.",
             at: CGPoint(x: margin, y: margin + 54), size: 8.5, color: faint, anchor: .topLeft)

        let tableW: CGFloat = 250
        let tx = page.width - margin - tableW
        let left = CGRect(x: margin + 24, y: margin + 76, width: tx - margin - 60, height: page.height - 2 * margin - 76 - 36)

        // Left: the front with its shelves, or the photos when there's no front.
        var openings: [(top: Float, bottom: Float)] = []
        if let fr = front, let image = UIImage(contentsOfFile: fr.1.path) {
            let f = fr.0
            let s = Swift.min(left.width / CGFloat(f.width), left.height / CGFloat(f.height))
            let r = CGRect(x: left.minX, y: left.minY, width: CGFloat(f.width) * s, height: CGFloat(f.height) * s)
            image.draw(in: r)
            ctx.setStrokeColor(ink.cgColor)
            ctx.setLineWidth(1)
            ctx.stroke(r)
            for (k, h) in f.shelves.enumerated() {
                let y = r.maxY - CGFloat(h) * s
                if let sure = f.confirmed, k < sure.count, !sure[k] {
                    // Not backed by the depth scan: maybe a bin or box edge. Dashed, to check.
                    ctx.saveGState()
                    ctx.setLineDash(phase: 0, lengths: [6, 4])
                    line(ctx, CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y), width: 1.4, color: accent, cap: .butt)
                    ctx.restoreGState()
                } else {
                    line(ctx, CGPoint(x: r.minX, y: y), CGPoint(x: r.maxX, y: y), width: 1.6, color: accent, cap: .butt)
                }
            }
            let edges = [Float(0)] + f.shelves + [f.height]
            for k in 1..<edges.count where edges[k] - edges[k - 1] > 0.05 { openings.append((edges[k], edges[k - 1])) }
            openings.reverse()
            for (k, o) in openings.enumerated() where openings.count > 1 {
                let y = r.maxY - CGFloat((o.top + o.bottom) / 2) * s
                let tag = "\(k + 1)  \(units.ftIn(o.top - o.bottom))"
                let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 9, weight: .semibold)]
                let sz = (tag as NSString).size(withAttributes: attrs)
                let at = CGPoint(x: r.maxX - sz.width - 6, y: y)
                ctx.setFillColor(UIColor.white.withAlphaComponent(0.85).cgColor)
                ctx.fill(CGRect(x: at.x - 3, y: y - sz.height / 2 - 1, width: sz.width + 6, height: sz.height + 2))
                text(tag, at: at, size: 9, weight: .semibold, color: accent, anchor: .left)
            }
            let wy = r.maxY + 14
            line(ctx, CGPoint(x: r.minX, y: wy), CGPoint(x: r.maxX, y: wy), width: 0.6, color: ink)
            text(units.ftIn(f.width), at: CGPoint(x: r.midX, y: wy + 9), size: 9, weight: .medium)
            let hx = r.minX - 14
            line(ctx, CGPoint(x: hx, y: r.minY), CGPoint(x: hx, y: r.maxY), width: 0.6, color: ink)
            text(units.ftIn(f.height), at: CGPoint(x: hx - 9, y: r.midY), size: 9, weight: .medium, angle: -.pi / 2)
        } else if !photos.isEmpty {
            photoGrid(photos, in: left, columns: photos.count > 2 ? 2 : 1)
        } else {
            text("No photo of this spot: take one with Photo next time, or see the wall pages.",
                 at: CGPoint(x: left.minX, y: left.minY + 10), size: 9, color: faint, anchor: .left)
        }

        // Right: the Scan / Tape table. Scan is the estimate; Tape is a box to fill in (or the entered value).
        var y: CGFloat = left.minY
        text("SCAN / TAPE", at: CGPoint(x: tx, y: y), size: 8, weight: .semibold, color: gold, anchor: .topLeft)
        y += 16
        text("Scan", at: CGPoint(x: tx + 96, y: y + 5), size: 8, weight: .semibold, color: faint, anchor: .left)
        text("Tape", at: CGPoint(x: tx + 160, y: y + 5), size: 8, weight: .semibold, color: faint, anchor: .left)
        y += 13
        line(ctx, CGPoint(x: tx, y: y), CGPoint(x: tx + tableW, y: y), width: 0.6, color: gold, cap: .butt)
        y += 3
        let rowH: CGFloat = 24
        func row(_ what: String, _ estimate: Float, field: String, color: UIColor = ink) {
            let cy = y + rowH / 2
            text(what, at: CGPoint(x: tx + 4, y: cy), size: 10, color: color, anchor: .left)
            text(units.ftIn(estimate), at: CGPoint(x: tx + 96, y: cy), size: 10, weight: .medium, color: color, anchor: .left)
            let tapeBox = CGRect(x: tx + 160, y: y + 3, width: tableW - 160, height: rowH - 6)
            ctx.setStrokeColor(faint.cgColor)
            ctx.setLineWidth(0.6)
            ctx.stroke(tapeBox)
            if let tape = measured.confirmed["\(key)|\(field)"] {
                text("✓ \(units.ftIn(tape))", at: CGPoint(x: tapeBox.minX + 6, y: cy), size: 10, weight: .semibold,
                     color: green, anchor: .left)
            }
            y += rowH
        }
        row("Width", size.x, field: "width")
        row("Depth", size.z, field: "depth")
        row("Height", size.y, field: "height")
        if openings.count > 1 {
            y += 4
            for (k, o) in openings.enumerated() {
                row("Opening \(k + 1)\(k == 0 ? " (top)" : "")", o.top - o.bottom, field: "opening \(k + 1)", color: accent)
            }
        }

        // Then what goes here, with quantities and a subtotal.
        y += 16
        text("PRODUCTS", at: CGPoint(x: tx, y: y), size: 8, weight: .semibold, color: gold, anchor: .topLeft)
        y += 18
        if products.isEmpty {
            text("None yet (Products, on the scan).", at: CGPoint(x: tx, y: y), size: 9, color: faint, anchor: .left)
            y += 16
        } else {
            // Rows run down the page; when they reach the footer the list continues on a new page
            // under the spot's name, so nothing runs off the page.
            let bottom: CGFloat = page.height - margin - 40
            var limit: CGFloat = bottom - (photos.isEmpty || front == nil ? 0 : 110)
            func continuePage() {
                begin(pdf, pager, page)
                text(name.uppercased(), at: CGPoint(x: margin, y: margin), size: 8, weight: .semibold, color: gold, anchor: .topLeft)
                text("\(label) (continued)", at: CGPoint(x: margin, y: margin + 13), size: 20, anchor: .topLeft, serif: true)
                line(pdf.cgContext, CGPoint(x: margin, y: margin + 46), CGPoint(x: margin + 40, y: margin + 46), width: 1.5,
                     color: gold, cap: .butt)
                y = margin + 76
                text("PRODUCTS", at: CGPoint(x: tx, y: y), size: 8, weight: .semibold, color: gold, anchor: .topLeft)
                y += 18
                limit = bottom
            }
            for p in products {
                if y + 15 > limit { continuePage() }
                textBox("\(p.qty) × \(p.product)", in: CGRect(x: tx, y: y - 7, width: tableW - 62, height: 14), size: 9)
                if let price = p.price {
                    text(money(price * Double(p.qty)), at: CGPoint(x: tx + tableW, y: y), size: 9, anchor: .right)
                }
                y += 15
            }
            if y + 30 > limit { continuePage() }
            line(pdf.cgContext, CGPoint(x: tx, y: y - 4), CGPoint(x: tx + tableW, y: y - 4), width: 0.6, color: gold, cap: .butt)
            y += 6
            let items: Int = products.reduce(0) { $0 + $1.qty }
            text("Subtotal  (\(items) item\(items == 1 ? "" : "s"))", at: CGPoint(x: tx, y: y), size: 9.5,
                 weight: .semibold, anchor: .left)
            text(money(subtotal(products)), at: CGPoint(x: tx + tableW, y: y), size: 9.5, weight: .semibold, anchor: .right)
            y += 18
        }

        // And its photos, under the products, when the front took the left side.
        if front != nil, !photos.isEmpty {
            let box = CGRect(x: tx, y: y + 8, width: tableW, height: page.height - margin - 30 - y - 8)
            if box.height > 60 { photoGrid(photos, in: box, columns: 2) }
        }
        let note: String = (openings.isEmpty ? "" : "Openings are between shelf edges as seen from the front; take off shelf thickness. ")
            + "Check critical dimensions with a tape before ordering product."
        text(note, at: CGPoint(x: margin, y: page.height - margin - 6), size: 7, color: faint, anchor: .left)
    }

    /// Photos in a grid, each captioned with its pin number.
    private static func photoGrid(_ photos: [(Int, URL)], in box: CGRect, columns: Int) {
        let gutter: CGFloat = 8, caption: CGFloat = 12
        let rows = Int(ceil(Double(photos.count) / Double(columns)))
        let cw = (box.width - gutter * CGFloat(columns - 1)) / CGFloat(columns)
        let ch = Swift.min(cw * 1.4, (box.height - gutter * CGFloat(rows - 1)) / CGFloat(rows))
        guard ch > caption + 20 else { return }
        for (n, (index, url)) in photos.enumerated() {
            let col = CGFloat(n % columns), row = CGFloat(n / columns)
            let cell = CGRect(x: box.minX + col * (cw + gutter), y: box.minY + row * (ch + gutter), width: cw, height: ch - caption)
            guard cell.maxY <= box.maxY else { break }
            if let image = UIImage(contentsOfFile: url.path), image.size.width > 0 {
                let k = Swift.min(cell.width / image.size.width, cell.height / image.size.height)
                let sz = CGSize(width: image.size.width * k, height: image.size.height * k)
                image.draw(in: CGRect(x: cell.minX, y: cell.minY, width: sz.width, height: sz.height))
            }
            text("P\(index + 1)", at: CGPoint(x: cell.minX, y: cell.maxY + caption / 2), size: 8, color: photoColor, anchor: .left)
        }
    }

    /// One line of text cut to fit its box.
    private static func textBox(_ s: String, in rect: CGRect, size: CGFloat, color: UIColor = ink) {
        let style = NSMutableParagraphStyle()
        style.lineBreakMode = .byTruncatingTail
        (s as NSString).draw(in: rect, withAttributes: [.font: UIFont.systemFont(ofSize: size), .foregroundColor: color,
                                                        .paragraphStyle: style])
    }

    // MARK: elevation pages

    /// One wall per page: the projected photo to scale, its width and height, and the
    /// doors, windows and objects on or against it, labelled as on the plan.
    private static func drawElevation(_ e: Elevation, image url: URL, room: CapturedRoom, units: Units,
                                      name: String, names: [String: String], products: [ProductLine] = [],
                                      photos: [(Int, URL)] = [], page: CGRect, pdf: UIGraphicsPDFRendererContext,
                                      pager: Pager) {
        guard let image = UIImage(contentsOfFile: url.path) else { return }
        let wall = room.walls[e.wall]
        let f = WallFrame(wall, flipped: e.flipped)
        // Every page is the document's own size: UIKit lays pages out for the renderer's bounds, so a
        // page of another size gets cut off.
        begin(pdf, pager, page)
        let ctx = pdf.cgContext
        text("\(name): \(shown("Wall W\(e.wall + 1)", names).replacingOccurrences(of: "W\(e.wall + 1) ", with: "Wall W\(e.wall + 1) · "))", at: CGPoint(x: margin, y: margin), size: 16,
             anchor: .topLeft, serif: true)
        text("\(units.length(f.width)) wide × \(units.length(f.height)) high, seen from inside the room",
             at: CGPoint(x: margin, y: margin + 22), size: 10, color: faint, anchor: .topLeft)

        // Leave a strip at the bottom for this wall's photos and products, when it has any.
        let strip: CGFloat = (products.isEmpty && photos.isEmpty) ? 0 : 120
        let cell = CGRect(x: margin + 30, y: margin + 50, width: page.width - 2 * margin - 40,
                          height: page.height - 2 * margin - 50 - 56 - strip)
        if strip > 0 {
            let top = page.height - margin - 20 - strip
            let photoBox = CGRect(x: margin, y: top, width: products.isEmpty ? page.width - 2 * margin : (page.width - 2 * margin) * 0.55,
                                  height: strip - 10)
            if !photos.isEmpty { photoGrid(Array(photos.prefix(6)), in: photoBox, columns: Swift.min(6, Swift.max(1, photos.count))) }
            if !products.isEmpty {
                let px = photos.isEmpty ? margin : photoBox.maxX + 16
                var py = top + 6
                text("Products on this wall", at: CGPoint(x: px, y: py), size: 10, weight: .semibold, anchor: .left)
                py += 15
                for p in products.prefix(6) {
                    textBox("\(p.qty) × \(p.product)", in: CGRect(x: px, y: py - 7, width: page.width - margin - px, height: 14), size: 9)
                    py += 14
                }
                if products.count > 6 {
                    text("+ \(products.count - 6) more on the product list", at: CGPoint(x: px, y: py), size: 8, color: faint, anchor: .left)
                }
            }
        }
        let s = Swift.min(cell.width / CGFloat(f.width), cell.height / CGFloat(f.height))  // points per metre
        let r = CGRect(x: cell.minX, y: cell.minY, width: CGFloat(f.width) * s, height: CGFloat(f.height) * s)
        image.draw(in: r)
        ctx.setStrokeColor(ink.cgColor)
        ctx.setLineWidth(1)
        ctx.stroke(r)
        func box(u0: Float, u1: Float, v0: Float, v1: Float) -> CGRect {
            let x0 = r.minX + CGFloat(Swift.max(0, u0)) * s, x1 = r.minX + CGFloat(Swift.min(f.width, u1)) * s
            let y0 = r.maxY - CGFloat(Swift.min(f.height, v1)) * s, y1 = r.maxY - CGFloat(Swift.max(0, v0)) * s
            return CGRect(x: x0, y: y0, width: Swift.max(0, x1 - x0), height: Swift.max(0, y1 - y0))
        }
        func outline(_ rect: CGRect, _ color: UIColor, _ label: String, dashed: Bool = false) {
            guard rect.width > 1, rect.height > 1 else { return }
            ctx.saveGState()
            ctx.setStrokeColor(color.cgColor)
            ctx.setLineWidth(1.4)
            if dashed { ctx.setLineDash(phase: 0, lengths: [4, 3]) }
            ctx.stroke(rect)
            ctx.restoreGState()
            let at = CGPoint(x: rect.minX + 3, y: rect.minY + 3)
            let attrs: [NSAttributedString.Key: Any] = [.font: UIFont.systemFont(ofSize: 8, weight: .semibold)]
            let sz = (label as NSString).size(withAttributes: attrs)
            ctx.setFillColor(UIColor.white.withAlphaComponent(0.8).cgColor)
            ctx.fill(CGRect(x: at.x - 1, y: at.y - 1, width: sz.width + 2, height: sz.height + 2))
            text(label, at: at, size: 8, weight: .semibold, color: color, anchor: .topLeft)
        }

        // Doors, windows and openings in this wall: within 30 cm of its plane, along its length.
        func onWall(_ o: CapturedRoom.Surface) -> CGRect? {
            let l = f.local(simd_make_float3(o.transform.columns.3))
            guard abs(l.depth) < 0.3, l.u > -0.1, l.u < f.width + 0.1 else { return nil }
            return box(u0: l.u - o.dimensions.x / 2, u1: l.u + o.dimensions.x / 2,
                       v0: l.v - o.dimensions.y / 2, v1: l.v + o.dimensions.y / 2)
        }
        for (i, d) in room.doors.enumerated() {
            if let b = onWall(d) { outline(b, doorColor, "D\(i + 1) \(units.length(d.dimensions.x))") }
        }
        for (i, w) in room.windows.enumerated() {
            if let b = onWall(w) { outline(b, windowColor, "Win\(i + 1) \(units.length(w.dimensions.x))") }
        }
        for o in room.openings {
            if let b = onWall(o) { outline(b, faint, "Opening") }
        }
        // Objects standing against it: footprint within 40 cm of the wall, overlapping its length.
        for (i, o) in room.objects.enumerated() {
            let t = o.transform
            let c = simd_make_float3(t.columns.3)
            let ax = simd_make_float3(t.columns.0) * (o.dimensions.x / 2)
            let az = simd_make_float3(t.columns.2) * (o.dimensions.z / 2)
            let corners = [c - ax - az, c + ax - az, c + ax + az, c - ax + az].map { f.local($0) }
            let us = corners.map { $0.u }, depths = corners.map { $0.depth }
            guard let near = depths.min(), near < 0.4, near > -0.3,
                  let u0 = us.min(), let u1 = us.max(), u1 > 0, u0 < f.width else { continue }
            let v0 = c.y - o.dimensions.y / 2 - f.bottom
            outline(box(u0: u0, u1: u1, v0: v0, v1: v0 + o.dimensions.y), faint,
                    shown("\(i + 1) \(Plan.label(o.category))", names), dashed: true)
        }

        // Width under, height to the left.
        let wy = r.maxY + 14
        line(ctx, CGPoint(x: r.minX, y: wy), CGPoint(x: r.maxX, y: wy), width: 0.6, color: ink)
        for x in [r.minX, r.maxX] { line(ctx, CGPoint(x: x - 3, y: wy + 3), CGPoint(x: x + 3, y: wy - 3), width: 0.9, color: ink) }
        text(units.length(f.width), at: CGPoint(x: r.midX, y: wy + 9), size: 9, weight: .medium)
        let hx = r.minX - 14
        line(ctx, CGPoint(x: hx, y: r.minY), CGPoint(x: hx, y: r.maxY), width: 0.6, color: ink)
        for y in [r.minY, r.maxY] { line(ctx, CGPoint(x: hx - 3, y: y + 3), CGPoint(x: hx + 3, y: y - 3), width: 0.9, color: ink) }
        text(units.length(f.height), at: CGPoint(x: hx - 9, y: r.midY), size: 9, weight: .medium, angle: -.pi / 2)

        text("Photo projected onto the wall from frames kept while scanning: flat things are to scale, "
             + "anything standing out from the wall looks stretched. Gray: no frame saw it.",
             at: CGPoint(x: margin, y: page.height - margin - 6), size: 7, color: faint, anchor: .left)
    }

    // MARK: products page

    /// What went where: each location as on the plan, its products with quantities and prices, a
    /// subtotal per location and the room's total.
    private static func drawProducts(_ lines: [ProductLine], name: String, names: [String: String], page: CGRect,
                                     pdf: UIGraphicsPDFRendererContext, pager: Pager) {
        guard !lines.isEmpty else { return }
        struct Row { var kind: Int; var left: String; var unit: String; var right: String }  // kind: 0 heading, 1 item, 2 subtotal, 3 total
        var order: [String] = []
        for l in lines where !order.contains(l.location) { order.append(l.location) }
        var rows: [Row] = []
        for loc in order {
            let here: [ProductLine] = lines.filter { $0.location == loc }
            rows.append(Row(kind: 0, left: shown(loc, names), unit: "", right: ""))
            for l in here {
                let unit: String = l.price.map { "@ " + money($0) } ?? ""
                let right: String = l.price.map { money($0 * Double(l.qty)) } ?? ""
                rows.append(Row(kind: 1, left: "\(l.qty) × \(l.product)", unit: unit, right: right))
            }
            rows.append(Row(kind: 2, left: "Subtotal", unit: "", right: money(subtotal(here))))
        }
        rows.append(Row(kind: 3, left: "Room total", unit: "", right: money(subtotal(lines))))
        let rowH: CGFloat = 16
        let xr: CGFloat = page.width - margin
        var y: CGFloat = page.height
        for row in rows {
            let need: CGFloat = row.kind == 0 ? rowH * 2.5 : (row.kind == 3 ? rowH * 2 : rowH)
            if y + need > page.height - margin {
                begin(pdf, pager, page)
                text("\(name): products by location", at: CGPoint(x: margin, y: margin), size: 16, anchor: .topLeft,
                     serif: true)
                y = margin + 38
            }
            let cy = y + rowH / 2
            switch row.kind {
            case 0:
                y += 6
                text(row.left, at: CGPoint(x: margin, y: y + rowH / 2), size: 11, weight: .semibold, anchor: .left, serif: true)
                line(pdf.cgContext, CGPoint(x: margin, y: y + rowH), CGPoint(x: xr, y: y + rowH), width: 0.5, color: gold, cap: .butt)
                y += rowH + 2
            case 1:
                textBox(row.left, in: CGRect(x: margin + 14, y: cy - 7, width: xr - 150 - (margin + 14), height: 14), size: 9)
                text(row.unit, at: CGPoint(x: xr - 70, y: cy), size: 8.5, color: faint, anchor: .right)
                text(row.right, at: CGPoint(x: xr, y: cy), size: 9, anchor: .right)
                y += rowH
            case 2:
                text(row.left, at: CGPoint(x: margin + 14, y: cy), size: 9, weight: .semibold, color: gold, anchor: .left)
                text(row.right, at: CGPoint(x: xr, y: cy), size: 9, weight: .semibold, anchor: .right)
                y += rowH + 4
            default:
                y += 4
                line(pdf.cgContext, CGPoint(x: margin, y: y), CGPoint(x: xr, y: y), width: 0.8, color: gold, cap: .butt)
                text(row.left, at: CGPoint(x: margin, y: y + rowH / 2 + 4), size: 11, weight: .semibold, anchor: .left, serif: true)
                text(row.right, at: CGPoint(x: xr, y: y + rowH / 2 + 4), size: 11, weight: .semibold, anchor: .right)
                y += rowH + 4
            }
        }
    }

    // MARK: photo pages

    /// Six to a page (three across on landscape pages, two on portrait), each captioned with its pin
    /// number and what it faces.
    private static func drawPhotos(_ plan: Plan, files: [URL], name: String, page: CGRect,
                                   pdf: UIGraphicsPDFRendererContext, pager: Pager) {
        guard !files.isEmpty else { return }
        let cols = page.width > page.height ? 3 : 2, rows = page.width > page.height ? 2 : 3
        let perPage = cols * rows
        let top = margin + 34, gutter: CGFloat = 16, caption: CGFloat = 18
        let cellW = (page.width - 2 * margin - gutter * CGFloat(cols - 1)) / CGFloat(cols)
        let cellH = (page.height - top - margin - 8 - gutter * CGFloat(rows - 1)) / CGFloat(rows)
        for (i, url) in files.enumerated() {
            if i % perPage == 0 {
                begin(pdf, pager, page)
                text("\(name): photos", at: CGPoint(x: margin, y: margin), size: 16, anchor: .topLeft, serif: true)
            }
            let col = CGFloat(i % cols), row = CGFloat((i % perPage) / cols)
            let cell = CGRect(x: margin + col * (cellW + gutter), y: top + row * (cellH + gutter),
                              width: cellW, height: cellH - caption)
            if let image = UIImage(contentsOfFile: url.path), image.size.width > 0, image.size.height > 0 {
                let k = min(cell.width / image.size.width, cell.height / image.size.height)
                let sz = CGSize(width: image.size.width * k, height: image.size.height * k)
                image.draw(in: CGRect(x: cell.midX - sz.width / 2, y: cell.minY, width: sz.width, height: sz.height))
            }
            var words = ["P\(i + 1)"]
            if i < plan.pins.count, let subject = plan.pins[i].subject { words.append(shown(plan.describe(subject), plan.names)) }
            if i < plan.pins.count { words.append(plan.pins[i].date.formatted(date: .omitted, time: .shortened)) }
            text(words.joined(separator: "  ·  "), at: CGPoint(x: cell.minX, y: cell.maxY + caption / 2),
                 size: 9, color: photoColor, anchor: .left)
        }
    }

    // MARK: drawing helpers

    private enum Anchor { case center, left, topLeft, right }

    /// Georgia stands in for the brand serif in headings; everything else is the system sans.
    private static func font(_ size: CGFloat, _ weight: UIFont.Weight, serif: Bool) -> UIFont {
        if serif {
            let bold: Bool = weight.rawValue >= UIFont.Weight.semibold.rawValue
            if let f = UIFont(name: bold ? "Georgia-Bold" : "Georgia", size: size) { return f }
        }
        return UIFont.systemFont(ofSize: size, weight: weight)
    }

    private static func text(_ s: String, at p: CGPoint, size: CGFloat, weight: UIFont.Weight = .regular,
                             color: UIColor = ink, angle: CGFloat = 0, anchor: Anchor = .center, serif: Bool = false) {
        guard let ctx = UIGraphicsGetCurrentContext() else { return }
        let attrs: [NSAttributedString.Key: Any] = [.font: font(size, weight, serif: serif),
                                                    .foregroundColor: color]
        let str = s as NSString
        let sz = str.size(withAttributes: attrs)
        let origin: CGPoint
        switch anchor {
        case .center: origin = CGPoint(x: -sz.width / 2, y: -sz.height / 2)
        case .left: origin = CGPoint(x: 0, y: -sz.height / 2)
        case .right: origin = CGPoint(x: -sz.width, y: -sz.height / 2)
        case .topLeft: origin = .zero
        }
        ctx.saveGState()
        ctx.translateBy(x: p.x, y: p.y)
        ctx.rotate(by: angle)
        str.draw(at: origin, withAttributes: attrs)
        ctx.restoreGState()
    }

    private static func line(_ ctx: CGContext, _ a: CGPoint, _ b: CGPoint, width: CGFloat, color: UIColor,
                             cap: CGLineCap = .round) {
        ctx.beginPath()
        ctx.move(to: a)
        ctx.addLine(to: b)
        ctx.setLineWidth(width)
        ctx.setLineCap(cap)
        ctx.setStrokeColor(color.cgColor)
        ctx.strokePath()
    }

    /// The angle of a direction on the page, turned so text along it never reads upside down.
    private static func upright(_ d: CGPoint) -> CGFloat {
        var a = atan2(d.y, d.x)
        if a > .pi / 2 { a -= .pi }
        if a <= -.pi / 2 { a += .pi }
        return a
    }

    private static func unit(_ p: CGPoint) -> CGPoint {
        let l = (p.x * p.x + p.y * p.y).squareRoot()
        return l > 0 ? CGPoint(x: p.x / l, y: p.y / l) : CGPoint(x: 1, y: 0)
    }

    private static func cg(_ v: SIMD2<Float>) -> CGPoint { CGPoint(x: CGFloat(v.x), y: CGFloat(v.y)) }
}

private func + (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x + b.x, y: a.y + b.y) }
private func - (a: CGPoint, b: CGPoint) -> CGPoint { CGPoint(x: a.x - b.x, y: a.y - b.y) }
private func * (a: CGPoint, k: CGFloat) -> CGPoint { CGPoint(x: a.x * k, y: a.y * k) }

// MARK: page bookkeeping

/// Counts a document's pages so each can carry its number in the footer.
private final class Pager {
    let room: String
    var number: Int = 0
    init(room: String) { self.room = room }
}

/// One line of the summary page: a spot (or other location) with what goes in it.
private struct SpotSummary {
    var label: String
    var size: String
    var qty: Int
    var subtotal: Double
}

// MARK: units

private struct Units {
    let imperial: Bool

    /// To the nearest inch, or centimetre: about what the scanner can tell.
    func length(_ m: Float) -> String {
        if imperial {
            let inches = Int((Double(m) / 0.0254).rounded())
            let ft = inches / 12, inch = inches % 12
            if ft == 0 { return "\(inch)\"" }
            return inch == 0 ? "\(ft)' 0\"" : "\(ft)' \(inch)\""
        }
        return m < 1 ? "\(Int((m * 100).rounded())) cm" : String(format: "%.2f m", m)
    }

    /// To the nearest half inch (or centimetre), for shelf estimates.
    func fine(_ m: Float) -> String {
        if imperial {
            let halves = Int((Double(m) / 0.0254 * 2).rounded())
            let whole = halves / 2, half = halves % 2 == 1 ? "½" : ""
            if whole >= 36 { return "\(whole / 12)' \(whole % 12)\(half)\"" }
            return "\(whole)\(half)\""
        }
        return "\(Int((m * 100).rounded())) cm"
    }

    /// Feet and inches to the half inch ("2' 3½\""), or centimetres: for openings and tape boxes.
    func ftIn(_ m: Float) -> String {
        if imperial {
            let halves = Int((Double(m) / 0.0254 * 2).rounded())
            let whole = halves / 2, half = halves % 2 == 1 ? "½" : ""
            if whole >= 12 { return "\(whole / 12)' \(whole % 12)\(half)\"" }
            return "\(whole)\(half)\""
        }
        return "\(Int((m * 100).rounded())) cm"
    }

    func area(_ m2: Float) -> String {
        imperial ? "\(Int((m2 * 10.7639).rounded())) sq ft" : String(format: "%.1f m²", m2)
    }

    /// The longest round length that fits in `maxMetres`, for the scale bar.
    func scaleStep(maxMetres: Float) -> (metres: Float, label: String) {
        if imperial {
            let feet: [Float] = [1, 2, 5, 10, 20, 50]
            let f = feet.last { $0 * 0.3048 <= maxMetres } ?? 1
            return (f * 0.3048, "\(Int(f)) ft")
        }
        let metres: [Float] = [0.5, 1, 2, 5, 10, 20]
        let m = metres.last { $0 <= maxMetres } ?? 0.5
        return (m, m < 1 ? "50 cm" : "\(Int(m)) m")
    }
}

// MARK: geometry

/// The room seen from above, in metres, turned so the longest wall runs across the page.
/// Page x is ARKit x and page y is ARKit z (both point the same way as on paper: no mirroring).
private struct Plan {
    struct Wall { var a, b, out: SIMD2<Float>; var length, height: Float; var interior = false }
    struct Opening { var a, b, out: SIMD2<Float>; var width, height, sill: Float }
    struct Item { var corners: [SIMD2<Float>]; var center: SIMD2<Float>; var name: String
                  var width, depth, height: Float }
    enum Subject: Equatable { case item(Int), wall(Int) }
    struct Pin { var at, facing: SIMD2<Float>; var date: Date; var subject: Subject? }

    var walls: [Wall] = []
    var doors: [Opening] = []
    var windows: [Opening] = []
    var openings: [Opening] = []
    var items: [Item] = []
    var floors: [[SIMD2<Float>]] = []
    var pins: [Pin] = []
    var names: [String: String] = [:]  // spot label ("3 Storage", "Wall W2") -> the organizer's name for it
    var area: Float?
    var ceiling: Float?
    var angle: Float = 0
    var lo = SIMD2<Float>(0, 0)
    var hi = SIMD2<Float>(0, 0)
    var size: SIMD2<Float> { hi - lo }

    /// `angle`: how far to turn the room (radians); by default so its longest wall runs across.
    /// Rooms of one home share the first room's, so they fit together.
    init(_ room: CapturedRoom, photos: [ScanPhoto] = [], angle fixed: Float? = nil) {
        var angle: Float = 0
        if let fixed {
            angle = fixed
        } else if let longest = room.walls.max(by: { $0.dimensions.x < $1.dimensions.x }) {
            let d = Self.dir(longest.transform.columns.0)
            angle = atan2(d.y, d.x)
        }
        self.angle = angle
        let c = cos(-angle), s = sin(-angle)
        func turn(_ p: SIMD2<Float>) -> SIMD2<Float> { SIMD2(c * p.x - s * p.y, s * p.x + c * p.y) }
        func ends(_ t: simd_float4x4, _ length: Float) -> (SIMD2<Float>, SIMD2<Float>) {
            let mid = turn(Self.flat(t.columns.3)), d = turn(Self.dir(t.columns.0))
            return (mid - d * (length / 2), mid + d * (length / 2))
        }

        // Floor outlines (RoomPlan gives their corners in the floor's own frame).
        var area: Float = 0
        for f in room.floors where f.polygonCorners.count > 2 {
            let poly = f.polygonCorners.map { p -> SIMD2<Float> in
                let w = f.transform * SIMD4<Float>(p.x, p.y, p.z, 1)
                return turn(SIMD2(w.x, w.z))
            }
            floors.append(poly)
            area += abs(Self.signedArea(poly))
        }
        self.area = area > 0 ? area : nil

        let floorY = room.walls.map { $0.transform.columns.3.y - $0.dimensions.y / 2 }.min() ?? 0
        let centre: SIMD2<Float> = {
            let mids = room.walls.map { turn(Self.flat($0.transform.columns.3)) }
            return mids.isEmpty ? .zero : mids.reduce(.zero, +) / Float(mids.count)
        }()
        let floorPolys = floors
        // Which side of a wall is outside: off the floor outline if there is one, else away from the middle.
        func outward(_ a: SIMD2<Float>, _ b: SIMD2<Float>) -> SIMD2<Float> {
            let d = b - a, l = simd_length(d)
            var n = l > 1e-6 ? SIMD2(-d.y, d.x) / l : SIMD2<Float>(0, 1)
            let m = (a + b) / 2
            if !floorPolys.isEmpty {
                if floorPolys.contains(where: { Self.inside(m + n * 0.15, $0) }) { n = -n }
            } else if simd_dot(n, m - centre) < 0 {
                n = -n
            }
            return n
        }

        for w in room.walls {
            let (a, b) = ends(w.transform, w.dimensions.x)
            let out = outward(a, b)
            let interior = floorPolys.contains { Self.inside((a + b) / 2 + out * 0.15, $0) }
            walls.append(Wall(a: a, b: b, out: out, length: w.dimensions.x, height: w.dimensions.y, interior: interior))
        }
        ceiling = room.walls.map(\.dimensions.y).max()
        func opening(_ o: CapturedRoom.Surface) -> Opening {
            let (a, b) = ends(o.transform, o.dimensions.x)
            let sill = Swift.max(0, o.transform.columns.3.y - o.dimensions.y / 2 - floorY)
            return Opening(a: a, b: b, out: outward(a, b), width: o.dimensions.x, height: o.dimensions.y, sill: sill)
        }
        doors = room.doors.map(opening)
        windows = room.windows.map(opening)
        openings = room.openings.map(opening)

        for o in room.objects {
            let t = o.transform
            let mid = turn(Self.flat(t.columns.3))
            let hw = turn(Self.dir(t.columns.0)) * (o.dimensions.x / 2)
            let hd = turn(Self.dir(t.columns.2)) * (o.dimensions.z / 2)
            items.append(Item(corners: [mid - hw - hd, mid + hw - hd, mid + hw + hd, mid - hw + hd], center: mid,
                              name: Self.label(o.category), width: o.dimensions.x, depth: o.dimensions.z,
                              height: o.dimensions.y))
        }

        // Photos: where the camera stood and which way it looked (the camera looks down its -z).
        for photo in photos {
            let t = photo.pose
            let at = turn(Self.flat(t.columns.3)), facing = turn(Self.dir(-t.columns.2))
            let seen = subject(from: at, facing: facing)
            pins.append(Pin(at: at, facing: facing, date: photo.date, subject: seen))
        }

        let points = walls.flatMap { [$0.a, $0.b] } + floors.flatMap { $0 } + items.flatMap(\.corners)
            + pins.map(\.at)
        if let first = points.first {
            lo = points.reduce(first) { simd_min($0, $1) }
            hi = points.reduce(first) { simd_max($0, $1) }
        }
    }

    /// What a photo shows: the nearest object roughly straight ahead, else the nearest wall.
    func subject(from at: SIMD2<Float>, facing: SIMD2<Float>) -> Subject? {
        func ahead(_ p: SIMD2<Float>, within degrees: Float) -> Float? {
            let d = p - at, l = simd_length(d)
            guard l > 0.05, simd_dot(d / l, facing) > cos(degrees * .pi / 180) else { return nil }
            return l
        }
        let item = items.indices.compactMap { i in ahead(items[i].center, within: 30).map { (i, $0) } }
            .min { $0.1 < $1.1 }
        if let item { return .item(item.0) }
        let wall = walls.indices.compactMap { i in ahead((walls[i].a + walls[i].b) / 2, within: 40).map { (i, $0) } }
            .min { $0.1 < $1.1 }
        return wall.map { .wall($0.0) }
    }

    func describe(_ s: Subject) -> String {
        switch s {
        case let .item(i): return "\(i + 1) \(items[i].name)"
        case let .wall(i): return "Wall W\(i + 1)"
        }
    }

    static func flat(_ v: simd_float4) -> SIMD2<Float> { SIMD2(v.x, v.z) }

    static func dir(_ v: simd_float4) -> SIMD2<Float> {
        let f = flat(v), l = simd_length(f)
        return l > 1e-6 ? f / l : SIMD2(1, 0)
    }

    static func signedArea(_ p: [SIMD2<Float>]) -> Float {
        var s: Float = 0
        for i in p.indices {
            let a = p[i], b = p[(i + 1) % p.count]
            s += a.x * b.y - b.x * a.y
        }
        return s / 2
    }

    static func inside(_ q: SIMD2<Float>, _ p: [SIMD2<Float>]) -> Bool {
        var yes = false
        var j = p.count - 1
        for i in p.indices {
            let a = p[i], b = p[j]
            if (a.y > q.y) != (b.y > q.y), q.x < (b.x - a.x) * (q.y - a.y) / (b.y - a.y) + a.x { yes.toggle() }
            j = i
        }
        return yes
    }

    /// "washerDryer" -> "Washer dryer".
    static func label(_ c: CapturedRoom.Object.Category) -> String {
        var out = ""
        for ch in String(describing: c) {
            if ch.isUppercase { out += " " + ch.lowercased() } else { out.append(ch) }
        }
        return out.prefix(1).uppercased() + out.dropFirst()
    }
}
