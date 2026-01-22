import Foundation
import UIKit

final class UploadService: NSObject {
    static let shared = UploadService()

    private let keychainService = KeychainService.shared
    private let imageProcessor = ImageProcessor.shared

    // For tracking upload progress
    private var progressHandler: ((Double) -> Void)?
    private var uploadTask: URLSessionUploadTask?

    // Test mode for UI development
    var testMode = false

    private override init() {
        super.init()
    }

    // MARK: - Configuration

    var isConfigured: Bool {
        guard let backendUrl = Config.sharedDefaults?.string(forKey: Config.backendUrlKey),
              !backendUrl.isEmpty,
              let token = try? keychainService.loadUploadToken(),
              !token.isEmpty else {
            return false
        }
        return true
    }

    func getBackendURL() -> String? {
        Config.sharedDefaults?.string(forKey: Config.backendUrlKey)
    }

    // MARK: - Upload

    func upload(
        imageData: Data,
        filename: String,
        progressHandler: ((Double) -> Void)? = nil
    ) async throws -> UploadRecord {
        // Test mode for UI development
        if testMode {
            return try await mockUpload(imageData: imageData, filename: filename, progressHandler: progressHandler)
        }

        self.progressHandler = progressHandler

        // Get configuration
        guard let backendUrl = Config.sharedDefaults?.string(forKey: Config.backendUrlKey),
              !backendUrl.isEmpty else {
            throw ImageHostError.notConfigured
        }

        guard let token = try keychainService.loadUploadToken(),
              !token.isEmpty else {
            throw ImageHostError.notConfigured
        }

        guard let url = URL(string: "\(backendUrl)/upload") else {
            throw ImageHostError.invalidURL
        }

        // Upload original data without resizing
        let processedData = imageData

        // Build multipart request
        let boundary = UUID().uuidString
        var request = URLRequest(url: url)
        request.httpMethod = "POST"
        request.setValue("multipart/form-data; boundary=\(boundary)", forHTTPHeaderField: "Content-Type")
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let body = createMultipartBody(imageData: processedData, filename: filename, boundary: boundary)

        // Perform upload with progress tracking
        let (data, response) = try await uploadWithProgress(request: request, bodyData: body)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageHostError.invalidResponse
        }

        guard httpResponse.statusCode == 200 else {
            let message = String(data: data, encoding: .utf8)
            throw ImageHostError.uploadFailed(statusCode: httpResponse.statusCode, message: message)
        }

        // Parse response
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let id = json["id"] as? String,
              let urlString = json["url"] as? String,
              let deleteUrl = json["deleteUrl"] as? String else {
            throw ImageHostError.invalidResponse
        }

        // Generate thumbnail
        let thumbnailData = imageProcessor.generateThumbnail(from: imageData)

        return UploadRecord(
            id: id,
            url: urlString,
            deleteUrl: deleteUrl,
            thumbnailData: thumbnailData,
            createdAt: Date(),
            originalFilename: filename
        )
    }

    // MARK: - Delete

    func delete(record: UploadRecord) async throws {
        guard let token = try keychainService.loadUploadToken(),
              !token.isEmpty else {
            throw ImageHostError.notConfigured
        }

        guard let url = URL(string: record.deleteUrl) else {
            throw ImageHostError.invalidURL
        }

        var request = URLRequest(url: url)
        request.httpMethod = "DELETE"
        request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

        let (data, response) = try await URLSession.shared.data(for: request)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw ImageHostError.invalidResponse
        }

        guard httpResponse.statusCode == 200 || httpResponse.statusCode == 204 else {
            let message = String(data: data, encoding: .utf8)
            throw ImageHostError.deleteFailed(statusCode: httpResponse.statusCode, message: message)
        }
    }

    // MARK: - Test Connection

    func testConnection() async throws {
        guard let testImageData = imageProcessor.createTestImage() else {
            throw ImageHostError.imageProcessingFailed
        }

        let record = try await upload(imageData: testImageData, filename: "test.png")

        // Try to delete the test image
        try? await delete(record: record)
    }

    // MARK: - Cancel

    func cancelUpload() {
        uploadTask?.cancel()
        uploadTask = nil
    }

    // MARK: - Private Methods

    private func createMultipartBody(imageData: Data, filename: String, boundary: String) -> Data {
        var body = Data()

        // Determine content type based on filename
        let contentType: String
        let lowercasedFilename = filename.lowercased()
        if lowercasedFilename.hasSuffix(".png") {
            contentType = "image/png"
        } else if lowercasedFilename.hasSuffix(".gif") {
            contentType = "image/gif"
        } else if lowercasedFilename.hasSuffix(".webp") {
            contentType = "image/webp"
        } else {
            contentType = "image/jpeg"
        }

        // Add file part
        body.append("--\(boundary)\r\n".data(using: .utf8)!)
        body.append("Content-Disposition: form-data; name=\"file\"; filename=\"\(filename)\"\r\n".data(using: .utf8)!)
        body.append("Content-Type: \(contentType)\r\n\r\n".data(using: .utf8)!)
        body.append(imageData)
        body.append("\r\n".data(using: .utf8)!)

        // End boundary
        body.append("--\(boundary)--\r\n".data(using: .utf8)!)

        return body
    }

    private func uploadWithProgress(request: URLRequest, bodyData: Data) async throws -> (Data, URLResponse) {
        try await withCheckedThrowingContinuation { continuation in
            let session = URLSession(configuration: .default, delegate: self, delegateQueue: nil)
            let task = session.uploadTask(with: request, from: bodyData) { data, response, error in
                if let error = error {
                    continuation.resume(throwing: ImageHostError.networkError(underlying: error))
                    return
                }

                guard let data = data, let response = response else {
                    continuation.resume(throwing: ImageHostError.invalidResponse)
                    return
                }

                continuation.resume(returning: (data, response))
            }

            self.uploadTask = task
            task.resume()
        }
    }

    // MARK: - Mock Upload for Testing

    private func mockUpload(imageData: Data, filename: String, progressHandler: ((Double) -> Void)?) async throws -> UploadRecord {
        // Simulate upload progress
        for progress in stride(from: 0.0, through: 1.0, by: 0.1) {
            try await Task.sleep(nanoseconds: 100_000_000) // 0.1 second
            await MainActor.run {
                progressHandler?(progress)
            }
        }

        let id = UUID().uuidString.prefix(8).lowercased()
        let thumbnailData = imageProcessor.generateThumbnail(from: imageData)

        return UploadRecord(
            id: String(id),
            url: "https://img.example.com/\(id).png",
            deleteUrl: "https://img.example.com/delete/\(id)",
            thumbnailData: thumbnailData,
            createdAt: Date(),
            originalFilename: filename
        )
    }
}

// MARK: - URLSessionTaskDelegate

extension UploadService: URLSessionTaskDelegate {
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didSendBodyData bytesSent: Int64,
        totalBytesSent: Int64,
        totalBytesExpectedToSend: Int64
    ) {
        let progress = Double(totalBytesSent) / Double(totalBytesExpectedToSend)
        DispatchQueue.main.async {
            self.progressHandler?(progress)
        }
    }
}
