import XCTest
@testable import NotedApp

final class TranscriptFormattingTests: XCTestCase {
    func testTimestampFormattingUsesMinutesUntilOneHour() {
        XCTAssertEqual(TranscriptTimestampFormatter.string(milliseconds: 0), "00:00")
        XCTAssertEqual(TranscriptTimestampFormatter.string(milliseconds: 65_999), "01:05")
        XCTAssertEqual(TranscriptTimestampFormatter.string(milliseconds: 3_661_000), "01:01:01")
    }

    func testNegativeTimestampIsClamped() {
        XCTAssertEqual(TranscriptTimestampFormatter.string(milliseconds: -1_000), "00:00")
    }

    func testDurationFormatting() {
        XCTAssertEqual(TranscriptTimestampFormatter.durationString(milliseconds: 59_000), "59s")
        XCTAssertEqual(TranscriptTimestampFormatter.durationString(milliseconds: 125_000), "2m 5s")
        XCTAssertEqual(TranscriptTimestampFormatter.durationString(milliseconds: 7_200_000), "2h 0m")
    }
}
