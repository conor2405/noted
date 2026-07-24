import Combine
import AVFoundation
import Foundation

enum RecordingSource: Sendable {
    case inApp
    case actionButton
}

struct RecordingToggleResult: Sendable {
    var isRecording: Bool
    var meetingID: UUID
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    @Published private(set) var meetings: [Meeting] = []
    @Published var selectedMeetingID: UUID?
    @Published private(set) var isRecording = false
    @Published private(set) var recordingElapsed: TimeInterval = 0
    @Published private(set) var isLoaded = false
    @Published private(set) var signedInUserID: String?
    @Published private(set) var preferences: UserPreferences = .defaults
    @Published private(set) var folderExportError: String?
    @Published var presentedError: String?
    @Published var isShowingSettings = false

    let authentication: AuthenticationService
    let firebaseConfigured: Bool

    private let persistence: LocalPersistence
    private let audioRecorder: AudioRecorder
    private let transcriber: OnDeviceTranscriptionService
    private let cloud: FirebaseCloudRepository?
    private let folderExporter: FolderExportService
    private var startTask: Task<Void, Never>?
    private var hiddenMeetings: [Meeting] = []
    private var isProcessingRecordings = false

    private init(
        persistence: LocalPersistence = .shared,
        audioRecorder: AudioRecorder? = nil,
        folderExporter: FolderExportService? = nil
    ) {
        let firebaseConfigured = FirebaseBootstrap.configureIfAvailable()
        self.firebaseConfigured = firebaseConfigured
        self.persistence = persistence
        self.audioRecorder = audioRecorder ?? AudioRecorder(persistence: persistence)
        self.transcriber = OnDeviceTranscriptionService()
        self.folderExporter = folderExporter ?? FolderExportService(persistence: persistence)
        self.authentication = AuthenticationService(cloudConfigured: firebaseConfigured)
        self.cloud = firebaseConfigured ? FirebaseCloudRepository() : nil

        self.audioRecorder.onElapsed = { [weak self] elapsed in
            self?.recordingElapsed = elapsed
        }
        self.audioRecorder.onUnexpectedStop = { [weak self] error in
            Task { @MainActor in
                guard let self else { return }
                self.presentedError = error?.localizedDescription
                try? await self.finishRecording()
            }
        }
        self.authentication.onUserChanged = { [weak self] userID in
            Task { @MainActor in
                await self?.userDidChange(userID)
            }
        }
    }

    func start() async {
        if isLoaded { return }
        if let startTask {
            await startTask.value
            return
        }

        let task = Task { @MainActor [weak self] in
            guard let self else { return }
            do {
                try await persistence.prepare()
            } catch {
                presentedError = error.localizedDescription
            }

            meetings = await persistence.loadMeetings()
            preferences = await persistence.loadPreferences()
            if firebaseConfigured {
                meetings.removeAll { $0.isDemo }
            }
            applyAccountVisibility(userID: authentication.userID)
            await applyPreferenceVisibility(userID: authentication.userID)
            await recoverInterruptedRecordings()

            if !firebaseConfigured, meetings.isEmpty {
                meetings = [.demo]
                try? await persistence.saveMeetings(meetings)
            }

            meetings.sort { $0.capturedAt > $1.capturedAt }
            selectedMeetingID = selectedMeetingID ?? meetings.first?.id
            isLoaded = true

            if let userID = authentication.userID {
                await userDidChange(userID)
            } else {
                Task { @MainActor [weak self] in
                    await self?.processPendingRecordings()
                }
            }
            await runPendingFolderExports()
        }
        startTask = task
        await task.value
        startTask = nil
    }

    @discardableResult
    func toggleRecording(source: RecordingSource) async throws -> RecordingToggleResult {
        await start()
        if audioRecorder.isRecording {
            let meetingID = try await finishRecording()
            return RecordingToggleResult(isRecording: false, meetingID: meetingID)
        }

        let id = UUID()
        let capturedAt = Date()
        let filename = try await audioRecorder.start(meetingID: id)
        let meeting = Meeting(
            id: id,
            ownerUserID: authentication.userID,
            title: Meeting.defaultTitle(at: capturedAt),
            capturedAt: capturedAt,
            localAudioFilename: filename,
            noteInstructions: "",
            pipeline: PipelineState(),
            isActivelyRecording: true
        )
        meetings.removeAll { $0.isDemo && !firebaseConfigured }
        meetings.insert(meeting, at: 0)
        selectedMeetingID = id
        isRecording = true
        recordingElapsed = 0
        try await persistMeetings()
        return RecordingToggleResult(isRecording: true, meetingID: id)
    }

