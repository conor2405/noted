import SwiftUI

struct RootView: View {
    @EnvironmentObject private var model: AppModel
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                if !model.firebaseConfigured {
                    LocalModeBanner()
                } else if model.signedInUserID == nil {
                    SignedOutBanner(authentication: model.authentication)
                }

                List(model.meetings, selection: $model.selectedMeetingID) { meeting in
                    NavigationLink(value: meeting.id) {
                        MeetingRow(meeting: meeting)
                    }
                    .tag(meeting.id)
                }
                .overlay {
                    if model.meetings.isEmpty, model.isLoaded {
                        ContentUnavailableView(
                            "No recordings",
                            systemImage: "waveform",
                            description: Text("Tap record to create your first note.")
                        )
                    }
                }
            }
            .navigationTitle("Noted")
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button {
                        model.isShowingSettings = true
                    } label: {
                        Label("Settings", systemImage: "gearshape")
                    }
                }
            }
            .safeAreaInset(edge: .bottom) {
                RecordingControl()
                    .padding()
                    .background(.bar)
            }
        } detail: {
            if let meetingID = model.selectedMeetingID,
               let meeting = model.meetings.first(where: { $0.id == meetingID }) {
                MeetingDetailView(meeting: meeting)
                    .id(meeting.id)
            } else {
                ContentUnavailableView(
                    "Select a recording",
                    systemImage: "note.text",
                    description: Text("Notes and timestamped transcripts appear here.")
                )
            }
        }
        .task {
            await model.start()
            await model.prepareMicrophoneAccess()
        }
        .onChange(of: scenePhase) { _, phase in
            guard phase == .active else { return }
            Task {
                await model.applicationBecameActive()
            }
        }
        .sheet(isPresented: $model.isShowingSettings) {
            NavigationStack {
                SettingsView()
                    .environmentObject(model)
                    .toolbar {
                        ToolbarItem(placement: .confirmationAction) {
                            Button("Done") {
                                model.isShowingSettings = false
                            }
                        }
                    }
            }
#if os(macOS)
            .frame(minWidth: 560, minHeight: 560)
#endif
        }
        .alert(
            "Noted",
            isPresented: Binding(
                get: { model.presentedError != nil },
                set: { if !$0 { model.presentedError = nil } }
            )
        ) {
            Button("OK") {
                model.presentedError = nil
            }
        } message: {
            Text(model.presentedError ?? "")
        }
    }
}

private struct LocalModeBanner: View {
    var body: some View {
        Label(
            "Local demo mode — add Firebase configuration to enable processing and sync.",
            systemImage: "externaldrive"
        )
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }
}

private struct SignedOutBanner: View {
    @ObservedObject var authentication: AuthenticationService

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Sign in to process and sync recordings.")
                .font(.caption)
                .foregroundStyle(.secondary)
            SignInWithApple(authentication: authentication)
                .frame(maxWidth: 280)
        }
        .padding()
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.thinMaterial)
    }
}

private struct RecordingControl: View {
    @EnvironmentObject private var model: AppModel

    var body: some View {
        HStack(spacing: 14) {
            Button {
                Task {
                    do {
                        _ = try await model.toggleRecording(source: .inApp)
                    } catch {
                        model.presentedError = error.localizedDescription
                    }
                }
            } label: {
                ZStack {
                    Circle()
                        .fill(model.isRecording ? Color.red.opacity(0.15) : Color.red)
                        .frame(width: 54, height: 54)
                    if model.isRecording {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(.red)
                            .frame(width: 20, height: 20)
                    } else {
                        Image(systemName: "waveform")
                            .font(.title3.weight(.semibold))
                            .foregroundStyle(.white)
                    }
                }
            }
            .buttonStyle(.plain)
            .accessibilityLabel(model.isRecording ? "Stop recording" : "Start recording")

            VStack(alignment: .leading, spacing: 2) {
                Text(model.isRecording ? "Recording" : "New recording")
                    .font(.headline)
                Text(
                    model.isRecording
                        ? TranscriptTimestampFormatter.string(
                            milliseconds: Int(model.recordingElapsed * 1_000)
                        )
                        : "Audio stays on this device"
                )
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}

private struct MeetingRow: View {
    let meeting: Meeting

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            HStack(spacing: 6) {
                Text(meeting.noteTitle ?? meeting.title)
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Image(systemName: meeting.progress.systemImage)
                    .foregroundStyle(statusColor)
                    .symbolEffect(.pulse, isActive: isProcessing)
            }

            HStack {
                Text(meeting.capturedAt, style: .date)
                Text("·")
                Text(meeting.capturedAt, style: .time)
                if meeting.durationMilliseconds > 0 {
                    Text("·")
                    Text(
                        TranscriptTimestampFormatter.durationString(
                            milliseconds: meeting.durationMilliseconds
                        )
                    )
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)

            Text(meeting.progress.label)
                .font(.caption)
                .foregroundStyle(statusColor)
        }
        .padding(.vertical, 4)
    }

    private var isProcessing: Bool {
        switch meeting.progress {
        case .uploading, .transcribing, .generatingNote:
            true
        default:
            false
        }
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
