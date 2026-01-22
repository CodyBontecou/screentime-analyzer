import SwiftUI

struct UploadDetailView: View {
    let record: UploadRecord
    let onDelete: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var showDeleteConfirmation = false
    @State private var copiedField: CopiedField?
    @State private var isDeleting = false

    private enum CopiedField {
        case url, deleteUrl
    }

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .medium
        return formatter
    }()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                // Thumbnail preview
                Group {
                    if let thumbnailData = record.thumbnailData,
                       let uiImage = UIImage(data: thumbnailData) {
                        Image(uiImage: uiImage)
                            .resizable()
                            .aspectRatio(contentMode: .fit)
                            .frame(maxHeight: 300)
                            .clipShape(RoundedRectangle(cornerRadius: 12))
                            .shadow(radius: 4)
                    } else {
                        RoundedRectangle(cornerRadius: 12)
                            .fill(Color.gray.opacity(0.2))
                            .frame(height: 200)
                            .overlay {
                                VStack {
                                    Image(systemName: "photo")
                                        .font(.largeTitle)
                                    Text("No preview available")
                                        .font(.caption)
                                }
                                .foregroundStyle(.gray)
                            }
                    }
                }
                .padding(.horizontal)

                // URL Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Image URL")
                        .font(.headline)

                    HStack {
                        Text(record.url)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        Spacer()

                        Button {
                            copyToClipboard(record.url)
                            copiedField = .url
                        } label: {
                            Image(systemName: copiedField == .url ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copiedField == .url ? .green : .blue)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal)

                // Delete URL Section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Delete URL")
                        .font(.headline)

                    HStack {
                        Text(record.deleteUrl)
                            .font(.system(.caption, design: .monospaced))
                            .foregroundStyle(.secondary)
                            .lineLimit(2)

                        Spacer()

                        Button {
                            copyToClipboard(record.deleteUrl)
                            copiedField = .deleteUrl
                        } label: {
                            Image(systemName: copiedField == .deleteUrl ? "checkmark" : "doc.on.doc")
                                .foregroundStyle(copiedField == .deleteUrl ? .green : .blue)
                        }
                    }
                    .padding()
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal)

                // Details
                VStack(alignment: .leading, spacing: 8) {
                    Text("Details")
                        .font(.headline)

                    VStack(spacing: 0) {
                        DetailRow(label: "Uploaded", value: dateFormatter.string(from: record.createdAt))
                        Divider()
                        if let filename = record.originalFilename {
                            DetailRow(label: "Original File", value: filename)
                            Divider()
                        }
                        DetailRow(label: "ID", value: record.id)
                    }
                    .background(Color(.systemGray6))
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                }
                .padding(.horizontal)

                // Action buttons
                VStack(spacing: 12) {
                    Button {
                        openInBrowser()
                    } label: {
                        Label("Open in Browser", systemImage: "safari")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)

                    Button(role: .destructive) {
                        showDeleteConfirmation = true
                    } label: {
                        if isDeleting {
                            ProgressView()
                                .frame(maxWidth: .infinity)
                        } else {
                            Label("Delete from Server", systemImage: "trash")
                                .frame(maxWidth: .infinity)
                        }
                    }
                    .buttonStyle(.bordered)
                    .disabled(isDeleting)
                }
                .padding(.horizontal)
                .padding(.bottom, 24)
            }
        }
        .navigationTitle("Upload Details")
        .navigationBarTitleDisplayMode(.inline)
        .confirmationDialog(
            "Delete Image",
            isPresented: $showDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete from Server", role: .destructive) {
                deleteFromServer()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will permanently delete the image from the server. This action cannot be undone.")
        }
        .onChange(of: copiedField) { _, newValue in
            if newValue != nil {
                // Reset after delay
                DispatchQueue.main.asyncAfter(deadline: .now() + 2) {
                    copiedField = nil
                }
            }
        }
    }

    private func copyToClipboard(_ text: String) {
        UIPasteboard.general.string = text
        // Haptic feedback
        let generator = UINotificationFeedbackGenerator()
        generator.notificationOccurred(.success)
    }

    private func openInBrowser() {
        guard let url = URL(string: record.url) else { return }
        UIApplication.shared.open(url)
    }

    private func deleteFromServer() {
        isDeleting = true

        Task {
            do {
                try await UploadService.shared.delete(record: record)
                try HistoryService.shared.delete(id: record.id)
                await MainActor.run {
                    onDelete()
                    dismiss()
                }
            } catch {
                await MainActor.run {
                    isDeleting = false
                    // Could show error alert here
                }
            }
        }
    }
}

struct DetailRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack {
            Text(label)
                .foregroundStyle(.secondary)
            Spacer()
            Text(value)
                .lineLimit(1)
        }
        .padding(.horizontal)
        .padding(.vertical, 10)
    }
}

#Preview {
    NavigationStack {
        UploadDetailView(record: .preview) {}
    }
}
