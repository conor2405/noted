import AVFoundation
import Combine
import SwiftUI

private enum DetailTab: String, CaseIterable, Identifiable {
    case note = "Note"
    case transcript = "Transcript"

    var id: String { rawValue }
}

struct MeetingDetailView: View {
    @EnvironmentObject private var model: AppModel
    let meeting: Meeting

    @State private var selectedTab: DetailTab = .note
    @State private var instructions = ""
    @State private var editedTitle = ""
    @State private var isEditingInstructions = false

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                header
                status
                localAudio

                Picker("Content", selection: $selectedTab) {
                    ForEach(DetailTab.allCases) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)

                switch selectedTab {
                case .note:
                    noteContent
                case .transcript:
                    transcriptContent
                }

                noteInstructions
            }
            .padding()
            .frame(maxWidth: 820, alignment: .leading)
            .frame(maxWidth: .infinity, alignment: .center)
        }
        .navigationTitle(meeting.noteTitle ?? meeting.title)
        .toolbar {
            if meeting.progress == .ready {
                ToolbarItem(placement: .primaryAction) {
                    ShareLink(item: MarkdownRenderer.render(meeting: meeting)) {
                        Label("Share Markdown", systemImage: "square.and.arrow.up")
                    }
                }
            }
        }
        .task(id: meeting.id) {
            instructions = meeting.noteInstructions
            editedTitle = meeting.title
            await model.refreshTranscript(for: meeting.id)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Recording title", text: $editedTitle)
                .font(.largeTitle.bold())
                .textFieldStyle(.plain)
                .onSubmit {
                    Task {
                        await model.updateTitle(meetingID: meeting.id, title: editedTitle)
                    }
                }

            HStack(spacing: 8) {
                Text(meeting.capturedAt.formatted(date: .long, time: .shortened))
                if meeting.durationMilliseconds > 0 {
                    Text("·")
                    Text(
                        TranscriptTimestampFormatter.durationString(
                            milliseconds: meeting.durationMilliseconds
                        )
                    )
                }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private var status: some View {
        HStack(spacing: 10) {
            Image(systemName: meeting.progress.systemImage)
                .foregroundStyle(statusColor)
            VStack(alignment: .leading, spacing: 2) {
                Text(meeting.progress.label)
                    .font(.headline)
                if case .failed(let message) = meeting.progress, let message {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if isProcessing {
                    Text("The note will update here automatically.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            if isProcessing {
                ProgressView()
                    .controlSize(.small)
            }
            if canRetry {
                Button("Retry") {
                    Task { await model.retry(meetingID: meeting.id) }
                }
            }
        }
        .padding()
        .background(.quaternary, in: RoundedRectangle(cornerRadius: 14))
    }

    @ViewBuilder
    private var localAudio: some View {
        if meeting.localAudioFilename != nil {
            LocalAudioPlayer(meetingID: meeting.id)
        }
    }

    @ViewBuilder
    private var noteContent: some View {
        if meeting.noteMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            ContentUnavailableView(
                "Note not ready",
                systemImage: "note.text",
                description: Text(notePlaceholder)
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            Text(.init(meeting.noteMarkdown))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private var transcriptContent: some View {
        if meeting.transcript.isEmpty {
            ContentUnavailableView(
                "Transcript not ready",
                systemImage: "text.bubble",
                description: Text("Speaker-labelled segments appear here after transcription.")
            )
            .frame(maxWidth: .infinity)
            .padding(.vertical, 30)
        } else {
            LazyVStack(alignment: .leading, spacing: 18) {
                ForEach(meeting.transcript.sorted(by: { $0.sequence < $1.sequence })) { segment in
                    TranscriptSegmentView(segment: segment)
                }
            }
            .textSelection(.enabled)
        }
    }

    private var noteInstructions: some View {
        DisclosureGroup("Instructions for this note", isExpanded: $isEditingInstructions) {
            VStack(alignment: .leading, spacing: 10) {
                TextEditor(text: $instructions)
                    .font(.body)
                    .frame(minHeight: 110)
                    .padding(6)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 10))

                Text(
                    meeting.isActivelyRecording
                        ? "These instructions will be sent when the recording stops."
                        : "Changing instructions can regenerate the note without retranscribing the audio."
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button(meeting.progress == .ready ? "Save and regenerate note" : "Save instructions") {
                    Task {
                        await model.updateNoteInstructions(
                            meetingID: meeting.id,
                            instructions: instructions,
                            regenerate: meeting.progress == .ready
                        )
                        isEditingInstructions = false
                    }
                }
                .buttonStyle(.borderedProminent)
            }
            .padding(.top, 8)
        }
    }

    private var notePlaceholder: String {
        switch meeting.progress {
        case .recording:
            "Stop the recording to begin processing."
        case .localOnly:
            "This recording is stored locally. Sign in and configure Firebase to process it."
        default:
            "Noted is creating a note from the transcript."
        }
    }

    private var isProcessing: Bool {
        switch meeting.progress {
        case .waitingToUpload, .uploading, .transcribing, .generatingNote:
            true
        default:
            false
        }
    }

    private var canRetry: Bool {
        model.firebaseConfigured
            && model.signedInUserID != nil
            && (meeting.pipeline.upload == .failed
                || (meeting.pipeline.note == .failed
                    && meeting.pipeline.transcription == .completed))
    }

    private var statusColor: Color {
        switch meeting.progress {
        case .recording: .red
        case .ready: .green
        case .failed: .orange
        default: .secondary
        }
    }
}

private struct TranscriptSegmentView: View {
    let segment: TranscriptSegment

    var body: some View {
        HStack(alignment: .top, spacing: 14) {
            Text(TranscriptTimestampFormatter.string(milliseconds: segment.startMilliseconds))
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
                .frame(width: 54, alignment: .leading)

            VStack(alignment: .leading, spacing: 4) {
                Text(segment.speakerLabel)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Color.accentColor)
                Text(segment.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

@MainActor
private final class AudioPlayerModel: NSObject, ObservableObject, AVAudioPlayerDelegate {
    @Published private(set) var isPlaying = false
    @Published private(set) var isAvailable = false

    private var player: AVAudioPlayer?

    func load(url: URL?) {
        guard let url else {
            isAvailable = false
            player = nil
            return
        }
        do {
            let player = try AVAudioPlayer(contentsOf: url)
            player.delegate = self
            player.prepareToPlay()
            self.player = player
            isAvailable = true
        } catch {
            isAvailable = false
        }
    }

    func toggle() {
        guard let player else { return }
        if player.isPlaying {
            player.pause()
            isPlaying = false
        } else {
            player.play()
            isPlaying = true
        }
    }

    func audioPlayerDidFinishPlaying(_ player: AVAudioPlayer, successfully flag: Bool) {
        isPlaying = false
    }
}

private struct LocalAudioPlayer: View {
    @EnvironmentObject private var appModel: AppModel
    @StateObject private var player = AudioPlayerModel()
    let meetingID: UUID

    var body: some View {
        HStack {
            Button {
                player.toggle()
            } label: {
                Label(player.isPlaying ? "Pause audio" : "Play audio", systemImage: player.isPlaying ? "pause.fill" : "play.fill")
            }
            .buttonStyle(.bordered)
            .disabled(!player.isAvailable)

            Text("Original audio is stored only on this device.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .task(id: meetingID) {
            player.load(url: await appModel.localAudioURL(for: meetingID))
        }
    }
}
