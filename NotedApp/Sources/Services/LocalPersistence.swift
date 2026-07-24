import Foundation

actor LocalPersistence {
    static let shared = LocalPersistence()

    private let fileManager: FileManager
    private let rootURL: URL
    private let audioDirectoryURL: URL
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    init(fileManager: FileManager = .default, rootURL: URL? = nil) {
        self.fileManager = fileManager
        let appSupport = rootURL
            ?? fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
                .appendingPathComponent("Noted", isDirectory: true)
        self.rootURL = appSupport
        self.audioDirectoryURL = appSupport.appendingPathComponent("Audio", isDirectory: true)

        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    func prepare() throws {
        try fileManager.createDirectory(at: rootURL, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: audioDirectoryURL, withIntermediateDirectories: true)

        var resourceValues = URLResourceValues()
        resourceValues.isExcludedFromBackup = true
        var localRootURL = rootURL
        var localAudioURL = audioDirectoryURL
        try? localRootURL.setResourceValues(resourceValues)
        try? localAudioURL.setResourceValues(resourceValues)

#if os(iOS)
        let protection = FileProtectionType.completeUntilFirstUserAuthentication
        try? fileManager.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: rootURL.path
        )
        try? fileManager.setAttributes(
            [.protectionKey: protection],
            ofItemAtPath: audioDirectoryURL.path
        )
#endif
    }

    func newAudioURL(meetingID: UUID) throws -> URL {
        try prepare()
        return audioDirectoryURL.appendingPathComponent("\(meetingID.uuidString.lowercased()).m4a")
    }

    func audioURL(filename: String) -> URL {
        audioDirectoryURL.appendingPathComponent(URL(fileURLWithPath: filename).lastPathComponent)
    }

    func loadMeetings() -> [Meeting] {
        read([Meeting].self, from: "meetings.json") ?? []
    }

    func saveMeetings(_ meetings: [Meeting]) throws {
        try write(meetings, to: "meetings.json")
    }

    func loadPendingUploads() -> [PendingUpload] {
        read([PendingUpload].self, from: "pending-uploads.json") ?? []
    }

    func savePendingUploads(_ uploads: [PendingUpload]) throws {
        try write(uploads, to: "pending-uploads.json")
    }

    func upsertPendingUpload(_ upload: PendingUpload) throws {
        var uploads = loadPendingUploads()
        uploads.removeAll { $0.meetingID == upload.meetingID }
        uploads.append(upload)
        try savePendingUploads(uploads)
    }

    func removePendingUpload(meetingID: UUID) throws {
        var uploads = loadPendingUploads()
        uploads.removeAll { $0.meetingID == meetingID }
        try savePendingUploads(uploads)
    }

    func loadPendingExports() -> [PendingFolderExport] {
        read([PendingFolderExport].self, from: "pending-exports.json") ?? []
    }

    func savePendingExports(_ exports: [PendingFolderExport]) throws {
        try write(exports, to: "pending-exports.json")
    }

    @discardableResult
    func enqueuePendingExportIfNeeded(_ export: PendingFolderExport) throws -> Bool {
        let receipts = loadExportReceipts()
        guard receipts[export.key]?.contentDigest != export.contentDigest else {
            return false
        }
        var exports = loadPendingExports()
        exports.removeAll { $0.key == export.key }
        exports.append(export)
        try savePendingExports(exports)
        return true
    }

    func upsertPendingExport(_ export: PendingFolderExport) throws {
        var exports = loadPendingExports()
        exports.removeAll { $0.key == export.key }
        exports.append(export)
        try savePendingExports(exports)
    }

    func registerPendingExportFailure(
        _ export: PendingFolderExport,
        replacingDigest: String
    ) throws {
        var exports = loadPendingExports()
        guard let index = exports.firstIndex(where: { $0.key == export.key }) else {
            return
        }
        guard exports[index].contentDigest == replacingDigest else {
            return
        }
        exports[index] = export
        try savePendingExports(exports)
    }

    func completePendingExport(
        _ export: PendingFolderExport,
        replacingDigest: String,
        receipt: ExportReceipt
    ) throws {
        // Persist the receipt first. A crash between these writes can cause a harmless
        // deterministic overwrite, but it cannot lose both the receipt and retry job.
        var receipts = loadExportReceipts()
        receipts[receipt.key] = receipt
        try saveExportReceipts(receipts)

        var exports = loadPendingExports()
        exports.removeAll {
            $0.key == export.key && $0.contentDigest == replacingDigest
        }
        try savePendingExports(exports)
    }

    func removePendingExports(destinationID: UUID) throws {
        var exports = loadPendingExports()
        exports.removeAll { $0.destinationID == destinationID }
        try savePendingExports(exports)
    }

    func loadExportReceipts() -> [String: ExportReceipt] {
        read([String: ExportReceipt].self, from: "export-receipts.json") ?? [:]
    }

    func saveExportReceipts(_ receipts: [String: ExportReceipt]) throws {
        try write(receipts, to: "export-receipts.json")
    }

    func loadPreferences() -> UserPreferences {
        read(UserPreferences.self, from: "preferences.json") ?? .defaults
    }

    func savePreferences(_ preferences: UserPreferences) throws {
        try write(preferences, to: "preferences.json")
    }

    private func read<T: Decodable>(_ type: T.Type, from filename: String) -> T? {
        let url = rootURL.appendingPathComponent(filename)
        guard let data = try? Data(contentsOf: url) else {
            return nil
        }
        return try? decoder.decode(type, from: data)
    }

    private func write<T: Encodable>(_ value: T, to filename: String) throws {
        try prepare()
        let data = try encoder.encode(value)
        try data.write(to: rootURL.appendingPathComponent(filename), options: .atomic)
    }
}
