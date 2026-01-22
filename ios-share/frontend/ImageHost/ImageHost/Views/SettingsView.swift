import SwiftUI

struct SettingsView: View {
    @Binding var isConfigured: Bool

    @State private var backendUrl: String = ""
    @State private var uploadToken: String = ""
    @State private var isSaving = false
    @State private var isTesting = false
    @State private var showAlert = false
    @State private var alertTitle = ""
    @State private var alertMessage = ""
    @State private var showClearConfirmation = false

    private let keychainService = KeychainService.shared

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Backend URL", text: $backendUrl)
                        .textContentType(.URL)
                        .keyboardType(.URL)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()

                    SecureField("Upload Token", text: $uploadToken)
                        .textContentType(.password)
                        .autocapitalization(.none)
                        .autocorrectionDisabled()
                } header: {
                    Text("Server Configuration")
                } footer: {
                    Text("Enter your image hosting backend URL (e.g., https://img.example.com) and your upload token.")
                }

                Section {
                    Button(action: saveSettings) {
                        HStack {
                            if isSaving {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("Save Settings")
                        }
                    }
                    .disabled(isSaving || backendUrl.isEmpty || uploadToken.isEmpty)

                    Button(action: testConnection) {
                        HStack {
                            if isTesting {
                                ProgressView()
                                    .padding(.trailing, 8)
                            }
                            Text("Test Connection")
                        }
                    }
                    .disabled(isTesting || !isConfigured)
                }

                Section {
                    Button(role: .destructive) {
                        showClearConfirmation = true
                    } label: {
                        Text("Clear Upload History")
                    }
                    .disabled(!isConfigured)
                } footer: {
                    if isConfigured {
                        Text("Connected to \(backendUrl)")
                            .foregroundStyle(.green)
                    } else {
                        Text("Not configured. Please enter your server details above.")
                            .foregroundStyle(.orange)
                    }
                }
            }
            .navigationTitle("Settings")
            .onAppear(perform: loadSettings)
            .alert(alertTitle, isPresented: $showAlert) {
                Button("OK", role: .cancel) {}
            } message: {
                Text(alertMessage)
            }
            .confirmationDialog(
                "Clear History",
                isPresented: $showClearConfirmation,
                titleVisibility: .visible
            ) {
                Button("Clear All History", role: .destructive) {
                    clearHistory()
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This will remove all upload history from this device. Images on the server will not be affected.")
            }
        }
    }

    private func loadSettings() {
        backendUrl = Config.sharedDefaults?.string(forKey: Config.backendUrlKey) ?? ""
        uploadToken = (try? keychainService.loadUploadToken()) ?? ""
        isConfigured = UploadService.shared.isConfigured
    }

    private func saveSettings() {
        isSaving = true

        // Validate URL format
        var normalizedUrl = backendUrl.trimmingCharacters(in: .whitespacesAndNewlines)
        if normalizedUrl.hasSuffix("/") {
            normalizedUrl = String(normalizedUrl.dropLast())
        }

        guard let url = URL(string: normalizedUrl),
              url.scheme == "https" || url.scheme == "http" else {
            showError(title: "Invalid URL", message: "Please enter a valid URL starting with https:// or http://")
            isSaving = false
            return
        }

        do {
            // Save to UserDefaults
            Config.sharedDefaults?.set(normalizedUrl, forKey: Config.backendUrlKey)

            // Save token to Keychain
            try keychainService.saveUploadToken(uploadToken)

            backendUrl = normalizedUrl
            isConfigured = UploadService.shared.isConfigured

            showError(title: "Settings Saved", message: "Your settings have been saved successfully.")
        } catch {
            showError(title: "Error", message: "Failed to save settings: \(error.localizedDescription)")
        }

        isSaving = false
    }

    private func testConnection() {
        isTesting = true

        Task {
            do {
                try await UploadService.shared.testConnection()
                await MainActor.run {
                    showError(title: "Success", message: "Connection test successful! Your server is configured correctly.")
                    isTesting = false
                }
            } catch {
                await MainActor.run {
                    showError(title: "Connection Failed", message: error.localizedDescription)
                    isTesting = false
                }
            }
        }
    }

    private func clearHistory() {
        do {
            try HistoryService.shared.clear()
            showError(title: "History Cleared", message: "All upload history has been removed.")
        } catch {
            showError(title: "Error", message: "Failed to clear history: \(error.localizedDescription)")
        }
    }

    private func showError(title: String, message: String) {
        alertTitle = title
        alertMessage = message
        showAlert = true
    }
}

#Preview {
    SettingsView(isConfigured: .constant(false))
}
