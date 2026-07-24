import Foundation
import XCTest
@testable import NotedApp

final class MeetingProgressTests: XCTestCase {
    func testPipelineReportsEachImportantStage() {
        var meeting = Meeting(title: "Test")

        meeting.pipeline.transcription = .inProgress
        XCTAssertEqual(meeting.progress, .transcribing)

        meeting.pipeline.transcription = .completed
        meeting.pipeline.sync = .queued
        XCTAssertEqual(meeting.progress, .waitingToSync)

        meeting.pipeline.sync = .inProgress
        XCTAssertEqual(meeting.progress, .syncing)

        meeting.pipeline.sync = .completed
        meeting.pipeline.note = .inProgress
        XCTAssertEqual(meeting.progress, .generatingNote)

        meeting.noteMarkdown = "A generated note"
        meeting.transcript = [
            TranscriptSegment(sequence: 0, startMilliseconds: 0, text: "Transcript")
        ]
        meeting.pipeline.note = .completed
        XCTAssertEqual(meeting.progress, .ready)
    }

    func testFailureTakesPriorityOverQueuedWork() {
        var meeting = Meeting(title: "Test")
        meeting.pipeline.transcription = .completed
        meeting.pipeline.sync = .failed
        meeting.pipeline.message = "Network unavailable"

        XCTAssertEqual(meeting.progress, .failed("Network unavailable"))
    }

    func testCloudStateDecoderIsTolerant() {
        XCTAssertEqual(WorkState(cloudValue: "processing"), .inProgress)
        XCTAssertEqual(WorkState(cloudValue: "ready"), .completed)
        XCTAssertEqual(WorkState(cloudValue: "unexpected-new-state"), .unknown)
        XCTAssertEqual(WorkState(cloudValue: nil), .notStarted)
    }

    func testLegacyUploadStateMigratesToSyncState() throws {
        let data = Data(
            """
            {
              "upload": "completed",
              "transcription": "completed",
              "note": "queued",
              "export": "notStarted"
            }
            """.utf8
        )

        let pipeline = try JSONDecoder().decode(PipelineState.self, from: data)

        XCTAssertEqual(pipeline.sync, .completed)
        XCTAssertEqual(pipeline.transcription, .completed)
        XCTAssertEqual(pipeline.note, .queued)
    }
}
