import FirebaseFirestore
import Foundation

enum CloudRepositoryError: LocalizedError {
    case missingTranscript

    var errorDescription: String? {
        switch self {
        case .missingTranscript: "The on-device transcript is not ready to sync."
        }
    }
}

final class FirebaseCloudRepository {
    typealias RecordingsChangeHandler = @Sendable (Result<[Meeting], Error>) -> Void
    typealias PreferencesChangeHandler = @Sendable (Result<String?, Error>) -> Void

    private let database: Firestore
    private var recordingsListener: ListenerRegistration?
    private var preferencesListener: ListenerRegistration?

    init(database: Firestore = .firestore()) {
        self.database = database
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

    func syncTranscript(
        meeting: Meeting,
        userID: String
    ) async throws {
        guard !meeting.transcript.isEmpty else {
            throw CloudRepositoryError.missingTranscript
        }

        let recordingID = meeting.id.uuidString.lowercased()
        let transcriptVersion = "apple-on-device-v1-\(recordingID)"
        let reference = database
            .collection("users")
            .document(userID)
            .collection("recordings")
            .document(recordingID)

        let existing = try await reference.getDocument()
        let existingData = existing.data() ?? [:]
        if existingData["transcriptionState"] as? String == "completed",
           existingData["transcriptVersion"] as? String == transcriptVersion,
           Self.integer(existingData["transcriptSegmentCount"]) == meeting.transcript.count {
            return
        }

        if existing.exists {
            try await reference.updateData([
                "title": meeting.title,
                "durationMilliseconds": meeting.durationMilliseconds,
                "noteInstructions": meeting.noteInstructions,
                "transcriptVersion": transcriptVersion,
                "transcriptSegmentCount": meeting.transcript.count,
                "transcriptSource": "apple_speech_analyzer",
                "syncState": "in_progress",
                "transcriptionState": "in_progress",
                "noteState": "queued",
                "processingError": FieldValue.delete(),
                "errorMessage": FieldValue.delete(),
                "updatedAt": FieldValue.serverTimestamp()
            ])
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
                "transcriptVersion": transcriptVersion,
                "transcriptSegmentCount": meeting.transcript.count,
                "transcriptSource": "apple_speech_analyzer",
                "syncState": "in_progress",
                "transcriptionState": "in_progress",
                "noteState": "queued",
                "exportState": "not_started"
            ])
        }

        let transcriptCollection = reference.collection("transcriptChunks")
        for pageStart in stride(from: 0, to: meeting.transcript.count, by: 400) {
            let pageEnd = min(pageStart + 400, meeting.transcript.count)
            let batch = database.batch()
            for segment in meeting.transcript[pageStart..<pageEnd] {
                let documentID = String(format: "%06d", segment.sequence)
                var data: [String: Any] = [
                    "processingJobId": transcriptVersion,
                    "sequence": segment.sequence,
                    "startMilliseconds": segment.startMilliseconds,
                    "speakerLabel": "",
                    "text": segment.text,
                    "confidence": NSNull(),
                    "languageCode": Locale.current.identifier(.bcp47),
                    "timestampPrecision": "result",
                    "source": "apple_speech_analyzer"
                ]
                if let endMilliseconds = segment.endMilliseconds {
                    data["endMilliseconds"] = endMilliseconds
                }
                batch.setData(
                    data,
                    forDocument: transcriptCollection.document(documentID)
                )
            }
            try await batch.commit()
        }

        try await reference.updateData([
            "syncState": "completed",
            "transcriptionState": "completed",
            "noteState": "queued",
            "updatedAt": FieldValue.serverTimestamp()
        ])
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
                transcription: WorkState(cloudValue: data["transcriptionState"]),
                sync: WorkState(cloudValue: data["syncState"]),
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
            speaker = ""
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
