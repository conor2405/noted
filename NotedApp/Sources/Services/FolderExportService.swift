import Foundation

enum FolderExportError: LocalizedError {
    case staleBookmark
    case destinationUnavailable
    case invalidSubfolder
    case coordinationFailed(Error)

    var errorDescription: String? {
        switch self {
        case .staleBookmark:
            "Folder access has expired. Reconnect the export folder in Settings."
        case .destinationUnavailable:
            "The export folder is unavailable. It may be offline or its permission may have been revoked."
        case .invalidSubfolder:
            "The export subfolder contains an invalid path component."
        case .coordinationFailed(let error):
            "The note could not be written safely: \(error.localizedDescription)"
        }
    }
}

struct FolderExportOutcome: Sendable {
    var meetingID: UUID
    var relativePath: String
}

actor FolderExportService {
    private let persistence: LocalPersistence
    private var isProcessing = false

    init(persistence: LocalPersistence = .shared) {
        self.persistence = persistence
    }

    func configuration(for selectedFolder: URL) throws -> FolderExportConfiguration {
        let didAccess = selectedFolder.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                selectedFolder.stopAccessingSecurityScopedResource()
            }
        }

#if os(macOS)
        let bookmark = try selectedFolder.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
#else
        let bookmark = try selectedFolder.bookmarkData(
            options: .minimalBookmark,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
#endif
        return FolderExportConfiguration(
            bookmarkData: bookmark,
            displayName: selectedFolder.lastPathComponent
        )
    }

    func enqueue(_ meeting: Meeting, configuration: FolderExportConfiguration) async throws {
        guard
            configuration.isEnabled,
            !meeting.isActivelyRecording,
            !meeting.isDemo,
            contentIsReady(meeting, configuration: configuration)
        else { return }
        let markdown = MarkdownRenderer.render(
            meeting: meeting,
            includeNote: configuration.includeNote,
            includeTranscript: configuration.includeTranscript
        )
        let digest = exportDigest(markdown, configuration: configuration)
        let job = PendingFolderExport(
            meetingID: meeting.id,
            destinationID: configuration.destinationID,
            contentDigest: digest,
            createdAt: Date(),
            attemptCount: 0,
            nextAttemptAt: Date()
        )
        _ = try await persistence.enqueuePendingExportIfNeeded(job)
    }

    func enqueueAll(_ meetings: [Meeting], configuration: FolderExportConfiguration) async throws {
        for meeting in meetings {
            try await enqueue(meeting, configuration: configuration)
        }
    }

    func latestFailure(destinationID: UUID) async -> String? {
        await persistence.loadPendingExports()
            .filter { $0.destinationID == destinationID && $0.lastError != nil }
            .max(by: { $0.attemptCount < $1.attemptCount })?
            .lastError
    }

    func process(
        meetings: [Meeting],
        configuration: FolderExportConfiguration,
        now: Date = Date(),
        ignoreRetrySchedule: Bool = false
    ) async -> [FolderExportOutcome] {
        guard configuration.isEnabled else { return [] }
        guard !isProcessing else { return [] }
        isProcessing = true
        defer { isProcessing = false }

        let queue = await persistence.loadPendingExports()
        var outcomes: [FolderExportOutcome] = []
        let meetingLookup = Dictionary(uniqueKeysWithValues: meetings.map { ($0.id, $0) })

        for var job in queue {
            let queuedDigest = job.contentDigest
            guard
                job.destinationID == configuration.destinationID,
                ignoreRetrySchedule || job.nextAttemptAt <= now
            else {
                continue
            }
            guard
                let meeting = meetingLookup[job.meetingID],
                !meeting.isActivelyRecording,
                contentIsReady(meeting, configuration: configuration)
            else {
                continue
            }

            let markdown = MarkdownRenderer.render(
                meeting: meeting,
                includeNote: configuration.includeNote,
                includeTranscript: configuration.includeTranscript
            )
            let currentDigest = exportDigest(markdown, configuration: configuration)
            job.contentDigest = currentDigest

            do {
                let path = try write(
                    markdown: markdown,
                    filename: MarkdownRenderer.deterministicFilename(for: meeting),
                    configuration: configuration
                )
                let receipt = ExportReceipt(
                    key: job.key,
                    contentDigest: currentDigest,
                    relativePath: path,
                    exportedAt: now
                )
                try await persistence.completePendingExport(
                    job,
                    replacingDigest: queuedDigest,
                    receipt: receipt
                )
                outcomes.append(FolderExportOutcome(meetingID: meeting.id, relativePath: path))
            } catch {
                job.registerFailure(error, now: now)
                try? await persistence.registerPendingExportFailure(
                    job,
                    replacingDigest: queuedDigest
                )
            }
        }
        return outcomes
    }

    private func write(
        markdown: String,
        filename: String,
        configuration: FolderExportConfiguration
    ) throws -> String {
        var isStale = false
#if os(macOS)
        let resolutionOptions: URL.BookmarkResolutionOptions = [.withSecurityScope, .withoutUI]
#else
        let resolutionOptions: URL.BookmarkResolutionOptions = [.withoutUI]
#endif
        let folderURL = try URL(
            resolvingBookmarkData: configuration.bookmarkData,
            options: resolutionOptions,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        guard !isStale else {
            throw FolderExportError.staleBookmark
        }

        let didAccess = folderURL.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                folderURL.stopAccessingSecurityScopedResource()
            }
        }

        let components = try safeSubfolderComponents(configuration.subfolder)
        let destinationFolder = components.reduce(folderURL) { partial, component in
            partial.appendingPathComponent(component, isDirectory: true)
        }

        do {
            try FileManager.default.createDirectory(
                at: destinationFolder,
                withIntermediateDirectories: true
            )
        } catch {
            throw FolderExportError.destinationUnavailable
        }

        let targetURL = destinationFolder.appendingPathComponent(filename, isDirectory: false)
        let coordinator = NSFileCoordinator(filePresenter: nil)
        var coordinationError: NSError?
        var writeError: Error?
        coordinator.coordinate(writingItemAt: targetURL, options: [], error: &coordinationError) { coordinatedURL in
            do {
                try Data(markdown.utf8).write(to: coordinatedURL, options: .atomic)
            } catch {
                writeError = error
            }
        }

        if let coordinationError {
            throw FolderExportError.coordinationFailed(coordinationError)
        }
        if let writeError {
            throw FolderExportError.coordinationFailed(writeError)
        }

        return (components + [filename]).joined(separator: "/")
    }

    private func safeSubfolderComponents(_ subfolder: String) throws -> [String] {
        let components = subfolder
            .split(separator: "/", omittingEmptySubsequences: true)
            .map(String.init)
        guard components.allSatisfy({ $0 != "." && $0 != ".." && !$0.contains("\\") }) else {
            throw FolderExportError.invalidSubfolder
        }
        return components
    }

    private func contentIsReady(
        _ meeting: Meeting,
        configuration: FolderExportConfiguration
    ) -> Bool {
        if configuration.includeNote,
           (meeting.pipeline.note != .completed
               || meeting.noteMarkdown.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) {
            return false
        }
        if configuration.includeTranscript,
           (meeting.pipeline.transcription != .completed || meeting.transcript.isEmpty) {
            return false
        }
        return configuration.includeNote || configuration.includeTranscript
    }

    private func exportDigest(
        _ markdown: String,
        configuration: FolderExportConfiguration
    ) -> String {
        MarkdownRenderer.exportDigest(
            markdown: markdown,
            subfolder: configuration.subfolder,
            includeNote: configuration.includeNote,
            includeTranscript: configuration.includeTranscript
        )
    }
}
