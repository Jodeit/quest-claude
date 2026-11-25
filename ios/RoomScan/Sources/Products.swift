import Foundation

/// One product from the organizer's catalog. `name` must stay exactly as the catalog spells it:
/// the product calculator looks prices up by exact name.
struct CatalogProduct: Codable, Hashable, Identifiable {
    var name: String
    var price: Double?
    var store: String?
    var url: String?
    var image: String?
    var dimensions: String?  // as the store words it, e.g. "24 Inches (L), 13.12 Inches (H) x 16.5 Inches (W)"
    var isNew: Bool?         // added on the phone from a store link; not in the master list yet
    var id: String { name }
}

/// A product used in a scanned room: how many, and where (a label from the plan, like
/// "3 Storage" or "Wall W2", or the whole room).
struct ProductLine: Codable, Hashable, Identifiable {
    var id = UUID()
    var product: String
    var store: String?
    var price: Double?
    var qty: Int
    var location: String

    static let wholeRoom = "Whole room"

    /// The calculator's Location column: the room, then the spot in it, by the organizer's name for
    /// it when there is one ("Pantry · Coffee station"), else its plan label ("Pantry · 3 Storage").
    func calculatorLocation(room: String, names: [String: String] = [:]) -> String {
        if let n = names[location]?.trimmingCharacters(in: .whitespaces), !n.isEmpty { return "\(room) · \(n)" }
        return location == Self.wholeRoom ? room : "\(room) · \(location)"
    }
}

/// The catalog, imported once from a CSV (or TSV) export of the calculator's product tab and kept
/// on the phone (Documents/catalog.json). Never bundled with the app: it's the business's data.
final class Catalog: ObservableObject {
    @Published private(set) var products: [CatalogProduct] = []
    private let url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("catalog.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let list = try? JSONDecoder().decode([CatalogProduct].self, from: data) {
            products = list
        }
    }

    enum ImportError: LocalizedError {
        case unreadable, noProductColumn, empty
        var errorDescription: String? {
            switch self {
            case .unreadable: return "Couldn't read that file as text."
            case .noProductColumn: return "No column headed \"Product\" in that file."
            case .empty: return "That file has no products in it."
            }
        }
    }

    /// Replaces the catalog with the products in a CSV/TSV whose header row has a "Product" column
    /// (and optionally a price column and a "Store" column). Returns how many it read.
    @discardableResult
    func importFile(_ file: URL) throws -> Int {
        let scoped = file.startAccessingSecurityScopedResource()
        defer { if scoped { file.stopAccessingSecurityScopedResource() } }
        guard let data = try? Data(contentsOf: file),
              let text = String(data: data, encoding: .utf8) ?? String(data: data, encoding: .windowsCP1252)
        else { throw ImportError.unreadable }
        let rows = Self.parse(text)
        func find(_ row: [String], _ test: (String) -> Bool) -> Int? {
            row.firstIndex { test($0.trimmingCharacters(in: .whitespaces).lowercased()) }
        }
        guard let headerAt = rows.firstIndex(where: { find($0, { $0 == "product" }) != nil }) else {
            throw ImportError.noProductColumn
        }
        let header = rows[headerAt]
        let nameCol = find(header, { $0 == "product" })!
        let priceCol = find(header, { $0.contains("price") })
        let storeCol = find(header, { $0 == "store" })
        var seen = Set<String>()
        var list: [CatalogProduct] = []
        for row in rows[(headerAt + 1)...] where nameCol < row.count {
            let name = row[nameCol].trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, seen.insert(name).inserted else { continue }
            func cell(_ c: Int?) -> String? {
                guard let c, c < row.count else { return nil }
                let v = row[c].trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
            let price: Double? = cell(priceCol).flatMap { ProductExport.parsePrice($0) }
            list.append(CatalogProduct(name: name, price: price, store: cell(storeCol)))
        }
        guard !list.isEmpty else { throw ImportError.empty }
        // Keep products added from links that the new master list doesn't have yet.
        let kept = products.filter { $0.isNew == true && !seen.contains($0.name) }
        products = list + kept
        try persist()
        return list.count
    }

    /// A product read from a store link: replaces one of the same name, else joins the catalog.
    func add(_ p: CatalogProduct) {
        if let i = products.firstIndex(where: { $0.name == p.name }) { products[i] = p } else { products.append(p) }
        try? persist()
    }

    var newProducts: [CatalogProduct] { products.filter { $0.isNew == true } }

    /// The catalog's price for a product name, matched exactly as the calculator does (nil when the
    /// name isn't in the catalog or has no price).
    func price(for name: String) -> Double? {
        for p in products where p.name == name { return p.price }
        return nil
    }

    /// Prices by exact product name, for pricing many lines at once.
    var priceTable: [String: Double] {
        var table: [String: Double] = [:]
        for p in products {
            if let v = p.price { table[p.name] = v }
        }
        return table
    }

    /// Rows for the calculator's master product tab: Product, Unit Price, Store, URL.
    func masterListRows(_ list: [CatalogProduct]) -> String {
        list.map { [$0.name, $0.price.map { String(format: "%.2f", $0) } ?? "", $0.store ?? "", $0.url ?? ""]
            .joined(separator: "\t") }.joined(separator: "\n")
    }

    func markAdded(_ list: [CatalogProduct]) {
        let names = Set(list.map(\.name))
        for i in products.indices where names.contains(products[i].name) { products[i].isNew = nil }
        try? persist()
    }

    private func persist() throws {
        try JSONEncoder().encode(products).write(to: url, options: .atomic)
    }

    /// RFC 4180-style: quoted fields, doubled quotes inside them (product names are full of inch
    /// marks), commas or newlines inside quotes. Tab-separated if the first line has tabs and no commas.
    static func parse(_ text: String) -> [[String]] {
        let firstLine = text.prefix { $0 != "\n" && $0 != "\r\n" && $0 != "\r" }
        let sep: Character = firstLine.contains("\t") && !firstLine.contains(",") ? "\t" : ","
        let chars = Array(text)
        var rows: [[String]] = [], row: [String] = [], field = ""
        var quoted = false, k = 0
        while k < chars.count {
            let c = chars[k]
            if quoted {
                if c == "\"" {
                    if k + 1 < chars.count, chars[k + 1] == "\"" {
                        field.append("\"")
                        k += 1
                    } else {
                        quoted = false
                    }
                } else {
                    field.append(c)
                }
            } else if c == "\"" && field.isEmpty {
                quoted = true
            } else if c == sep {
                row.append(field)
                field = ""
            } else if c == "\n" || c == "\r\n" || c == "\r" {
                row.append(field)
                rows.append(row)
                row = []
                field = ""
            } else {
                field.append(c)
            }
            k += 1
        }
        if !field.isEmpty || !row.isEmpty {
            row.append(field)
            rows.append(row)
        }
        return rows
    }
}

