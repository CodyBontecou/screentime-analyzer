import Foundation

enum ImageHostError: LocalizedError {
    case notConfigured
    case invalidURL
    case uploadFailed(statusCode: Int, message: String?)
    case networkError(underlying: Error)
    case invalidResponse
    case keychainError(status: OSStatus)
    case fileSystemError(underlying: Error)
    case imageProcessingFailed
    case deleteFailed(statusCode: Int, message: String?)

    var errorDescription: String? {
        switch self {
        case .notConfigured:
            return "App not configured. Please set up the backend URL and token in settings."
        case .invalidURL:
            return "Invalid backend URL. Please check your settings."
        case .uploadFailed(let statusCode, let message):
            if let message = message {
                return "Upload failed (\(statusCode)): \(message)"
            }
            return "Upload failed with status code \(statusCode)"
        case .networkError(let underlying):
            return "Network error: \(underlying.localizedDescription)"
        case .invalidResponse:
            return "Invalid response from server"
        case .keychainError(let status):
            return "Keychain error: \(status)"
        case .fileSystemError(let underlying):
            return "File system error: \(underlying.localizedDescription)"
        case .imageProcessingFailed:
            return "Failed to process image"
        case .deleteFailed(let statusCode, let message):
            if let message = message {
                return "Delete failed (\(statusCode)): \(message)"
            }
            return "Delete failed with status code \(statusCode)"
        }
    }

    var recoverySuggestion: String? {
        switch self {
        case .notConfigured:
            return "Open the ImageHost app and configure your backend URL and upload token."
        case .invalidURL:
            return "Make sure the URL starts with https:// and is a valid web address."
        case .uploadFailed:
            return "Check your internet connection and try again. If the problem persists, verify your upload token."
        case .networkError:
            return "Check your internet connection and try again."
        case .invalidResponse:
            return "The server returned an unexpected response. Please try again later."
        case .keychainError:
            return "Try removing and re-entering your upload token in settings."
        case .fileSystemError:
            return "Try restarting the app. If the problem persists, reinstall the app."
        case .imageProcessingFailed:
            return "The image may be corrupted or in an unsupported format."
        case .deleteFailed:
            return "The image may have already been deleted, or your token may not have delete permissions."
        }
    }
}
