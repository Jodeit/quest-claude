import SwiftUI

@main
struct RoomScanApp: App {
    @StateObject private var settings = ServerSettings()
    @StateObject private var library = ScanLibrary()

    var body: some Scene {
        WindowGroup {
            HomeView()
                .environmentObject(settings)
                .environmentObject(library)
        }
    }
}
