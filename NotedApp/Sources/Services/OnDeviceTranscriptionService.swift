import AVFoundation
import Foundation
import Speech

enum OnDeviceTranscriptionError: LocalizedError {
    case audioMissing
    case localeUnsupported
    case emptyTranscript

    var errorDescription: String? {
        switch self {
        case .audioMissing:
            "The local recording could not be found."
        case .localeUnsupported:
            "Apple on-device transcription does not support this device language."
        case .emptyTranscript:
            "Apple on-device transcription did not find any speech in this recording."
        }
    }
}

actor OnDeviceTranscriptionService {
    private let preferredLocale: Locale

    init(preferredLocale: Locale = .current) {
        self.preferredLocale = preferredLocale
    }

    func prepareModel() async throws {
        let locale = try await resolvedLocale()
        let transcriber = makeTranscriber(locale: locale)
        try await ensureModel(for: transcriber, locale: locale)
    }

    func transcribe(fileURL: URL) async throws -> [TranscriptSegment] {
        guard FileManager.default.fileExists(atPath: fileURL.path) else {
            throw OnDeviceTranscriptionError.audioMissing
        }

        let locale = try await resolvedLocale()
        let transcriber = makeTranscriber(locale: locale)
        try await ensureModel(for: transcriber, locale: locale)

        let audioFile = try AVAudioFile(forReading: fileURL)
        async let segmentFuture = collectSegments(from: transcriber)
        let analyzer = SpeechAnalyzer(modules: [transcriber])
        if let lastSample = try await analyzer.analyzeSequence(from: audioFile) {
            try await analyzer.finalizeAndFinish(through: lastSample)
        } else {
            await analyzer.cancelAndFinishNow()
        }

        let segments = try await segmentFuture
        guard !segments.isEmpty else {
            throw OnDeviceTranscriptionError.emptyTranscript
        }
        return segments
    }

    private func makeTranscriber(locale: Locale) -> SpeechTranscriber {
        SpeechTranscriber(
            locale: locale,
            transcriptionOptions: [],
            reportingOptions: [],
            attributeOptions: [.audioTimeRange]
        )
    }

    private func collectSegments(
        from transcriber: SpeechTranscriber
    ) async throws -> [TranscriptSegment] {
        var segments: [TranscriptSegment] = []
        var fallbackStartMilliseconds = 0

        for try await result in transcriber.results where result.isFinal {
            let text = String(result.text.characters)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }

            let timeRange = result.text.audioTimeRange
            let startMilliseconds = timeRange.flatMap {
                Self.milliseconds(from: $0.start)
            } ?? fallbackStartMilliseconds
            let endMilliseconds = timeRange.flatMap {
                Self.milliseconds(from: CMTimeRangeGetEnd($0))
            }
            fallbackStartMilliseconds = endMilliseconds ?? startMilliseconds

            segments.append(
                TranscriptSegment(
                    id: String(format: "%06d", segments.count),
                    sequence: segments.count,
                    startMilliseconds: startMilliseconds,
                    endMilliseconds: endMilliseconds,
                    text: text
                )
            )
        }

        return segments
    }

    private func resolvedLocale() async throws -> Locale {
        let supported = await SpeechTranscriber.supportedLocales
        let preferredIdentifier = preferredLocale.identifier(.bcp47)
        if let exact = supported.first(where: {
            $0.identifier(.bcp47)
                .caseInsensitiveCompare(preferredIdentifier) == .orderedSame
        }) {
            return exact
        }

        let preferredLanguage = preferredIdentifier
            .split(separator: "-", maxSplits: 1)
            .first?
            .lowercased()
        if let languageMatch = supported.first(where: {
            $0.identifier(.bcp47)
                .split(separator: "-", maxSplits: 1)
                .first?
                .lowercased() == preferredLanguage
        }) {
            return languageMatch
        }

        if let englishFallback = supported.first(where: {
            $0.identifier(.bcp47).caseInsensitiveCompare("en-GB") == .orderedSame
        }) {
            return englishFallback
        }

        throw OnDeviceTranscriptionError.localeUnsupported
    }

    private func ensureModel(
        for transcriber: SpeechTranscriber,
        locale: Locale
    ) async throws {
        let identifier = locale.identifier(.bcp47)
        let installed = await SpeechTranscriber.installedLocales
        if installed.contains(where: {
            $0.identifier(.bcp47).caseInsensitiveCompare(identifier) == .orderedSame
        }) {
            return
        }

        if let request = try await AssetInventory.assetInstallationRequest(
            supporting: [transcriber]
        ) {
            try await request.downloadAndInstall()
        }
    }

    private static func milliseconds(from time: CMTime) -> Int? {
        let seconds = CMTimeGetSeconds(time)
        guard seconds.isFinite else { return nil }
        return max(0, Int((seconds * 1_000).rounded()))
    }
}
