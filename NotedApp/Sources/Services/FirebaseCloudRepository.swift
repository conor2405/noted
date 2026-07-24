import FirebaseFirestore
import FirebaseStorage
import Foundation

enum CloudRepositoryError: LocalizedError {
    case signedOut
    case missingAudio

    var errorDescription: String? {
        switch self {
        case .signedOut: "Sign in before uploading recordings."
        case .missingAudio: "The local audio file could not be found."
        }
    }
}

final class FirebaseCloudRepository {
    typealias RecordingsChangeHandler = @Sendable (Result<[Meeting], Error>) -> Void
    typealias PreferencesChangeHandler = @Sendable (Result<String?, Error>) -> Void

    private let database: Firestore
    private let storage: Storage
    private var recordingsListener: ListenerRegistration?
    private var preferencesListener: ListenerRegistration?

    init(database: Firestore = .firestore(), storage: Storage = .storage()) {
        self.database = database
        self.storage = storage
    }

    deinit {
        recordingsListener?.remove()
        preferencesListener?.remove()
    }

    func observeRecordings(userID: String, handler: @escaping RecordingsChangeHandler) {
        recordingsListener?.remove()
        recordingsListener = database
            .collection("users")
            .document(userID)
            .collection("recordings")
            .order(by: "createdAt", descending: true)
            .addSnapshotListener { snapshot, error in
                if let error {
                    handler(.failure(error))
                    return
                }
                let meetings = snapshot?.documents.compactMap(Self.decodeMeeting) ?? []
                handler(.success(meetings))
            }
    }

    func stopObserving() {
        recordingsListener?.remove()
        recordingsListener = nil
        preferencesListener?.remove()
        preferencesListener = nil
    }

    func observePreferences(userID: String, handler: @escaping PreferencesChangeHandler) {
        preferencesListener?.remove()
        preferencesListener = database
            .collection("users")
            .document(userID)
            .collection("preferences")
            .document("default")
            .addSnapshotListener { snapshot, error in
                if let error {
                    handler(.failure(error))
                    return
                }
                let instructions = snapshot?.data()?["noteInstructions"] as? String
                handler(.success(instructions))
            }
    }

    func upload(
        meeting: Meeting,
        audioURL: URL,
        userID: String
    ) async throws {
        guard FileManager.default.fileExists(atPath: audioURL.path) else {
            throw CloudRepositoryError.missingAudio
        }

        let recordingID = meeting.id.uuidString.lowercased()
        let storagePath = "recordings/\(userID)/\(recordingID)/source.m4a"
        let reference = database
            .collection("users")
            .document(userID)
            .collection("recordings")
            .document(recordingID)
        let storageReference = storage.reference(withPath: storagePath)

        let existing = try await reference.getDocument()
        if existing.exists {
            let data = existing.data() ?? [:]
            let uploadState = data["uploadState"] as? String
            let transcriptionState = data["transcriptionState"] as? String
            if transcriptionState == "failed" {
                try? await storageReference.delete()
            } else {
                if let uploadState, ["completed", "uploaded", "deleted"].contains(uploadState) {
                    return
                }
                if let transcriptionState,
                   ["in_progress", "processing", "completed", "ready"].contains(transcriptionState) {
                    return
                }
            }
        } else {
            try await reference.setData([
                "ownerUid": userID,
                "title": meeting.title,
                "createdAt": Timestamp(date: meeting.capturedAt),
                "capturedAt": Timestamp(date: meeting.capturedAt),
                "startedAt": Timestamp(date: meeting.capturedAt),
                "updatedAt": FieldValue.serverTimestamp(),
                "durationMilliseconds": meeting.durationMilliseconds,
                "noteInstructions": meeting.noteInstructions,
                "audioStoragePath": storagePath,
                "uploadState": "in_progress",
                "transcriptionState": "queued",
                "noteState": "queued",
                "exportState": "not_started"
            ])
        }

        let metadata = StorageMetadata()
        metadata.contentType = "audio/mp4"
        metadata.customMetadata = [
            "recordingID": recordingID,
            "ownerID": userID
        ]
        _ = try await storageReference.putFileAsync(from: audioURL, metadata: metadata)
    }

    func fetchTranscript(userID: String, meetingID: UUID) async throws -> [TranscriptSegment] {
        let snapshot = try await database
            .collection("users")
            .document(userID)
            .collection("recordings")
            .document(meetingID.uuidString.lowercased())
            .collection("transcriptChunks")
            .order(by: "sequence")
            .getDocuments()

        return snapshot.documents.enumerated().compactMap { fallbackSequence, document in
            Self.decodeTranscriptSegment(
                id: document.documentID,
                data: document.data(),
                fallbackSequence: fallbackSequence
            )
        }
    }

    func updateNoteInstructions(
        userID: String,
        meetingID: UUID,
        instructions: String,
        regenerate: Bool
    ) async throws {
        let reference = database
            .collection("users")
            .document(userID)
            .collection("recordings")
            .document(meetingID.uuidString.lowercased())
        guard try await reference.getDocument().exists else { return }

        var data: [String: Any] = [
            "noteInstructions": instructions,
            "updatedAt": FieldValue.serverTimestamp()
        ]
        if regenerate {
            data["noteState"] = "queued"
        }

        try await reference.updateData(data)
    }

    func updateTitle(userID: String, meetingID: UUID, title: String) async throws {
        let reference = database
            .collection("users")
            .document(userID)
            .collection("recordings")
            .document(meetingID.uuidString.lowercased())
        guard try await reference.getDocument().exists else { return }
        try await reference.updateData([
            "title": title,
            "updatedAt": FieldValue.serverTimestamp()
        ])
    }

