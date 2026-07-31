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
    #expect(
        TranscriptFormatter.filename(
            title: "Q3 / Product: Planning?",
            for: date,
            timeZone: utc
        ) == "1970-01-01_000000_Q3-Product-Planning.md"
    )
}

@Test func usesReadableHeaderAndFallbackTitle() {
    let date = Date(timeIntervalSince1970: 0)
    let utc = TimeZone(secondsFromGMT: 0)!
    let header = TranscriptFormatter.header(
        title: "  ",
        startedAt: date,
        timeZone: utc
    )

    #expect(header.contains("# Untitled Meeting"))
    #expect(header.contains("**01 Jan 1970 · 00:00**"))
}
