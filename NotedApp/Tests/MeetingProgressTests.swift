import XCTest
@testable import NotedApp

final class MeetingProgressTests: XCTestCase {
    func testPipelineReportsEachImportantStage() {
        var meeting = Meeting(title: "Test")

        meeting.pipeline.upload = .queued
        XCTAssertEqual(meeting.progress, .waitingToUpload)

        meeting.pipeline.upload = .inProgress
        XCTAssertEqual(meeting.progress, .uploading)

        meeting.pipeline.upload = .completed
        meeting.pipeline.transcription = .inProgress
        XCTAssertEqual(meeting.progress, .transcribing)

        meeting.pipeline.transcription = .completed
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
        meeting.pipeline.upload = .failed
        meeting.pipeline.transcription = .queued
        meeting.pipeline.message = "Network unavailable"

        XCTAssertEqual(meeting.progress, .failed("Network unavailable"))
    }

    func testCloudStateDecoderIsTolerant() {
        XCTAssertEqual(WorkState(cloudValue: "processing"), .inProgress)
        XCTAssertEqual(WorkState(cloudValue: "ready"), .completed)
        XCTAssertEqual(WorkState(cloudValue: "unexpected-new-state"), .unknown)
        XCTAssertEqual(WorkState(cloudValue: nil), .notStarted)
    }
}
