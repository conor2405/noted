import Foundation

enum WorkState: String, Codable, CaseIterable, Sendable {
    case notStarted
    case queued
    case inProgress
    case completed
    case failed
    case unknown

    init(cloudValue: Any?) {
        guard let raw = cloudValue as? String else {
            self = .notStarted
            return
        }

        switch raw.lowercased() {
        case "notstarted", "not_started", "none", "idle":
            self = .notStarted
        case "queued", "pending":
            self = .queued
        case "inprogress", "in_progress", "processing", "uploading", "transcribing", "generating":
            self = .inProgress
        case "completed", "complete", "ready", "succeeded", "success", "exported", "uploaded", "deleted":
            self = .completed
        case "failed", "error":
            self = .failed
        default:
            self = .unknown
        }
    }

    var cloudValue: String {
        switch self {
        case .notStarted: "not_started"
        case .queued: "queued"
        case .inProgress: "in_progress"
        case .completed: "completed"
        case .failed: "failed"
        case .unknown: "unknown"
        }
    }
}

struct PipelineState: Codable, Hashable, Sendable {
    var transcription: WorkState = .notStarted
    var sync: WorkState = .notStarted
    var note: WorkState = .notStarted
    var export: WorkState = .notStarted
    var message: String?

    init(
        transcription: WorkState = .notStarted,
        sync: WorkState = .notStarted,
        note: WorkState = .notStarted,
        export: WorkState = .notStarted,
        message: String? = nil
    ) {
        self.transcription = transcription
        self.sync = sync
        self.note = note
        self.export = export
        self.message = message
    }

    private enum CodingKeys: String, CodingKey {
        case transcription
        case sync
        case legacyUpload = "upload"
        case note
        case export
        case message
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        transcription = try container.decodeIfPresent(
            WorkState.self,
            forKey: .transcription
        ) ?? .notStarted
        sync = try container.decodeIfPresent(WorkState.self, forKey: .sync)
            ?? container.decodeIfPresent(WorkState.self, forKey: .legacyUpload)
            ?? .notStarted
        note = try container.decodeIfPresent(WorkState.self, forKey: .note)
            ?? .notStarted
        export = try container.decodeIfPresent(WorkState.self, forKey: .export)
            ?? .notStarted
        message = try container.decodeIfPresent(String.self, forKey: .message)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(transcription, forKey: .transcription)
        try container.encode(sync, forKey: .sync)
        try container.encode(note, forKey: .note)
        try container.encode(export, forKey: .export)
        try container.encodeIfPresent(message, forKey: .message)
    }
}

enum MeetingProgress: Equatable, Sendable {
    case recording
    case transcribing
    case waitingToSync
    case syncing
    case generatingNote
    case ready
    case failed(String?)
    case localOnly

    var label: String {
        switch self {
        case .recording: "Recording"
        case .transcribing: "Transcribing on device"
        case .waitingToSync: "Waiting to sync"
        case .syncing: "Syncing transcript"
        case .generatingNote: "Creating note"
        case .ready: "Ready"
        case .failed: "Needs attention"
        case .localOnly: "Saved locally"
        }
    }

    var systemImage: String {
        switch self {
        case .recording: "waveform.circle.fill"
        case .transcribing: "text.bubble"
        case .waitingToSync: "clock.arrow.circlepath"
        case .syncing: "arrow.triangle.2.circlepath"
        case .generatingNote: "sparkles"
        case .ready: "checkmark.circle.fill"
        case .failed: "exclamationmark.triangle.fill"
        case .localOnly: "iphone"
        }
    }
}

struct TranscriptSegment: Identifiable, Codable, Hashable, Sendable {
    var id: String
    var sequence: Int
    var startMilliseconds: Int
    var endMilliseconds: Int?
    var speakerLabel: String
    var text: String

    init(
        id: String = UUID().uuidString,
        sequence: Int,
        startMilliseconds: Int,
        endMilliseconds: Int? = nil,
        speakerLabel: String = "",
        text: String
    ) {
        self.id = id
        self.sequence = sequence
        self.startMilliseconds = max(0, startMilliseconds)
        self.endMilliseconds = endMilliseconds
        self.speakerLabel = speakerLabel
        self.text = text
    }
}

