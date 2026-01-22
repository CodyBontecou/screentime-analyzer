import SwiftUI

struct ContentView: View {
    @State private var selectedTab = 0
    @State private var isConfigured = false

    var body: some View {
        TabView(selection: $selectedTab) {
            HistoryView()
                .tabItem {
                    Label("History", systemImage: "clock.arrow.circlepath")
                }
                .tag(0)

            SettingsView(isConfigured: $isConfigured)
                .tabItem {
                    Label("Settings", systemImage: "gearshape")
                }
                .tag(1)
        }
        .onAppear {
            checkConfiguration()
        }
        .onChange(of: selectedTab) { _, _ in
            checkConfiguration()
        }
    }

    private func checkConfiguration() {
        isConfigured = UploadService.shared.isConfigured
        // If not configured, switch to settings tab
        if !isConfigured && selectedTab == 0 {
            selectedTab = 1
        }
    }
}

#Preview {
    ContentView()
}
