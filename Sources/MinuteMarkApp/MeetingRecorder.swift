import Foundation
import MinuteMarkCore

@MainActor
final class MeetingRecorder {
    typealias ResultHandler = @Sendable (TranscriptionUpdate) -> Void
    typealias ErrorHandler = @Sendable (String) -> Void
    typealias DiagnosticsHandler = @Sendable (String) -> Void

    private let microphoneTranscriber = LiveTranscriber()
    private let meetingTranscriber = LiveTranscriber()
    private var capture: AudioCapture?
    private var writer: TranscriptWriter?
    private var diagnosticLog: DiagnosticLog?

    func start(
        localeIdentifier: String,
        microphoneDeviceID: String,
        microphoneInputChannel: Int,
        outputDirectory: URL,
        onResult: @escaping ResultHandler,
        onError: @escaping ErrorHandler,
        onDiagnostics: @escaping DiagnosticsHandler
    ) async throws -> URL {
        let writer = try TranscriptWriter(directory: outputDirectory)
        self.writer = writer
        let transcriptURL = await writer.fileURL
        let diagnosticLog = try DiagnosticLog(transcriptURL: transcriptURL)
        self.diagnosticLog = diagnosticLog
        diagnosticLog.append(
            "Configuration locale=\(localeIdentifier) microphone=\(microphoneDeviceID.isEmpty ? "system-default" : microphoneDeviceID) inputChannel=\(microphoneInputChannel < 0 ? "automatic" : String(microphoneInputChannel + 1))"
        )

        let resultSink: LiveTranscriber.ResultHandler = { update in
            diagnosticLog.append(
                "RESULT speaker=\(update.speaker.rawValue) final=\(update.isFinal) text=\(update.text)"
            )
            if update.isFinal {
                try? await writer.append(
                    speaker: update.speaker,
                    text: update.text
                )
            }
            onResult(update)
        }
        let errorSink: ErrorHandler = { message in
            diagnosticLog.append("ERROR \(message)")
            onError(message)
        }
        let diagnosticsSink: DiagnosticsHandler = { message in
            diagnosticLog.append(message)
            onDiagnostics(message)
        }

        do {
            diagnosticLog.append("Preparing microphone transcriber")
            try await microphoneTranscriber.start(
                localeIdentifier: localeIdentifier,
                speaker: .you,
                inputChannel: microphoneInputChannel,
                onResult: resultSink,
                onError: errorSink,
                onDiagnostics: diagnosticsSink
            )
            diagnosticLog.append("Microphone transcriber ready")
            diagnosticLog.append("Preparing meeting transcriber")
            try await meetingTranscriber.start(
                localeIdentifier: localeIdentifier,
                speaker: .meeting,
                inputChannel: nil,
                onResult: resultSink,
                onError: errorSink,
                onDiagnostics: diagnosticsSink
            )
            diagnosticLog.append("Meeting transcriber ready")

            let capture = AudioCapture(
                microphoneDeviceID: microphoneDeviceID,
                onMicrophoneBuffer: { [microphoneTranscriber] buffer in
                    Task { await microphoneTranscriber.consume(buffer) }
                },
                onSystemBuffer: { [meetingTranscriber] buffer in
                    Task { await meetingTranscriber.consume(buffer) }
                },
                onError: errorSink,
                onDiagnostics: diagnosticsSink
            )
            diagnosticLog.append("Starting ScreenCaptureKit stream")
            try await capture.start()
            diagnosticLog.append("ScreenCaptureKit stream started")
            self.capture = capture
            return transcriptURL
        } catch {
            diagnosticLog.append("START FAILED \(error.localizedDescription)")
            await microphoneTranscriber.stop()
            await meetingTranscriber.stop()
            try? await writer.close()
            diagnosticLog.close()
            self.diagnosticLog = nil
            self.writer = nil
            throw error
        }
    }

    func stop() async {
        diagnosticLog?.append("Stop requested")
        await capture?.stop()
        capture = nil
        await microphoneTranscriber.stop()
        await meetingTranscriber.stop()
        try? await writer?.close()
        diagnosticLog?.append("Transcription stopped")
        diagnosticLog?.close()
        diagnosticLog = nil
        writer = nil
    }
}