struct Meeting: Identifiable, Codable, Hashable, Sendable {
    var id: UUID
    var ownerUserID: String?
    var title: String
    var capturedAt: Date
    var updatedAt: Date
    var durationMilliseconds: Int
    var localAudioFilename: String?
    var noteInstructions: String
    var noteTitle: String?
    var noteMarkdown: String
    var noteVersion: Int
    var transcript: [TranscriptSegment]
    var pipeline: PipelineState
    var isActivelyRecording: Bool
    var isDemo: Bool

    init(
        id: UUID = UUID(),
        ownerUserID: String? = nil,
        title: String,
        capturedAt: Date = Date(),
        updatedAt: Date = Date(),
        durationMilliseconds: Int = 0,
        localAudioFilename: String? = nil,
        noteInstructions: String = "",
        noteTitle: String? = nil,
        noteMarkdown: String = "",
        noteVersion: Int = 0,
        transcript: [TranscriptSegment] = [],
        pipeline: PipelineState = PipelineState(),
        isActivelyRecording: Bool = false,
        isDemo: Bool = false
    ) {
        self.id = id
        self.ownerUserID = ownerUserID
        self.title = title
        self.capturedAt = capturedAt
        self.updatedAt = updatedAt
        self.durationMilliseconds = durationMilliseconds
        self.localAudioFilename = localAudioFilename
        self.noteInstructions = noteInstructions
        self.noteTitle = noteTitle
        self.noteMarkdown = noteMarkdown
        self.noteVersion = noteVersion
        self.transcript = transcript.sorted { $0.sequence < $1.sequence }
        self.pipeline = pipeline
        self.isActivelyRecording = isActivelyRecording
        self.isDemo = isDemo
    }

    var progress: MeetingProgress {
        if isActivelyRecording {
            return .recording
        }

        if pipeline.transcription == .failed || pipeline.sync == .failed || pipeline.note == .failed {
            return .failed(pipeline.message)
        }

        if pipeline.note == .completed || (!noteMarkdown.isEmpty && !transcript.isEmpty) {
            return .ready
        }

        if pipeline.transcription == .inProgress || pipeline.transcription == .queued {
            return .transcribing
        }

        if pipeline.sync == .inProgress {
            return .syncing
        }

        if pipeline.sync == .queued {
            return .waitingToSync
        }

        if pipeline.note == .inProgress || (pipeline.transcription == .completed && pipeline.note != .completed) {
            return .generatingNote
        }

        return .localOnly
    }

    var duration: TimeInterval {
        TimeInterval(durationMilliseconds) / 1_000
    }

    static func defaultTitle(at date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return "Recording \(formatter.string(from: date))"
    }
}

extension Meeting {
    static let demo = Meeting(
        id: UUID(uuidString: "00000000-0000-4000-8000-000000000001")!,
        title: "Product sync",
        capturedAt: Date().addingTimeInterval(-3_600),
        updatedAt: Date().addingTimeInterval(-3_300),
        durationMilliseconds: 184_000,
        noteInstructions: "Use concise headings and finish with action items.",
        noteTitle: "Product sync",
        noteMarkdown: """
        ## Summary

        The team agreed to ship automatic Markdown export in the first release. Processing will happen after each recording stops.

        ## Decisions

        - Keep original audio on the recording device.
        - Sync notes and timestamped transcript chunks through Firebase.
        - Retry device-folder exports automatically.

        ## Action items

        - Conor: confirm the first Obsidian filename template.
        - Team: test Action Button recording while the phone is locked.
        """,
        noteVersion: 1,
        transcript: [
            TranscriptSegment(
                sequence: 0,
                startMilliseconds: 0,
                endMilliseconds: 8_400,
                text: "For the MVP, recording can process as soon as the user stops."
            ),
            TranscriptSegment(
                sequence: 1,
                startMilliseconds: 8_400,
                endMilliseconds: 19_700,
                text: "Agreed. The generated note and transcript should both remain visible in Noted."
            ),
            TranscriptSegment(
                sequence: 2,
                startMilliseconds: 19_700,
                endMilliseconds: 31_200,
                text: "And completed meetings should export automatically to the selected folder."
            )
        ],
        pipeline: PipelineState(
            transcription: .completed,
            sync: .completed,
            note: .completed,
            export: .notStarted
        ),
        isDemo: true
    )
}