    func savePreferences(userID: String, instructions: String) async throws {
        try await database
            .collection("users")
            .document(userID)
            .collection("preferences")
            .document("default")
            .setData([
                "noteInstructions": instructions,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
    }

    func saveFolderExportRule(
        userID: String,
        configuration: FolderExportConfiguration
    ) async throws {
        try await database
            .collection("users")
            .document(userID)
            .collection("exportRules")
            .document(configuration.destinationID.uuidString.lowercased())
            .setData([
                "destinationType": "folder",
                "enabled": configuration.isEnabled,
                "includeNotes": configuration.includeNote,
                "includeTranscript": configuration.includeTranscript,
                "displayName": configuration.displayName,
                "subfolder": configuration.subfolder,
                "updatedAt": FieldValue.serverTimestamp()
            ], merge: true)
    }

    func removeFolderExportRule(userID: String, destinationID: UUID) async throws {
        try await database
            .collection("users")
            .document(userID)
            .collection("exportRules")
            .document(destinationID.uuidString.lowercased())
            .delete()
    }

    func markFolderExportCompleted(
        userID: String,
        meetingID: UUID,
        configuration: FolderExportConfiguration,
        relativePath: String
    ) async throws {
        let recordingID = meetingID.uuidString.lowercased()
        let ruleID = configuration.destinationID.uuidString.lowercased()
        let attempts = try await database
            .collection("users")
            .document(userID)
            .collection("exportAttempts")
            .whereField("recordingId", isEqualTo: recordingID)
            .whereField("ruleId", isEqualTo: ruleID)
            .getDocuments()

        let batch = database.batch()
        for attempt in attempts.documents {
            batch.updateData([
                "state": "completed",
                "deviceId": DeviceIdentity.current,
                "exportedAt": FieldValue.serverTimestamp(),
                "outputPath": relativePath,
                "updatedAt": FieldValue.serverTimestamp()
            ], forDocument: attempt.reference)
        }

        let recordingReference = database
            .collection("users")
            .document(userID)
            .collection("recordings")
            .document(recordingID)
        batch.updateData([
            "exportState": "completed",
            "updatedAt": FieldValue.serverTimestamp()
        ], forDocument: recordingReference)
        try await batch.commit()
    }

    private static func decodeMeeting(_ document: QueryDocumentSnapshot) -> Meeting? {
        guard let id = UUID(uuidString: document.documentID) else { return nil }
        let data = document.data()
        let createdAt = date(data["capturedAt"]) ?? date(data["createdAt"]) ?? Date()
        let updatedAt = date(data["updatedAt"]) ?? createdAt
        let title = string(data["title"]) ?? Meeting.defaultTitle(at: createdAt)
        let noteTitle = string(data["noteTitle"])
        let noteMarkdown = string(data["noteMarkdown"]) ?? string(data["generatedNote"]) ?? ""
        let processingError = data["processingError"] as? [String: Any]
        let errorMessage = string(data["errorMessage"])
            ?? string(data["processingError"])
            ?? string(processingError?["message"])

        return Meeting(
            id: id,
            ownerUserID: string(data["ownerUid"]),
            title: title,
            capturedAt: createdAt,
            updatedAt: updatedAt,
            durationMilliseconds: integer(data["durationMilliseconds"]) ?? 0,
            localAudioFilename: nil,
            noteInstructions: string(data["noteInstructions"]) ?? "",
            noteTitle: noteTitle,
            noteMarkdown: noteMarkdown,
            noteVersion: integer(data["noteVersion"]) ?? 0,
            transcript: [],
            pipeline: PipelineState(
                upload: WorkState(cloudValue: data["uploadState"]),
                transcription: WorkState(cloudValue: data["transcriptionState"]),
                note: WorkState(cloudValue: data["noteState"]),
                export: WorkState(cloudValue: data["exportState"]),
                message: errorMessage
            )
        )
    }

    private static func decodeTranscriptSegment(
        id: String,
        data: [String: Any],
        fallbackSequence: Int
    ) -> TranscriptSegment? {
        guard let text = string(data["text"]), !text.isEmpty else { return nil }
        let speaker: String
        if let label = string(data["speakerLabel"]) ?? string(data["speaker"]) {
            speaker = label
        } else if let speakerNumber = integer(data["speakerTag"]) {
            speaker = "Speaker \(speakerNumber)"
        } else {
            speaker = "Speaker"
        }

        return TranscriptSegment(
            id: id,
            sequence: integer(data["sequence"]) ?? integer(data["index"]) ?? fallbackSequence,
            startMilliseconds: integer(data["startMilliseconds"])
                ?? integer(data["startMs"])
                ?? 0,
            endMilliseconds: integer(data["endMilliseconds"]) ?? integer(data["endMs"]),
            speakerLabel: speaker,
            text: text
        )
    }

    private static func string(_ value: Any?) -> String? {
        value as? String
    }

    private static func integer(_ value: Any?) -> Int? {
        if let value = value as? Int { return value }
        if let value = value as? Int64 { return Int(value) }
        if let value = value as? NSNumber { return value.intValue }
        return nil
    }

    private static func date(_ value: Any?) -> Date? {
        if let timestamp = value as? Timestamp { return timestamp.dateValue() }
        if let date = value as? Date { return date }
        return nil
    }
}

private enum DeviceIdentity {
    static let current: String = {
        let key = "noted.device-identity"
        if let existing = UserDefaults.standard.string(forKey: key) {
            return existing
        }
        let value = "apple-\(UUID().uuidString.lowercased())"
        UserDefaults.standard.set(value, forKey: key)
        return value
    }()
}
