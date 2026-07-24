import CryptoKit
import Foundation

enum MarkdownRenderer {
    static func render(
        meeting: Meeting,
        includeNote: Bool = true,
        includeTranscript: Bool = true
    ) -> String {
        var lines: [String] = [
            "---",
            "noted_id: \(meeting.id.uuidString.lowercased())",
            "captured_at: \(iso8601.string(from: meeting.capturedAt))",
            "duration_seconds: \(meeting.durationMilliseconds / 1_000)",
            "---",
            "",
            "# \(meeting.noteTitle?.nilIfBlank ?? meeting.title)",
            ""
        ]

        if includeNote {
            lines += ["## Note", "", meeting.noteMarkdown.nilIfBlank ?? "_Note is not ready yet._", ""]
        }

        if includeTranscript {
            lines += ["## Transcript", ""]
            if meeting.transcript.isEmpty {
                lines += ["_Transcript is not ready yet._", ""]
            } else {
                for segment in meeting.transcript.sorted(by: { $0.sequence < $1.sequence }) {
                    let timestamp = TranscriptTimestampFormatter.string(milliseconds: segment.startMilliseconds)
                    lines += ["**[\(timestamp)] \(segment.speakerLabel)**", "", segment.text, ""]
                }
            }
        }

        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func deterministicFilename(for meeting: Meeting) -> String {
        let date = filenameDate.string(from: meeting.capturedAt)
        let slug = slugify(meeting.noteTitle?.nilIfBlank ?? meeting.title)
        let suffix = String(meeting.id.uuidString.lowercased().prefix(8))
        return "\(date)-\(slug)-\(suffix).md"
    }

    static func digest(_ content: String) -> String {
        SHA256.hash(data: Data(content.utf8))
            .map { String(format: "%02x", $0) }
            .joined()
    }

    static func exportDigest(
        markdown: String,
        subfolder: String,
        includeNote: Bool,
        includeTranscript: Bool
    ) -> String {
        digest(
            [
                "subfolder=\(subfolder)",
                "include-note=\(includeNote)",
                "include-transcript=\(includeTranscript)",
                markdown
            ].joined(separator: "\n")
        )
    }

    static func slugify(_ value: String) -> String {
        let folded = value
            .folding(options: [.diacriticInsensitive, .caseInsensitive], locale: Locale(identifier: "en_US_POSIX"))
            .lowercased()
        let allowed = folded.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(String(scalar))
            }
            return "-"
        }
        let compact = String(allowed)
            .split(separator: "-", omittingEmptySubsequences: true)
            .joined(separator: "-")
        return String((compact.isEmpty ? "recording" : compact).prefix(60))
    }

    private static let iso8601: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter
    }()

    private static let filenameDate: DateFormatter = {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .gregorian)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd-HHmm"
        return formatter
    }()
}

private extension String {
    var nilIfBlank: String? {
        trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self
    }
}
