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
    var upload: WorkState = .notStarted
    var transcription: WorkState = .notStarted
    var note: WorkState = .notStarted
    var export: WorkState = .notStarted
    var message: String?
}

enum MeetingProgress: Equatable, Sendable {
    case recording
    case waitingToUpload
    case uploading
    case transcribing
    case generatingNote
    case ready
    case failed(String?)
    case localOnly

    var label: String {
        switch self {
        case .recording: "Recording"
        case .waitingToUpload: "Waiting to upload"
        case .uploading: "Uploading"
        case .transcribing: "Transcribing"
        case .generatingNote: "Creating note"
        case .ready: "Ready"
        case .failed: "Needs attention"
        case .localOnly: "Saved locally"
        }
    }

    var systemImage: String {
        switch self {
        case .recording: "waveform.circle.fill"
        case .waitingToUpload: "clock.arrow.circlepath"
        case .uploading: "arrow.up.circle"
        case .transcribing: "text.bubble"
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
        speakerLabel: String = "Speaker",
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

        if pipeline.upload == .failed || pipeline.transcription == .failed || pipeline.note == .failed {
            return .failed(pipeline.message)
        }

        if pipeline.note == .completed || (!noteMarkdown.isEmpty && !transcript.isEmpty) {
            return .ready
        }

        if pipeline.upload == .inProgress {
            return .uploading
        }

        if pipeline.upload == .queued {
            return .waitingToUpload
        }

        if pipeline.transcription == .inProgress || pipeline.transcription == .queued {
            return .transcribing
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
                speakerLabel: "Speaker 1",
                text: "For the MVP, recording can process as soon as the user stops."
            ),
            TranscriptSegment(
                sequence: 1,
                startMilliseconds: 8_400,
                endMilliseconds: 19_700,
                speakerLabel: "Speaker 2",
                text: "Agreed. The generated note and transcript should both remain visible in Noted."
            ),
            TranscriptSegment(
                sequence: 2,
                startMilliseconds: 19_700,
                endMilliseconds: 31_200,
                speakerLabel: "Speaker 1",
                text: "And completed meetings should export automatically to the selected folder."
            )
        ],
        pipeline: PipelineState(
            upload: .completed,
            transcription: .completed,
            note: .completed,
            export: .notStarted
        ),
        isDemo: true
    )
}
