import SwiftUI
import UniformTypeIdentifiers

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel

    @State private var noteInstructions = ""
    @State private var automaticExportEnabled = true
    @State private var exportSubfolder = ""
    @State private var includeNote = true
    @State private var includeTranscript = true
    @State private var isChoosingFolder = false

    var body: some View {
        Form {
            accountSection
            notePreferencesSection
            automaticExportSection
            actionButtonSection
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .task {
            loadValues()
        }
        .fileImporter(
            isPresented: $isChoosingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                guard let url = urls.first else { return }
                Task {
                    await model.configureFolderExport(url: url)
                    loadValues()
                }
            case .failure(let error):
                model.presentedError = error.localizedDescription
            }
        }
    }

    @ViewBuilder
    private var accountSection: some View {
        Section("Account and sync") {
            if !model.firebaseConfigured {
                LabeledContent("Mode", value: "Local demo")
                Text("Add GoogleService-Info.plist to enable Sign in with Apple, processing, and Firebase sync.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if model.signedInUserID != nil {
                LabeledContent(
                    "Signed in",
                    value: model.authentication.displayName ?? "Apple account"
                )
                Button("Sign out", role: .destructive) {
                    model.authentication.signOut()
                }
                .disabled(model.isRecording)
            } else {
                SignInWithApple(authentication: model.authentication)
                    .frame(maxWidth: 320)
            }
        }
    }

    private var notePreferencesSection: some View {
        Section {
            TextEditor(text: $noteInstructions)
                .frame(minHeight: 130)
            Button("Save note preferences") {
                Task {
                    await model.updatePreferences(noteInstructions: noteInstructions)
                }
            }
        } header: {
            Text("Default note instructions")
        } footer: {
            Text("These instructions are added to every note-generation request. Each recording can override them.")
        }
    }

    @ViewBuilder
    private var automaticExportSection: some View {
        Section {
            if let destination = model.preferences.folderExport {
                LabeledContent("Folder", value: destination.displayName)
                Toggle("Export automatically", isOn: $automaticExportEnabled)
                TextField("Optional subfolder", text: $exportSubfolder)
                Toggle("Include generated note", isOn: $includeNote)
                Toggle("Include timestamped transcript", isOn: $includeTranscript)

                if let exportError = model.folderExportError {
                    Label(exportError, systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                    Button("Retry queued exports") {
                        Task { await model.retryPendingWork() }
                    }
                }

                Button("Save automation") {
                    if !includeNote && !includeTranscript {
                        includeNote = true
                    }
                    Task {
                        await model.updateFolderExport(
                            isEnabled: automaticExportEnabled,
                            subfolder: exportSubfolder,
                            includeNote: includeNote,
                            includeTranscript: includeTranscript
                        )
                    }
                }

                HStack {
                    Button("Reconnect or change folder") {
                        isChoosingFolder = true
                    }
                    Spacer()
                    Button("Remove", role: .destructive) {
                        Task {
                            await model.removeFolderExport()
                            loadValues()
                        }
                    }
                }
            } else {
                Button {
                    isChoosingFolder = true
                } label: {
                    Label("Choose automatic export folder", systemImage: "folder.badge.plus")
                }
            }
        } header: {
            Text("Automatic Markdown export")
        } footer: {
            Text("Noted writes a deterministic Markdown file after processing. Each device must authorise its own folder. If iOS suspends the app, queued exports catch up the next time Noted runs.")
        }
    }

    private var actionButtonSection: some View {
        Section("Action Button") {
            Label("Choose Noted’s “Toggle Recording” shortcut in Action Button settings.", systemImage: "button.programmable")
            Text("Open Noted and grant microphone permission before the first locked-phone recording. Press once to start and again to stop.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func loadValues() {
        noteInstructions = model.preferences.noteInstructions
        if let configuration = model.preferences.folderExport {
            automaticExportEnabled = configuration.isEnabled
            exportSubfolder = configuration.subfolder
            includeNote = configuration.includeNote
            includeTranscript = configuration.includeTranscript
        } else {
            automaticExportEnabled = true
            exportSubfolder = ""
            includeNote = true
            includeTranscript = true
        }
    }
}
