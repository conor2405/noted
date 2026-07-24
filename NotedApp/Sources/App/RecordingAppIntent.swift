#if os(iOS)
import AppIntents
import Foundation

@available(iOS 18.0, *)
struct ToggleNotedRecordingIntent: AudioRecordingIntent {
    static let title: LocalizedStringResource = "Toggle Noted Recording"
    static let description = IntentDescription(
        "Starts or stops a Noted recording without opening the app."
    )
    static let openAppWhenRun = false
    static let authenticationPolicy: IntentAuthenticationPolicy = .alwaysAllowed

    func perform() async throws -> some IntentResult & ProvidesDialog {
        do {
            let result = try await AppModel.shared.toggleRecording(source: .actionButton)
            if result.isRecording {
                return .result(dialog: "Noted is recording.")
            }
            return .result(dialog: "Recording saved. Transcription will begin now.")
        } catch RecordingError.microphonePermissionDenied {
            return .result(
                dialog: "Open Noted once and allow microphone access before using the Action Button."
            )
        } catch CloudRepositoryError.signedOut {
            return .result(
                dialog: "Open Noted and sign in before using the Action Button."
            )
        } catch {
            return .result(dialog: "Noted could not change the recording state. Open the app to try again.")
        }
    }
}

@available(iOS 18.0, *)
struct NotedAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: ToggleNotedRecordingIntent(),
            phrases: [
                "Record with \(.applicationName)",
                "Toggle recording in \(.applicationName)"
            ],
            shortTitle: "Toggle Recording",
            systemImageName: "waveform.circle.fill"
        )
    }
}
#endif
