import Foundation

public enum TranscriptSpeaker: String, Sendable {
    case you = "You"
    case meeting = "Meeting"
}

public enum TranscriptFormatter {
    public static func header(title: String, startedAt: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd HH:mm"

        return """
        # \(title)

        Started \(formatter.string(from: startedAt))

        ## Transcript

        """
    }

    public static func line(
        speaker: TranscriptSpeaker,
        text: String,
        at date: Date,
        timeZone: TimeZone = .current
    ) -> String? {
        let cleaned = text
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !cleaned.isEmpty else { return nil }

        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "HH:mm:ss"
        return "- **\(formatter.string(from: date)) — \(speaker.rawValue):** \(cleaned)\n"
    }

    public static func filename(for date: Date, timeZone: TimeZone = .current) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd-HHmmss"
        return "Meeting-\(formatter.string(from: date)).md"
    }
}
