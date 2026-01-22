import SwiftUI
import UIKit

struct ShareView: View {
    let extensionContext: NSExtensionContext?
    let loadImage: () async throws -> (Data, String)

    @State private var state: ShareState = .loading
    @State private var progress: Double = 0
    @State private var uploadedURL: String = ""
    @State private var errorMessage: String = ""
    @State private var previewImage: UIImage?
    @State private var pendingImageData: Data?
    @State private var pendingFilename: String?
    @State private var fileSizeMB: Double = 0

    // Share extensions have ~120MB memory limit, warn at 80MB to be safe
    private let memorySafetyLimitMB: Double = 80
    private let memoryHardLimitMB: Double = 100

    private enum ShareState {
        case loading
        case uploading
        case success
        case error
        case notConfigured
        case fileTooLarge
    }

    var body: some View {
        ZStack {
            // Semi-transparent background
            Color.black.opacity(0.4)
                .ignoresSafeArea()

            // Card
            VStack(spacing: 20) {
                switch state {
                case .loading:
                    loadingView

                case .uploading:
                    uploadingView

                case .success:
                    successView

                case .error:
                    errorView

                case .notConfigured:
                    notConfiguredView

                case .fileTooLarge:
                    fileTooLargeView
                }
            }
            .padding(24)
            .frame(maxWidth: 320)
            .background(Color(.systemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 20))
            .shadow(radius: 20)
        }
        .onAppear {
            prepareUpload()
        }
    }

    // MARK: - State Views

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.2)
            Text("Preparing...")
                .font(.headline)
        }
        .padding(.vertical, 20)
    }

    private var uploadingView: some View {
        VStack(spacing: 16) {
            // Image preview
            if let image = previewImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 150)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Text("Uploading...")
                .font(.headline)

            // Progress bar
            VStack(spacing: 8) {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)

                Text("\(Int(progress * 100))%")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Button("Cancel") {
                UploadService.shared.cancelUpload()
                dismiss()
            }
            .foregroundStyle(.red)
        }
    }

    private var successView: some View {
        VStack(spacing: 16) {
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.green)

            Text("Copied to clipboard")
                .font(.headline)

            Text(uploadedURL)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
        .onAppear {
            // Auto-dismiss after 1.5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
                dismiss()
            }
        }
    }

    private var errorView: some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text("Upload Failed")
                .font(.headline)

            Text(errorMessage)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 10) {
                Button("Retry") {
                    uploadOriginal()
                }
                .buttonStyle(.borderedProminent)

                if fileSizeMB > 10 {
                    Button("Retry with Resize") {
                        uploadResized()
                    }
                    .buttonStyle(.bordered)
                }

                Button("Done") {
                    dismiss()
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    private var notConfiguredView: some View {
        VStack(spacing: 16) {
            Image(systemName: "gear.badge.xmark")
                .font(.system(size: 50))
                .foregroundStyle(.orange)

            Text("Not Configured")
                .font(.headline)

            Text("Open the ImageHost app to set up your backend URL and token.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            Button("Done") {
                dismiss()
            }
            .buttonStyle(.borderedProminent)
        }
    }

    private var fileTooLargeView: some View {
        VStack(spacing: 16) {
            // Image preview
            if let image = previewImage {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 120)
                    .clipShape(RoundedRectangle(cornerRadius: 12))
            }

            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 40))
                .foregroundStyle(.orange)

            Text("Large File")
                .font(.headline)

            Text(String(format: "This image is %.1f MB. Files over %.0f MB may fail to upload due to memory limits.", fileSizeMB, memorySafetyLimitMB))
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .padding(.horizontal)

            VStack(spacing: 10) {
                Button {
                    uploadResized()
                } label: {
                    Text("Resize & Upload")
                        .frame(maxWidth: .infinity)
                }
                .buttonStyle(.borderedProminent)

                if fileSizeMB < memoryHardLimitMB {
                    Button {
                        uploadOriginal()
                    } label: {
                        Text("Upload Original")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }

                Button("Cancel") {
                    dismiss()
                }
                .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - Actions

    private func prepareUpload() {
        // Check if configured
        guard UploadService.shared.isConfigured else {
            state = .notConfigured
            return
        }

        state = .loading

        Task {
            do {
                // Load image
                let (imageData, filename) = try await loadImage()

                // Store for later use
                await MainActor.run {
                    pendingImageData = imageData
                    pendingFilename = filename
                    fileSizeMB = Double(imageData.count) / (1024 * 1024)

                    // Create preview
                    if let image = UIImage(data: imageData) {
                        previewImage = image
                    }

                    // Check file size
                    if fileSizeMB >= memorySafetyLimitMB {
                        state = .fileTooLarge
                    } else {
                        // File is small enough, proceed with upload
                        performUpload(data: imageData, filename: filename)
                    }
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    state = .error
                }
            }
        }
    }

    private func uploadOriginal() {
        guard let data = pendingImageData, let filename = pendingFilename else { return }
        performUpload(data: data, filename: filename)
    }

    private func uploadResized() {
        guard let data = pendingImageData, let filename = pendingFilename else { return }

        // Resize the image
        if let image = UIImage(data: data),
           let resizedData = ImageProcessor.shared.prepareForUpload(image: image) {
            // Update filename to .jpg since we're converting
            let newFilename = filename.replacingOccurrences(
                of: "\\.[^.]+$",
                with: ".jpg",
                options: .regularExpression
            )
            performUpload(data: resizedData, filename: newFilename)
        } else {
            // Fallback to original if resize fails
            performUpload(data: data, filename: filename)
        }
    }

    private func performUpload(data: Data, filename: String) {
        state = .uploading
        progress = 0

        Task {
            do {
                // Upload
                let record = try await UploadService.shared.upload(
                    imageData: data,
                    filename: filename
                ) { uploadProgress in
                    Task { @MainActor in
                        progress = uploadProgress
                    }
                }

                // Copy URL to clipboard immediately
                await MainActor.run {
                    UIPasteboard.general.string = record.url
                }

                // Play haptic feedback
                let generator = UINotificationFeedbackGenerator()
                generator.notificationOccurred(.success)

                // Save to history
                try? HistoryService.shared.save(record)

                await MainActor.run {
                    uploadedURL = record.url
                    state = .success
                }
            } catch {
                await MainActor.run {
                    errorMessage = error.localizedDescription
                    state = .error
                }
            }
        }
    }

    private func dismiss() {
        extensionContext?.completeRequest(returningItems: nil, completionHandler: nil)
    }
}

#Preview {
    ShareView(
        extensionContext: nil,
        loadImage: {
            // Return mock data for preview
            let image = UIImage(systemName: "photo")!
            return (image.pngData()!, "test.png")
        }
    )
}
