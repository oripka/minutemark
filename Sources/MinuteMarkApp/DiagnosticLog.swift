import Foundation

final class DiagnosticLog: @unchecked Sendable {
    let fileURL: URL

    private let lock = NSLock()
    private var handle: FileHandle?

    init(transcriptURL: URL) throws {
        fileURL = transcriptURL
            .deletingPathExtension()
            .appendingPathExtension("diagnostics.log")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        handle = try FileHandle(forWritingTo: fileURL)
        append("MinuteMark diagnostics started")
    }

    func append(_ message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let handle else { return }

        let timestamp = Date.now.formatted(
            .iso8601
                .year()
                .month()
                .day()
                .dateSeparator(.dash)
                .time(includingFractionalSeconds: true)
                .timeZone(separator: .colon)
        )
        let line = "\(timestamp) \(message)\n"
        do {
            try handle.write(contentsOf: Data(line.utf8))
            try handle.synchronize()
        } catch {
            // Diagnostics must never interrupt the transcription itself.
        }
    }

    func close() {
        lock.lock()
        defer { lock.unlock() }
        try? handle?.synchronize()
        try? handle?.close()
        handle = nil
    }
}