    func retryPendingWork() async {
        await processPendingRecordings(force: true)
        await runPendingFolderExports(force: true)
    }

    func retry(meetingID: UUID) async {
        guard let meeting = meetings.first(where: { $0.id == meetingID }) else { return }

        if meeting.pipeline.note == .failed,
           meeting.pipeline.transcription == .completed {
            guard
                let userID = authentication.userID,
                let cloud
            else { return }
            do {
                try await cloud.updateNoteInstructions(
                    userID: userID,
                    meetingID: meetingID,
                    instructions: meeting.noteInstructions,
                    regenerate: true
                )
            } catch {
                presentedError = error.localizedDescription
                return
            }

            guard authentication.userID == userID else { return }
            if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
                meetings[index].pipeline.note = .queued
                meetings[index].pipeline.message = nil
            }
            do {
                try await persistMeetings()
            } catch {
                // The backend accepted the retry, so keep the in-memory queued state.
                presentedError = error.localizedDescription
            }
            return
        }

        guard let filename = meeting.localAudioFilename else {
            await retryPendingWork()
            return
        }

        let pending = PendingProcessing(
            meetingID: meeting.id,
            ownerUserID: meeting.ownerUserID,
            localAudioFilename: filename
        )
        do {
            try await persistence.upsertPendingProcessing(pending)
        } catch {
            presentedError = error.localizedDescription
            return
        }
        if let index = meetings.firstIndex(where: { $0.id == meetingID }) {
            if meetings[index].pipeline.transcription == .failed {
                meetings[index].pipeline.transcription = .queued
                meetings[index].pipeline.sync = .notStarted
                meetings[index].pipeline.note = .notStarted
            } else {
                meetings[index].pipeline.sync = firebaseConfigured ? .queued : .notStarted
                meetings[index].pipeline.note = firebaseConfigured ? .queued : .notStarted
            }
            meetings[index].pipeline.message = nil
        }
        do {
            try await persistMeetings()
        } catch {
            // The durable queue is authoritative; continue and let processing update the state.
            presentedError = error.localizedDescription
        }
        await processPendingRecordings(force: true)
    }

    func applicationBecameActive() async {
        await processPendingRecordings()
        await runPendingFolderExports()
    }

    func prepareMicrophoneAccess() async {
        _ = await audioRecorder.prepareMicrophoneAccess()
        do {
            try await transcriber.prepareModel()
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func updateTitle(meetingID: UUID, title: String) async {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        let cleaned = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleaned.isEmpty else { return }
        meetings[index].title = cleaned
        meetings[index].updatedAt = Date()
        let isActivelyRecording = meetings[index].isActivelyRecording
        try? await persistMeetings()
        if let userID = authentication.userID, !isActivelyRecording {
            do {
                try await cloud?.updateTitle(userID: userID, meetingID: meetingID, title: cleaned)
            } catch {
                presentedError = error.localizedDescription
            }
        }
    }

    func updateNoteInstructions(
        meetingID: UUID,
        instructions: String,
        regenerate: Bool
    ) async {
        guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
        meetings[index].noteInstructions = instructions
        meetings[index].updatedAt = Date()
        if regenerate {
            meetings[index].pipeline.note = .queued
        }
        let isActivelyRecording = meetings[index].isActivelyRecording
        try? await persistMeetings()

        guard
            !isActivelyRecording,
            let userID = authentication.userID,
            let cloud
        else { return }

        do {
            try await cloud.updateNoteInstructions(
                userID: userID,
                meetingID: meetingID,
                instructions: instructions,
                regenerate: regenerate
            )
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func updatePreferences(noteInstructions: String) async {
        preferences.noteInstructions = noteInstructions
        preferences.notePreferenceOwnerUserID = authentication.userID
        do {
            try await persistence.savePreferences(preferences)
            if let userID = authentication.userID {
                try await cloud?.savePreferences(userID: userID, instructions: noteInstructions)
            }
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func configureFolderExport(url: URL) async {
        do {
            let previousDestinationID = preferences.folderExport?.destinationID
            let configuration = try await folderExporter.configuration(for: url)
            preferences.folderExport = configuration
            try await persistence.savePreferences(preferences)
            if let previousDestinationID,
               previousDestinationID != configuration.destinationID {
                try? await persistence.removePendingExports(destinationID: previousDestinationID)
                if let userID = authentication.userID {
                    try? await cloud?.removeFolderExportRule(
                        userID: userID,
                        destinationID: previousDestinationID
                    )
                }
            }
            if let userID = authentication.userID {
                try await cloud?.saveFolderExportRule(userID: userID, configuration: configuration)
            }
            try await folderExporter.enqueueAll(meetings, configuration: configuration)
            await runPendingFolderExports(force: true)
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func updateFolderExport(
        isEnabled: Bool,
        subfolder: String,
        includeNote: Bool,
        includeTranscript: Bool
    ) async {
        guard var configuration = preferences.folderExport else { return }
        configuration.isEnabled = isEnabled
        configuration.subfolder = subfolder.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.includeNote = includeNote
        configuration.includeTranscript = includeTranscript
        preferences.folderExport = configuration

        do {
            try await persistence.savePreferences(preferences)
            if let userID = authentication.userID {
                try await cloud?.saveFolderExportRule(userID: userID, configuration: configuration)
            }
            try await folderExporter.enqueueAll(meetings, configuration: configuration)
            await runPendingFolderExports(force: true)
        } catch {
            presentedError = error.localizedDescription
        }
    }

    func removeFolderExport() async {
        let destinationID = preferences.folderExport?.destinationID
        preferences.folderExport = nil
        try? await persistence.savePreferences(preferences)
        if let destinationID {
            try? await persistence.removePendingExports(destinationID: destinationID)
        }
        if let destinationID, let userID = authentication.userID {
            try? await cloud?.removeFolderExportRule(userID: userID, destinationID: destinationID)
        }
    }

    func refreshTranscript(for meetingID: UUID) async {
        guard
            let userID = authentication.userID,
            let cloud,
            meetings.contains(where: { $0.id == meetingID })
        else { return }

        do {
            let segments = try await cloud.fetchTranscript(userID: userID, meetingID: meetingID)
            guard !segments.isEmpty else { return }
            guard authentication.userID == userID else { return }
            guard let index = meetings.firstIndex(where: { $0.id == meetingID }) else { return }
            meetings[index].transcript = segments
            meetings[index].updatedAt = Date()
            let updatedMeeting = meetings[index]
            try await persistMeetings()
            guard authentication.userID == userID else { return }
            await enqueueFolderExportIfNeeded(updatedMeeting)
            await runPendingFolderExports()
        } catch {
            // A transcript can legitimately be unavailable while the backend is still processing.
        }
    }

    func localAudioURL(for meetingID: UUID) async -> URL? {
        guard
            let filename = meetings.first(where: { $0.id == meetingID })?.localAudioFilename
        else { return nil }
        let url = await persistence.audioURL(filename: filename)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    private func finishRecording() async throws -> UUID {
        let result = try audioRecorder.stop()
        guard let index = meetings.firstIndex(where: { $0.id == result.meetingID }) else {
            throw RecordingError.noActiveRecording
        }

        meetings[index].durationMilliseconds = result.durationMilliseconds
        meetings[index].localAudioFilename = result.filename
        meetings[index].isActivelyRecording = false
        meetings[index].updatedAt = Date()
        isRecording = false
        recordingElapsed = 0

        meetings[index].pipeline.transcription = .queued
        meetings[index].pipeline.sync = firebaseConfigured ? .queued : .notStarted
        meetings[index].pipeline.note = firebaseConfigured ? .queued : .notStarted
        let pending = PendingProcessing(
            meetingID: result.meetingID,
            ownerUserID: meetings[index].ownerUserID,
            localAudioFilename: result.filename
        )
        try await persistence.upsertPendingProcessing(pending)
        try await persistMeetings()
        applyAccountVisibility(userID: authentication.userID)
        if !meetings.contains(where: { $0.id == selectedMeetingID }) {
            selectedMeetingID = meetings.first?.id
        }
        let backgroundLease = BackgroundTaskLease(name: "Transcribe Noted recording")
        Task { @MainActor [weak self] in
            await self?.processPendingRecordings()
            backgroundLease.end()
        }
        return result.meetingID
    }

    private func userDidChange(_ userID: String?) async {
        cloud?.stopObserving()
        signedInUserID = userID
        applyAccountVisibility(userID: userID)
        await applyPreferenceVisibility(userID: userID)
        await recoverInterruptedRecordings()
        selectedMeetingID = meetings.contains(where: { $0.id == selectedMeetingID })
            ? selectedMeetingID
            : meetings.first?.id
        guard let userID, let cloud else { return }

        cloud.observeRecordings(userID: userID) { [weak self] result in
            Task { @MainActor in
                guard let self, self.authentication.userID == userID else { return }
                switch result {
                case .success(let remoteMeetings):
                    await self.mergeRemoteMeetings(remoteMeetings, userID: userID)
                case .failure(let error):
                    self.presentedError = error.localizedDescription
                }
            }
        }
        cloud.observePreferences(userID: userID) { [weak self] result in
            Task { @MainActor in
                guard let self, self.authentication.userID == userID else { return }
                switch result {
                case .success(let remoteInstructions):
                    let cleaned = remoteInstructions?
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if let cleaned, !cleaned.isEmpty {
                        self.preferences.noteInstructions = cleaned
                        self.preferences.notePreferenceOwnerUserID = userID
                        try? await self.persistence.savePreferences(self.preferences)
                    } else if (self.preferences.notePreferenceOwnerUserID == nil
                                || self.preferences.notePreferenceOwnerUserID == userID),
                              !self.preferences.noteInstructions
                        .trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        try? await cloud.savePreferences(
                            userID: userID,
                            instructions: self.preferences.noteInstructions
                        )
                        guard self.authentication.userID == userID else { return }
                        self.preferences.notePreferenceOwnerUserID = userID
                        try? await self.persistence.savePreferences(self.preferences)
                    }
                case .failure(let error):
                    self.presentedError = error.localizedDescription
                }
            }
        }
        if let configuration = preferences.folderExport {
            try? await cloud.saveFolderExportRule(userID: userID, configuration: configuration)
        }
        await enqueueUnsyncedMeetings(userID: userID)
        Task { @MainActor [weak self] in
            await self?.processPendingRecordings()
        }
    }

    private func processPendingRecordings(force: Bool = false) async {
        guard !isProcessingRecordings else { return }
        isProcessingRecordings = true
        defer { isProcessingRecordings = false }

        let pending = await persistence.loadPendingProcessing()
        let now = Date()

        for var item in pending {
            guard force || item.nextAttemptAt <= now else { continue }
            guard let currentMeeting = meetings.first(where: { $0.id == item.meetingID }) else {
                continue
            }

            let audioURL = await persistence.audioURL(filename: item.localAudioFilename)
            guard let progressIndex = meetings.firstIndex(where: { $0.id == item.meetingID }) else {
                continue
            }

            do {
                if currentMeeting.pipeline.transcription != .completed
                    || currentMeeting.transcript.isEmpty {
                    meetings[progressIndex].pipeline.transcription = .inProgress
                    meetings[progressIndex].pipeline.message = nil
                    try? await persistMeetings()

                    let segments = try await transcriber.transcribe(fileURL: audioURL)
                    guard let resultIndex = meetings.firstIndex(where: {
                        $0.id == item.meetingID
                    }) else { continue }
                    meetings[resultIndex].transcript = segments
                    meetings[resultIndex].pipeline.transcription = .completed
                    meetings[resultIndex].updatedAt = Date()
                    try await persistMeetings()
                }

                guard firebaseConfigured, let cloud else {
                    try await persistence.removePendingProcessing(meetingID: item.meetingID)
                    if let localMeeting = meetings.first(where: { $0.id == item.meetingID }) {
                        await enqueueFolderExportIfNeeded(localMeeting)
                    }
                    await runPendingFolderExports()
                    continue
                }
                guard let userID = authentication.userID else {
                    if let index = meetings.firstIndex(where: { $0.id == item.meetingID }) {
                        meetings[index].pipeline.sync = .queued
                    }
                    try? await persistMeetings()
                    continue
                }
                guard item.ownerUserID == nil || item.ownerUserID == userID else {
                    continue
                }
                guard currentMeeting.ownerUserID == nil
                        || currentMeeting.ownerUserID == userID else {
                    continue
                }

                item.ownerUserID = userID
                guard let syncIndex = meetings.firstIndex(where: { $0.id == item.meetingID }) else {
                    continue
                }
                meetings[syncIndex].ownerUserID = userID
                meetings[syncIndex].pipeline.sync = .inProgress
                meetings[syncIndex].pipeline.note = .queued
                meetings[syncIndex].pipeline.message = nil
                try await persistence.upsertPendingProcessing(item)
                try await persistMeetings()
                let meetingToSync = meetings[syncIndex]

                try await cloud.syncTranscript(meeting: meetingToSync, userID: userID)
                guard authentication.userID == userID else { return }
                if let resultIndex = meetings.firstIndex(where: { $0.id == item.meetingID }) {
                    meetings[resultIndex].pipeline.sync = .completed
                    meetings[resultIndex].pipeline.note = .queued
                }
                try await persistence.removePendingProcessing(meetingID: item.meetingID)
            } catch {
                item.registerFailure(error, now: now)
                try? await persistence.upsertPendingProcessing(item)
                if let resultIndex = meetings.firstIndex(where: { $0.id == item.meetingID }) {
                    if meetings[resultIndex].pipeline.transcription == .inProgress {
                        meetings[resultIndex].pipeline.transcription = .failed
                    } else {
                        meetings[resultIndex].pipeline.sync = .failed
                    }
                    meetings[resultIndex].pipeline.message = error.localizedDescription
                }
            }
            try? await persistMeetings()
        }
    }

    private func mergeRemoteMeetings(_ remoteMeetings: [Meeting], userID: String) async {
        guard authentication.userID == userID else { return }
        var merged = meetings.filter { meeting in
            meeting.isActivelyRecording
                || meeting.isDemo
                || remoteMeetings.contains(where: { $0.id == meeting.id }) == false
        }

        for var remote in remoteMeetings {
            if let local = meetings.first(where: { $0.id == remote.id }) {
                remote.localAudioFilename = local.localAudioFilename
                if remote.transcript.isEmpty {
                    remote.transcript = local.transcript
                }
                if remote.noteInstructions.isEmpty {
                    remote.noteInstructions = local.noteInstructions
                }
                remote.isActivelyRecording = local.isActivelyRecording
            }
            merged.removeAll { $0.id == remote.id }
            merged.append(remote)
        }

        guard authentication.userID == userID else { return }
        meetings = merged.sorted { $0.capturedAt > $1.capturedAt }
        selectedMeetingID = selectedMeetingID ?? meetings.first?.id
        try? await persistMeetings()
        guard authentication.userID == userID else { return }

        for remote in remoteMeetings where remote.pipeline.sync == .completed {
            try? await persistence.removePendingProcessing(meetingID: remote.id)
        }
        guard authentication.userID == userID else { return }

        for meeting in meetings where
            meeting.pipeline.transcription == .completed && meeting.transcript.isEmpty {
            Task { @MainActor [weak self] in
                await self?.refreshTranscript(for: meeting.id)
            }
        }
        for meeting in meetings {
            await enqueueFolderExportIfNeeded(meeting)
        }
        await runPendingFolderExports()
    }

    private func enqueueFolderExportIfNeeded(_ meeting: Meeting) async {
        guard let configuration = preferences.folderExport else { return }
        try? await folderExporter.enqueue(meeting, configuration: configuration)
    }

    private func runPendingFolderExports(force: Bool = false) async {
        guard let configuration = preferences.folderExport, configuration.isEnabled else { return }
        try? await folderExporter.enqueueAll(meetings, configuration: configuration)
        let outcomes = await folderExporter.process(
            meetings: meetings,
            configuration: configuration,
            now: Date(),
            ignoreRetrySchedule: force
        )
        folderExportError = await folderExporter.latestFailure(
            destinationID: configuration.destinationID
        )
        guard !outcomes.isEmpty else { return }
        for outcome in outcomes {
            guard let index = meetings.firstIndex(where: { $0.id == outcome.meetingID }) else { continue }
            meetings[index].pipeline.export = .completed
            if let userID = authentication.userID {
                try? await cloud?.markFolderExportCompleted(
                    userID: userID,
                    meetingID: outcome.meetingID,
                    configuration: configuration,
                    relativePath: outcome.relativePath
                )
            }
        }
        try? await persistMeetings()
    }

    private func persistMeetings() async throws {
        try await persistence.saveMeetings(
            deduplicatedMeetings(meetings + hiddenMeetings)
        )
    }

    private func recoverInterruptedRecordings() async {
        guard !audioRecorder.isRecording else { return }
        let interruptedIDs = meetings
            .filter(\.isActivelyRecording)
            .map(\.id)
        var didRecover = false
        for meetingID in interruptedIDs {
            guard let initialIndex = meetings.firstIndex(where: { $0.id == meetingID }) else {
                continue
            }
            didRecover = true
            meetings[initialIndex].isActivelyRecording = false
            meetings[initialIndex].updatedAt = Date()

            guard let filename = meetings[initialIndex].localAudioFilename else {
                meetings[initialIndex].pipeline.transcription = .failed
                meetings[initialIndex].pipeline.message = "The interrupted recording has no local audio file."
                continue
            }

            let url = await persistence.audioURL(filename: filename)
            guard let fileIndex = meetings.firstIndex(where: { $0.id == meetingID }) else {
                continue
            }
            guard FileManager.default.fileExists(atPath: url.path) else {
                meetings[fileIndex].pipeline.transcription = .failed
                meetings[fileIndex].pipeline.message = "The interrupted recording’s local audio file is missing."
                continue
            }

            let asset = AVURLAsset(url: url)
            if let duration = try? await asset.load(.duration) {
                let seconds = CMTimeGetSeconds(duration)
                if seconds.isFinite,
                   let durationIndex = meetings.firstIndex(where: { $0.id == meetingID }) {
                    meetings[durationIndex].durationMilliseconds = max(
                        meetings[durationIndex].durationMilliseconds,
                        Int((seconds * 1_000).rounded())
                    )
                }
            }
            guard let recoveredIndex = meetings.firstIndex(where: { $0.id == meetingID }) else {
                continue
            }
            meetings[recoveredIndex].pipeline.transcription = .queued
            meetings[recoveredIndex].pipeline.sync = firebaseConfigured ? .queued : .notStarted
            meetings[recoveredIndex].pipeline.note = firebaseConfigured ? .queued : .notStarted
            try? await persistence.upsertPendingProcessing(
                PendingProcessing(
                    meetingID: meetingID,
                    ownerUserID: meetings[recoveredIndex].ownerUserID,
                    localAudioFilename: filename
                )
            )
        }
        if didRecover {
            try? await persistMeetings()
        }
    }

    private func enqueueUnsyncedMeetings(userID: String) async {
        for meeting in meetings where
            meeting.pipeline.transcription == .completed
                && meeting.pipeline.sync != .completed
                && (meeting.ownerUserID == nil || meeting.ownerUserID == userID) {
            guard let filename = meeting.localAudioFilename else { continue }
            try? await persistence.upsertPendingProcessing(
                PendingProcessing(
                    meetingID: meeting.id,
                    ownerUserID: meeting.ownerUserID,
                    localAudioFilename: filename
                )
            )
        }
    }

    private func applyAccountVisibility(userID: String?) {
        let combined = deduplicatedMeetings(meetings + hiddenMeetings)
        guard firebaseConfigured else {
            meetings = combined.sorted { $0.capturedAt > $1.capturedAt }
            hiddenMeetings = []
            return
        }

        if let userID {
            meetings = combined.filter {
                $0.isActivelyRecording || $0.ownerUserID == nil || $0.ownerUserID == userID
            }
            hiddenMeetings = combined.filter {
                !$0.isActivelyRecording && $0.ownerUserID != nil && $0.ownerUserID != userID
            }
        } else {
            meetings = combined.filter { $0.isActivelyRecording || $0.ownerUserID == nil }
            hiddenMeetings = combined.filter { !$0.isActivelyRecording && $0.ownerUserID != nil }
        }
        meetings.sort { $0.capturedAt > $1.capturedAt }
    }

    private func deduplicatedMeetings(_ values: [Meeting]) -> [Meeting] {
        var seen = Set<UUID>()
        return values.filter { seen.insert($0.id).inserted }
    }

    private func applyPreferenceVisibility(userID: String?) async {
        guard firebaseConfigured else { return }
        if let userID {
            guard preferences.notePreferenceOwnerUserID == nil
                    || preferences.notePreferenceOwnerUserID == userID
            else {
                preferences.noteInstructions = UserPreferences.defaults.noteInstructions
                preferences.notePreferenceOwnerUserID = userID
                try? await persistence.savePreferences(preferences)
                return
            }
        } else if preferences.notePreferenceOwnerUserID != nil {
            preferences.noteInstructions = UserPreferences.defaults.noteInstructions
            preferences.notePreferenceOwnerUserID = nil
            try? await persistence.savePreferences(preferences)
        }
    }
}