enum ProductExport {
    /// Rows for the calculator's Client Product List, to paste at column A: Location, Product, an
    /// empty Price (the sheet's formula fills it), Qty in Home. Tab-separated, as spreadsheets paste.
    static func calculatorRows(_ lines: [ProductLine], room: String, names: [String: String] = [:]) -> String {
        lines.map { [$0.calculatorLocation(room: room, names: names), $0.product, "", String($0.qty)].joined(separator: "\t") }
            .joined(separator: "\n")
    }

    /// A price typed or exported in either convention: "$1,234.50", "1.234,50", "12,50" (decimal
    /// comma), "1,234" (thousands). nil when it isn't a number.
    static func parsePrice(_ raw: String) -> Double? {
        var allowed: String = ""
        for ch in raw {
            if ch.isNumber || ch == "," || ch == "." || ch == "-" { allowed.append(ch) }
        }
        guard !allowed.isEmpty else { return nil }
        let lastComma: String.Index? = allowed.lastIndex(of: ",")
        let lastDot: String.Index? = allowed.lastIndex(of: ".")
        var cleaned: String = allowed
        if let c = lastComma, let d = lastDot {
            if c > d {
                // "1.234,50": comma is the decimal mark.
                cleaned = allowed.replacingOccurrences(of: ".", with: "").replacingOccurrences(of: ",", with: ".")
            } else {
                cleaned = allowed.replacingOccurrences(of: ",", with: "")
            }
        } else if let c = lastComma {
            let commas: Int = allowed.filter { $0 == "," }.count
            let after: Int = allowed.distance(from: c, to: allowed.endIndex) - 1
            if commas == 1 && after >= 1 && after <= 2 {
                cleaned = allowed.replacingOccurrences(of: ",", with: ".")   // "12,50"
            } else {
                cleaned = allowed.replacingOccurrences(of: ",", with: "")    // "1,234" or "1,234,567"
            }
        } else if lastDot != nil {
            let dots: Int = allowed.filter { $0 == "." }.count
            if dots > 1 { cleaned = allowed.replacingOccurrences(of: ".", with: "") }  // "1.234.567"
        }
        return Double(cleaned)
    }

