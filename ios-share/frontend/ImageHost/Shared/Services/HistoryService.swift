import Foundation

final class HistoryService {
    static let shared = HistoryService()

    private let fileManager = FileManager.default
    private let encoder = JSONEncoder()
    private let decoder = JSONDecoder()

    private var historyFileURL: URL? {
        Config.sharedContainerURL?.appendingPathComponent(Config.historyFileName)
    }

    init() {
        encoder.dateEncodingStrategy = .iso8601
        decoder.dateDecodingStrategy = .iso8601
    }

    // MARK: - Public Methods

    func save(_ record: UploadRecord) throws {
        var records = try loadAll()

        // Remove any existing record with the same ID
        records.removeAll { $0.id == record.id }

        // Add new record at the beginning
        records.insert(record, at: 0)

        // Limit to max count
        if records.count > Config.maxHistoryCount {
            records = Array(records.prefix(Config.maxHistoryCount))
        }

        try write(records)
    }

    func loadAll() throws -> [UploadRecord] {
        guard let url = historyFileURL else {
            throw ImageHostError.fileSystemError(underlying: NSError(
                domain: "HistoryService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not access shared container"]
            ))
        }

        guard fileManager.fileExists(atPath: url.path) else {
            return []
        }

        do {
            let data = try Data(contentsOf: url)
            return try decoder.decode([UploadRecord].self, from: data)
        } catch {
            throw ImageHostError.fileSystemError(underlying: error)
        }
    }

    func delete(id: String) throws {
        var records = try loadAll()
        records.removeAll { $0.id == id }
        try write(records)
    }

    func clear() throws {
        try write([])
    }

    func getRecord(id: String) throws -> UploadRecord? {
        let records = try loadAll()
        return records.first { $0.id == id }
    }

    // MARK: - Private Methods

    private func write(_ records: [UploadRecord]) throws {
        guard let url = historyFileURL else {
            throw ImageHostError.fileSystemError(underlying: NSError(
                domain: "HistoryService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Could not access shared container"]
            ))
        }

        do {
            let data = try encoder.encode(records)
            try data.write(to: url, options: .atomic)
        } catch {
            throw ImageHostError.fileSystemError(underlying: error)
        }
    }
}
