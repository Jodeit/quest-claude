import SwiftUI

/// Name the spots the scan found: each object and wall, as labelled on the plan. The names go on
/// the plan PDF, the products list and the calculator's Location column.
struct SpotNamesView: View {
    @EnvironmentObject private var library: ScanLibrary
    @Environment(\.dismiss) private var dismiss
    let scan: SavedScan

    @State private var spots: [String] = []
    @State private var names: [String: String] = [:]

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    ForEach(spots, id: \.self) { spot in
                        LabeledContent(spot) {
                            TextField("Name", text: binding(spot))
                                .multilineTextAlignment(.trailing)
                        }
                    }
                } footer: {
                    Text("Labels match the plan: numbered objects, then walls W1, W2…. Give the ones that matter "
                         + "a name, like Coffee station or Snack drawer.")
                }
            }
            .navigationTitle("Name spots in \(scan.name)")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        library.setNames(names, for: scan)
                        dismiss()
                    }
                }
            }
            .onAppear {
                spots = library.locations(for: scan).filter { $0 != ProductLine.wholeRoom }
                names = library.names(for: scan)
            }
        }
    }

    private func binding(_ spot: String) -> Binding<String> {
        Binding(get: { names[spot] ?? "" }, set: { names[spot] = $0 })
    }
}