    /// The one price source for every total (screen, CSV, PDF): the catalog's price for the exact
    /// product name, nil when the name isn't priced.
    static func price(of line: ProductLine, prices: [String: Double]) -> Double? { prices[line.product] }

    /// Lines whose product has no catalog price. With no priced products at all (no catalog loaded)
    /// nothing is flagged, as the product screen does, since every name would be.
    static func unpricedCount(_ lines: [ProductLine], prices: [String: Double]) -> Int {
        if prices.isEmpty { return 0 }
        return lines.filter { prices[$0.product] == nil }.count
    }

    /// The lines with `price` set from the shared price table (nil where unpriced), for drawing.
    static func repriced(_ lines: [ProductLine], prices: [String: Double]) -> [ProductLine] {
        lines.map { l in
            var c = l
            c.price = prices[l.product]
            return c
        }
    }

    /// A cell a spreadsheet would run as a formula starts with = + - @ (or tab/CR): prefix a quote.
    static func neutralised(_ s: String) -> String {
        guard let f = s.unicodeScalars.first else { return s }
        if "=+-@\t\r".unicodeScalars.contains(f) { return "'" + s }
        return s
    }

    /// RFC 4180 field: quoted only when it holds a comma, quote, or line break; quotes doubled.
    static func csvField(_ raw: String) -> String {
        let s = neutralised(raw)
        let needs = s.contains(",") || s.contains("\"") || s.contains("\n") || s.contains("\r")
        guard needs else { return s }
        return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }

    /// The calculator's four columns, exactly: Location, Product, Price, Qty in Home. One row per
    /// product per location, sorted by location (then product). Price is the catalog's price for the
    /// exact product name, empty when the name isn't priced. CRLF line endings per RFC 4180.
    static func calculatorCSV(_ lines: [ProductLine], room: String, names: [String: String] = [:],
                              prices: [String: Double]) -> String {
        var rows: [(String, String, String, Int)] = []
        for l in lines {
            let loc = l.calculatorLocation(room: room, names: names)
            let price = prices[l.product].map { String(format: "%.2f", $0) } ?? ""
            rows.append((loc, l.product, price, l.qty))
        }
        rows.sort { a, b in
            if a.0 != b.0 { return a.0.localizedStandardCompare(b.0) == .orderedAscending }
            return a.1.localizedStandardCompare(b.1) == .orderedAscending
        }
        var out = ["Location,Product,Price,Qty in Home"]
        for r in rows {
            out.append([csvField(r.0), csvField(r.1), r.2, String(r.3)].joined(separator: ","))
        }
        // A UTF-8 byte order mark first, so Excel reads accents and inch marks right.
        return "\u{FEFF}" + out.joined(separator: "\r\n") + "\r\n"
    }

    /// Subtotal of lines with a catalog price (price x qty); unpriced names add nothing.
    static func subtotal(_ lines: [ProductLine], prices: [String: Double]) -> Double {
        var sum = 0.0
        for l in lines {
            if let p = prices[l.product] { sum += p * Double(l.qty) }
        }
        return sum
    }

    static func csv(_ lines: [ProductLine], room: String, names: [String: String] = [:]) -> String {
        func q(_ raw: String) -> String { let s = neutralised(raw); return "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = lines.map { l in
            [q(l.calculatorLocation(room: room, names: names)), q(l.product), l.price.map { String(format: "%.2f", $0) } ?? "",
             String(l.qty), q(l.store ?? "")].joined(separator: ",")
        }
        return (["Location,Product,Unit Price,Qty in Home,Store"] + rows).joined(separator: "\n") + "\n"
    }
}
