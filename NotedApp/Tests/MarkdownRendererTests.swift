import Foundation
import XCTest
@testable import NotedApp

final class MarkdownRendererTests: XCTestCase {
    private let id = UUID(uuidString: "12345678-1234-4234-8234-123456789ABC")!

    func testCombinedMarkdownContainsStableMetadataNoteAndSegmentTimestamp() {
        let meeting = Meeting(
            id: id,
            title: "Weekly planning",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000),
            durationMilliseconds: 90_000,
            noteMarkdown: "## Decisions\n\nShip the MVP.",
            noteVersion: 1,
            transcript: [
                TranscriptSegment(
                    sequence: 0,
                    startMilliseconds: 65_000,
                    speakerLabel: "Speaker 1",
                    text: "Let’s ship."
                )
            ],
            pipeline: PipelineState(
                transcription: .completed,
                sync: .completed,
                note: .completed,
                export: .notStarted
            )
        )

        let markdown = MarkdownRenderer.render(meeting: meeting)

        XCTAssertTrue(markdown.contains("noted_id: 12345678-1234-4234-8234-123456789abc"))
        XCTAssertTrue(markdown.contains("## Note"))
        XCTAssertTrue(markdown.contains("Ship the MVP."))
        XCTAssertTrue(markdown.contains("**[01:05] Speaker 1**"))
        XCTAssertTrue(markdown.contains("Let’s ship."))
        XCTAssertTrue(markdown.hasSuffix("\n"))
    }

    func testFilenameIsDeterministicAndSafe() {
        let meeting = Meeting(
            id: id,
            title: "Café / Weekly: Sync!",
            capturedAt: Date(timeIntervalSince1970: 1_700_000_000)
        )

        let first = MarkdownRenderer.deterministicFilename(for: meeting)
        let second = MarkdownRenderer.deterministicFilename(for: meeting)

        XCTAssertEqual(first, second)
        XCTAssertTrue(first.contains("cafe-weekly-sync"))
        XCTAssertTrue(first.hasSuffix("-12345678.md"))
        XCTAssertFalse(first.contains("/"))
        XCTAssertFalse(first.contains(":"))
    }

    func testAppleTranscriptOmitsEmptySpeakerLabel() {
        let meeting = Meeting(
            id: id,
            title: "On-device transcript",
            transcript: [
                TranscriptSegment(
                    sequence: 0,
                    startMilliseconds: 5_000,
                    text: "Apple Speech result."
                )
            ]
        )

        let markdown = MarkdownRenderer.render(
            meeting: meeting,
            includeNote: false,
            includeTranscript: true
        )

        XCTAssertTrue(markdown.contains("**[00:05]**"))
        XCTAssertFalse(markdown.contains("Speaker"))
    }

    func testDigestChangesWhenContentChanges() {
        XCTAssertEqual(MarkdownRenderer.digest("same"), MarkdownRenderer.digest("same"))
        XCTAssertNotEqual(MarkdownRenderer.digest("before"), MarkdownRenderer.digest("after"))
    }

    func testExportDigestIncludesDestinationSettings() {
        let first = MarkdownRenderer.exportDigest(
            markdown: "same",
            subfolder: "Meetings",
            includeNote: true,
            includeTranscript: true
        )
        let moved = MarkdownRenderer.exportDigest(
            markdown: "same",
            subfolder: "Archive",
            includeNote: true,
            includeTranscript: true
        )

        XCTAssertNotEqual(first, moved)
    }
}
