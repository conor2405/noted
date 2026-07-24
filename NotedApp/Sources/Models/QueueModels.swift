import Foundation

struct PendingProcessing: Identifiable, Codable, Hashable, Sendable {
    var id: UUID { meetingID }
    var meetingID: UUID
    var ownerUserID: String?
    var localAudioFilename: String
    var createdAt: Date
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastError: String?

    init(
        meetingID: UUID,
        ownerUserID: String? = nil,
        localAudioFilename: String,
        createdAt: Date = Date()
    ) {
        self.meetingID = meetingID
        self.ownerUserID = ownerUserID
        self.localAudioFilename = localAudioFilename
        self.createdAt = createdAt
        self.attemptCount = 0
        self.nextAttemptAt = createdAt
    }

    mutating func registerFailure(_ error: Error, now: Date = Date()) {
        attemptCount += 1
        lastError = error.localizedDescription
        let delay = min(pow(2, Double(attemptCount)) * 15, 3_600)
        nextAttemptAt = now.addingTimeInterval(delay)
    }
}

struct PendingFolderExport: Identifiable, Codable, Hashable, Sendable {
    var id: String { key }
    var meetingID: UUID
    var destinationID: UUID
    var contentDigest: String
    var createdAt: Date
    var attemptCount: Int
    var nextAttemptAt: Date
    var lastError: String?

    var key: String {
        "\(destinationID.uuidString):\(meetingID.uuidString)"
    }

    mutating func registerFailure(_ error: Error, now: Date = Date()) {
        attemptCount += 1
        lastError = error.localizedDescription
        let delay = min(pow(2, Double(attemptCount)) * 10, 3_600)
        nextAttemptAt = now.addingTimeInterval(delay)
    }
}

struct ExportReceipt: Codable, Hashable, Sendable {
    var key: String
    var contentDigest: String
    var relativePath: String
    var exportedAt: Date
}

struct FolderExportConfiguration: Codable, Equatable, Sendable {
    var destinationID: UUID
    var bookmarkData: Data
    var displayName: String
    var isEnabled: Bool
    var subfolder: String
    var includeNote: Bool
    var includeTranscript: Bool

    init(
        destinationID: UUID = UUID(),
        bookmarkData: Data,
        displayName: String,
        isEnabled: Bool = true,
        subfolder: String = "",
        includeNote: Bool = true,
        includeTranscript: Bool = true
    ) {
        self.destinationID = destinationID
        self.bookmarkData = bookmarkData
        self.displayName = displayName
        self.isEnabled = isEnabled
        self.subfolder = subfolder
        self.includeNote = includeNote
        self.includeTranscript = includeTranscript
    }
}

struct UserPreferences: Codable, Equatable, Sendable {
    var noteInstructions: String
    var notePreferenceOwnerUserID: String?
    var folderExport: FolderExportConfiguration?

    static let defaults = UserPreferences(
        noteInstructions: "Create a concise, well-structured note. Preserve decisions, key facts, and action items.",
        notePreferenceOwnerUserID: nil,
        folderExport: nil
    )
}
