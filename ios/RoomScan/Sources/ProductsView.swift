import SwiftUI
import UIKit
import UniformTypeIdentifiers

/// The organizing products used in one scanned room, by location on the plan, with the way out to
/// the product calculator.
struct ProductsView: View {
    @EnvironmentObject private var library: ScanLibrary
    @EnvironmentObject private var catalog: Catalog
    @Environment(\.dismiss) private var dismiss
    let scan: SavedScan

    @State private var lines: [ProductLine] = []
    @State private var locations: [String] = []
    @State private var adding = false
    @State private var importing = false
    @State private var notice: String?
    @State private var csvURL: URL?
    @State private var names: [String: String] = [:]

    var body: some View {
        NavigationStack {
            List {
                if catalog.products.isEmpty {
                    Section {
                        Button {
                            importing = true
                        } label: {
                            Label("Import the product catalog", systemImage: "square.and.arrow.down")
                        }
                    } footer: {
                        Text("Export the calculator's product tab as CSV (File → Download → .csv) and pick it "
                             + "here. It needs a column headed Product; Unit Price and Store are read too. "
                             + "It stays on this phone. Or tap + and paste a store link to add products one by one.")
                    }
                }
                if lines.isEmpty {
                    Section {
                        Text("No products yet. Tap + to add what went where.").foregroundStyle(.secondary)
                    }
                }
                ForEach(groupedLocations, id: \.self) { loc in
                    Section(FloorPlanPDF.shown(loc, names)) {
                        ForEach(lines.filter { $0.location == loc }) { line in
                            HStack {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(line.product).font(.subheadline)
                                    if isUnpriced(line) {
                                        Label("No catalog price: fix the exact name", systemImage: "exclamationmark.triangle.fill")
                                            .font(.caption)
                                            .foregroundStyle(.orange)
                                    } else if let p = priceTable[line.product] {
                                        Text(money(p * Double(line.qty)))
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                                Spacer()
                                Stepper("\(line.qty)", value: qtyBinding(line.id), in: 1...999)
                                    .fixedSize()
                            }
                        }
                        .onDelete { offsets in
                            let ids = offsets.map { lines.filter { $0.location == loc }[$0].id }
                            lines.removeAll { ids.contains($0.id) }
                            save()
                        }
                        HStack {
                            Text("Subtotal").font(.subheadline.weight(.semibold))
                            Spacer()
                            Text(money(ProductExport.subtotal(lines.filter { $0.location == loc }, prices: priceTable)))
                                .font(.subheadline.weight(.semibold))
                        }
                    }
                }
                if !lines.isEmpty {
                    Section {
                        HStack {
                            Text("Total").font(.headline)
                            Spacer()
                            Text(money(ProductExport.subtotal(lines, prices: priceTable))).font(.headline)
                        }
                        if unpricedCount > 0 {
                            Text("\(unpricedCount) product\(unpricedCount == 1 ? "" : "s") without a catalog price "
                                 + "left out of the totals.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                    }
                }
                if let notice {
                    Section { Text(notice).font(.callout) }
                }
            }
            .navigationTitle("\(scan.name) products")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Done") { dismiss() } }
                ToolbarItemGroup(placement: .primaryAction) {
                    Menu {
                        Button {
                            UIPasteboard.general.string = ProductExport.calculatorRows(lines, room: scan.name, names: names)
                            notice = "Copied \(lines.count) row\(lines.count == 1 ? "" : "s"). In the calculator's "
                                + "Client Product List, click the first empty cell in the Location column and paste: "
                                + "Location, Product and Qty in Home fill in, and the sheet looks up the price."
                        } label: { Label("Copy rows for the calculator", systemImage: "doc.on.clipboard") }
                            .disabled(lines.isEmpty)
                        Button {
                            csvURL = writeCSV()
                        } label: { Label("Share as CSV", systemImage: "tablecells") }
                            .disabled(lines.isEmpty)
                        Button {
                            let fresh = catalog.newProducts
                            UIPasteboard.general.string = catalog.masterListRows(fresh)
                            catalog.markAdded(fresh)
                            notice = "Copied \(fresh.count) new product\(fresh.count == 1 ? "" : "s") for the master "
                                + "product tab (Product, Unit Price, Store, URL): paste at the first empty Product cell, "
                                + "so the calculator can price them."
                        } label: {
                            Label("Copy new products for the master list (\(catalog.newProducts.count))",
                                  systemImage: "list.bullet.rectangle")
                        }
                        .disabled(catalog.newProducts.isEmpty)
                        Button {
                            importing = true
                        } label: {
                            Label(catalog.products.isEmpty ? "Import catalog" : "Replace catalog (\(catalog.products.count))",
                                  systemImage: "square.and.arrow.down")
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    Button {
                        adding = true
                    } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $adding) {
                AddProductView(locations: locations, names: names) { line in
                    lines.append(line)
                    save()
                }
            }
            .sheet(item: $csvURL) { url in ShareSheet(items: [url]) }
            .fileImporter(isPresented: $importing,
                          allowedContentTypes: [.commaSeparatedText, .tabSeparatedText, .plainText]) { result in
                do {
                    let n = try catalog.importFile(try result.get())
                    notice = "Catalog imported: \(n) products."
                } catch {
                    notice = error.localizedDescription
                }
            }
            .onAppear {
                lines = library.products(for: scan)
                locations = library.locations(for: scan)
                names = library.names(for: scan)
            }
        }
    }

    /// Locations in plan order, then any others (a scan re-labelled since), only those in use.
    private var groupedLocations: [String] {
        let used = Set(lines.map(\.location))
        let known = locations.filter(used.contains)
        return known + used.subtracting(known).sorted()
    }

    private func qtyBinding(_ id: UUID) -> Binding<Int> {
        Binding(
            get: { lines.first { $0.id == id }?.qty ?? 1 },
            set: { q in
                if let i = lines.firstIndex(where: { $0.id == id }) {
                    lines[i].qty = q
                    save()
                }
            })
    }

    private func save() { library.setProducts(lines, for: scan) }

    private var priceTable: [String: Double] { catalog.priceTable }

    /// Flagged only once a catalog is loaded; with none, every name would be flagged.
    private func isUnpriced(_ line: ProductLine) -> Bool {
        !catalog.products.isEmpty && priceTable[line.product] == nil
    }

    private var unpricedCount: Int {
        catalog.products.isEmpty ? 0 : lines.filter { priceTable[$0.product] == nil }.count
    }

    private func money(_ v: Double) -> String { String(format: "$%.2f", v) }

    private func writeCSV() -> URL? {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(scan.id)-products.csv")
        let text = ProductExport.calculatorCSV(lines, room: scan.name, names: names, prices: priceTable)
        guard (try? text.write(to: url, atomically: true, encoding: .utf8)) != nil
        else { return nil }
        return url
    }
}

/// Pick a location, find a product in the catalog, set how many.
struct AddProductView: View {
    @EnvironmentObject private var catalog: Catalog
    @Environment(\.dismiss) private var dismiss
    let locations: [String]
    let names: [String: String]
    let add: (ProductLine) -> Void

    @State private var location = ProductLine.wholeRoom
    @State private var search = ""
    @State private var picked: CatalogProduct?
    @State private var qty = 1
    @State private var link = ""
    @State private var reading = false
    @State private var readError: String?
    @State private var draft: CatalogProduct?
    @State private var draftPrice = ""

    var body: some View {
        NavigationStack {
            Form {
                Section("Where") {
                    Picker("Location", selection: $location) {
                        ForEach(locations, id: \.self) { Text(FloorPlanPDF.shown($0, names)).tag($0) }
                    }
                }
                if let picked {
                    Section("Product") {
                        Text(picked.name)
                        if let price = picked.price {
                            Text(price, format: .currency(code: "USD")).foregroundStyle(.secondary)
                        }
                        Stepper("Quantity: \(qty)", value: $qty, in: 1...999)
                        Button("Pick a different product") { self.picked = nil }
                    }
                } else if draft != nil {
                    Section {
                        TextField("Name", text: draftBinding(\.name), axis: .vertical)
                        TextField("Price", text: $draftPrice).keyboardType(.decimalPad)
                        if let store = draft?.store { LabeledContent("Store", value: store) }
                        if let dims = draft?.dimensions { LabeledContent("Size", value: dims) }
                        Button("Use this product") {
                            guard var p = draft else { return }
                            p.name = p.name.trimmingCharacters(in: .whitespacesAndNewlines)
                            p.price = Double(draftPrice.replacingOccurrences(of: "$", with: ""))
                            guard !p.name.isEmpty else { return }
                            catalog.add(p)
                            picked = p
                            draft = nil
                        }
                        Button("Cancel", role: .cancel) { draft = nil }
                    } header: {
                        Text("From the store page")
                    } footer: {
                        Text("Edit the name to match the master list's style if you like: the calculator "
                             + "looks prices up by exact name. New products are marked for adding to the master list.")
                    }
                } else {
                    Section {
                        HStack {
                            TextField("Paste a product link", text: $link)
                                .keyboardType(.URL)
                                .textInputAutocapitalization(.never)
                                .autocorrectionDisabled()
                            Button("Paste") { link = UIPasteboard.general.string ?? link }
                                .buttonStyle(.borderless)
                        }
                        Button {
                            Task { await readLink() }
                        } label: {
                            HStack {
                                Text(reading ? "Reading the page…" : "Read product from link")
                                if reading { Spacer(); ProgressView() }
                            }
                        }
                        .disabled(reading || URL(string: link.trimmingCharacters(in: .whitespaces))?.host == nil)
                        if let readError { Text(readError).font(.caption).foregroundStyle(.red) }
                    } header: {
                        Text("From a store")
                    } footer: {
                        Text("Copy the link from Safari or the Target, Amazon or Container Store app (Share → Copy).")
                    }
                    Section("Product") {
                        ForEach(matches) { p in
                            Button {
                                picked = p
                            } label: {
                                VStack(alignment: .leading) {
                                    Text(p.name).foregroundStyle(.primary)
                                    if let store = p.store { Text(store).font(.caption).foregroundStyle(.secondary) }
                                }
                            }
                        }
                    }
                }
            }
            .searchable(text: $search, prompt: "Search the catalog")
            .navigationTitle("Add product")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add") {
                        guard let picked else { return }
                        add(ProductLine(product: picked.name, store: picked.store, price: picked.price, qty: qty,
                                        location: location))
                        dismiss()
                    }
                    .disabled(picked == nil)
                }
            }
        }
    }

    private func draftBinding(_ key: WritableKeyPath<CatalogProduct, String>) -> Binding<String> {
        Binding(get: { draft?[keyPath: key] ?? "" }, set: { draft?[keyPath: key] = $0 })
    }

    @MainActor private func readLink() async {
        guard let url = URL(string: link.trimmingCharacters(in: .whitespaces)) else { return }
        reading = true
        readError = nil
        defer { reading = false }
        do {
            let found = try await ProductPageReader().read(url)
            draft = CatalogProduct(name: found.name ?? "", price: found.price, store: found.store, url: found.url,
                                   image: found.image, dimensions: found.dimensions, isNew: true)
            draftPrice = found.price.map { String(format: "%.2f", $0) } ?? ""
        } catch {
            readError = error.localizedDescription
        }
    }

    /// Every word typed must appear somewhere in the name or store; at most 100 shown.
    private var matches: [CatalogProduct] {
        let words = search.lowercased().split(separator: " ").map(String.init)
        let hits = words.isEmpty ? catalog.products : catalog.products.filter { p in
            let hay = (p.name + " " + (p.store ?? "")).lowercased()
            return words.allSatisfy { hay.contains($0) }
        }
        return Array(hits.prefix(100))
    }
}

/// UIKit's share sheet, for a file made on demand.
struct ShareSheet: UIViewControllerRepresentable {
    let items: [Any]
    func makeUIViewController(context: Context) -> UIActivityViewController {
        UIActivityViewController(activityItems: items, applicationActivities: nil)
    }
    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

extension URL: Identifiable {
    public var id: String { absoluteString }
}
