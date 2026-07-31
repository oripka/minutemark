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
        formatter.dateFormat = "dd MMM yyyy · HH:mm"

        return """
        # \(normalizedTitle(title))

        **\(formatter.string(from: startedAt))**

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

    public static func filename(
        title: String,
        for date: Date,
        timeZone: TimeZone = .current
    ) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = timeZone
        formatter.dateFormat = "yyyy-MM-dd_HHmmss"
        return "\(formatter.string(from: date))_\(safeFilenameTitle(title)).md"
    }

    public static func normalizedTitle(_ title: String) -> String {
        let cleaned = title
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty ? "Untitled Meeting" : cleaned
    }

    public static func safeFilenameTitle(_ title: String) -> String {
        let title = normalizedTitle(title)
        let allowed = CharacterSet.alphanumerics
        var result = ""
        var needsSeparator = false

        for character in title {
            let isAllowed = character.unicodeScalars.allSatisfy {
                allowed.contains($0)
            }
            if isAllowed {
                if needsSeparator, !result.isEmpty {
                    result.append("-")
                }
                result.append(character)
                needsSeparator = false
            } else {
                needsSeparator = true
            }
        }

        let shortened = String(result.prefix(64))
            .trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return shortened.isEmpty ? "Untitled-Meeting" : shortened
    }
}
