import Foundation

struct Config {
    static let appGroup = "group.com.imagehost.shared"
    static let keychainService = "com.imagehost"
    static let keychainAccessGroup = "group.com.imagehost.shared"

    // Keys for UserDefaults
    static let backendUrlKey = "backendUrl"
    static let uploadTokenKey = "uploadToken"

    // History file name
    static let historyFileName = "upload_history.json"
    static let maxHistoryCount = 100

    // Image processing
    static let maxUploadDimension: CGFloat = 4096
    static let thumbnailSize: CGFloat = 200
    static let jpegQuality: CGFloat = 0.85

    // Shared UserDefaults
    static var sharedDefaults: UserDefaults? {
        UserDefaults(suiteName: appGroup)
    }

    // Shared container URL
    static var sharedContainerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroup)
    }
}
