import SwiftUI

@main
struct ImageHostApp: App {
    @State private var showSettings = false

    var body: some Scene {
        WindowGroup {
            ContentView()
                .onAppear {
                    // Check if app is configured on launch
                    if !UploadService.shared.isConfigured {
                        showSettings = true
                    }
                }
        }
    }
}
