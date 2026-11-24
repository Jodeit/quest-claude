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
            let price = cell(priceCol).flatMap {
                Double($0.replacingOccurrences(of: "$", with: "").replacingOccurrences(of: ",", with: ""))
            }
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

    static func csv(_ lines: [ProductLine], room: String, names: [String: String] = [:]) -> String {
        func q(_ s: String) -> String { "\"" + s.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let rows = lines.map { l in
            [q(l.calculatorLocation(room: room, names: names)), q(l.product), l.price.map { String(format: "%.2f", $0) } ?? "",
             String(l.qty), q(l.store ?? "")].joined(separator: ",")
        }
        return (["Location,Product,Unit Price,Qty in Home,Store"] + rows).joined(separator: "\n") + "\n"
    }
}
