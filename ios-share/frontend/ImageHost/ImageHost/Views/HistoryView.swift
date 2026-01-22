import SwiftUI

struct HistoryView: View {
    @State private var records: [UploadRecord] = []
    @State private var isLoading = true
    @State private var errorMessage: String?
    @State private var deletingIds: Set<String> = []

    private let dateFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter
    }()

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Loading...")
                } else if let error = errorMessage {
                    ContentUnavailableView {
                        Label("Error", systemImage: "exclamationmark.triangle")
                    } description: {
                        Text(error)
                    } actions: {
                        Button("Retry") {
                            loadHistory()
                        }
                    }
                } else if records.isEmpty {
                    ContentUnavailableView {
                        Label("No Uploads", systemImage: "photo.on.rectangle.angled")
                    } description: {
                        Text("Your upload history will appear here.\n\nShare an image from Photos to get started.")
                    }
                } else {
                    List {
                        ForEach(records) { record in
                            NavigationLink(destination: UploadDetailView(record: record, onDelete: {
                                deleteRecord(record)
                            })) {
                                HistoryRow(record: record, dateFormatter: dateFormatter)
                            }
                            .disabled(deletingIds.contains(record.id))
                            .swipeActions(edge: .trailing, allowsFullSwipe: true) {
                                Button(role: .destructive) {
                                    deleteRecord(record)
                                } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                                .disabled(deletingIds.contains(record.id))
                            }
                        }
                    }
                    .refreshable {
                        loadHistory()
                    }
                }
            }
            .navigationTitle("History")
            .onAppear {
                loadHistory()
            }
        }
    }

    private func loadHistory() {
        isLoading = true
        errorMessage = nil

        do {
            records = try HistoryService.shared.loadAll()
            isLoading = false
        } catch {
            errorMessage = error.localizedDescription
            isLoading = false
        }
    }

    private func deleteRecord(_ record: UploadRecord) {
        deletingIds.insert(record.id)

        Task {
            // Try to delete from server
            do {
                try await UploadService.shared.delete(record: record)
            } catch {
                // Continue with local deletion even if server delete fails
                print("Server delete failed: \(error)")
            }

            // Delete from local history
            do {
                try HistoryService.shared.delete(id: record.id)
                await MainActor.run {
                    records.removeAll { $0.id == record.id }
                    deletingIds.remove(record.id)
                }
            } catch {
                await MainActor.run {
                    deletingIds.remove(record.id)
                }
            }
        }
    }
}

struct HistoryRow: View {
    let record: UploadRecord
    let dateFormatter: DateFormatter

    var body: some View {
        HStack(spacing: 12) {
            // Thumbnail
            if let thumbnailData = record.thumbnailData,
               let uiImage = UIImage(data: thumbnailData) {
                Image(uiImage: uiImage)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .frame(width: 50, height: 50)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                RoundedRectangle(cornerRadius: 8)
                    .fill(Color.gray.opacity(0.2))
                    .frame(width: 50, height: 50)
                    .overlay {
                        Image(systemName: "photo")
                            .foregroundStyle(.gray)
                    }
            }

            VStack(alignment: .leading, spacing: 4) {
                // URL (truncated)
                Text(truncatedURL(record.url))
                    .font(.subheadline)
                    .lineLimit(1)

                // Date
                Text(dateFormatter.string(from: record.createdAt))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 4)
    }

    private func truncatedURL(_ url: String) -> String {
        guard let urlComponents = URLComponents(string: url) else {
            return url
        }

        let host = urlComponents.host ?? ""
        let path = urlComponents.path

        if path.count > 20 {
            return "\(host)/...\(path.suffix(15))"
        }
        return "\(host)\(path)"
    }
}

#Preview {
    HistoryView()
}
