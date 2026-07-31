import Foundation
import Testing
@testable import MinuteMarkCore

@Test func formatsTranscriptLineAndCollapsesWhitespace() {
    let date = Date(timeIntervalSince1970: 12 * 60 * 60 + 34 * 60 + 56)
    let utc = TimeZone(secondsFromGMT: 0)!

    let line = TranscriptFormatter.line(
        speaker: .you,
        text: "  Hello   aus\nBerlin. ",
        at: date,
        timeZone: utc
    )

    #expect(line == "- **12:34:56 — You:** Hello aus Berlin.\n")
}

@Test func ignoresBlankResults() {
    #expect(
        TranscriptFormatter.line(
            speaker: .meeting,
            text: " \n ",
            at: Date()
        ) == nil
    )
}

@Test func createsSortableFilename() {
    let date = Date(timeIntervalSince1970: 0)
    let utc = TimeZone(secondsFromGMT: 0)!
    #expect(TranscriptFormatter.filename(for: date, timeZone: utc) == "Meeting-1970-01-01-000000.md")
}
