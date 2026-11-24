import SwiftUI

@main
struct RoomScanApp: App {
    @StateObject private var settings = ServerSettings()
    @StateObject private var library = ScanLibrary()
    @StateObject private var catalog = Catalog()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(settings)
                .environmentObject(library)
                .environmentObject(catalog)
        }
    }
}
