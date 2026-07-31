import Foundation

public actor TranscriptWriter {
    public let fileURL: URL
    private let handle: FileHandle

    public init(directory: URL, startedAt: Date = Date()) throws {
        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )

        fileURL = directory.appendingPathComponent(
            TranscriptFormatter.filename(for: startedAt)
        )

        let header = TranscriptFormatter.header(
            title: "Meeting — \(startedAt.formatted(date: .abbreviated, time: .shortened))",
            startedAt: startedAt
        )
        try Data(header.utf8).write(to: fileURL, options: .atomic)
        handle = try FileHandle(forWritingTo: fileURL)
        try handle.seekToEnd()
    }

    deinit {
        try? handle.close()
    }

    public func append(speaker: TranscriptSpeaker, text: String, at date: Date = Date()) throws {
        guard let line = TranscriptFormatter.line(speaker: speaker, text: text, at: date) else {
            return
        }
        try handle.write(contentsOf: Data(line.utf8))
        try handle.synchronize()
    }

    public func close() throws {
        try handle.synchronize()
        try handle.close()
    }
}
