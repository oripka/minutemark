import AVFoundation
import CoreGraphics
import CoreMedia
import Foundation
import ScreenCaptureKit

final class AudioCapture: NSObject, SCStreamOutput, SCStreamDelegate, @unchecked Sendable {
    struct BufferPacket: @unchecked Sendable {
        let buffer: AVAudioPCMBuffer
    }

    typealias BufferHandler = @Sendable (BufferPacket) -> Void
    typealias ErrorHandler = @Sendable (String) -> Void
    typealias DiagnosticsHandler = @Sendable (String) -> Void

    private let microphoneDeviceID: String
    private let onMicrophoneBuffer: BufferHandler
    private let onSystemBuffer: BufferHandler
    private let onError: ErrorHandler
    private let onDiagnostics: DiagnosticsHandler
    private let sampleQueue = DispatchQueue(label: "app.minutemark.capture", qos: .userInitiated)
    private var stream: SCStream?
    private var microphoneBufferCount = 0
    private var systemBufferCount = 0
    private var reportedDecodeFailure = false

    init(
        microphoneDeviceID: String,
        onMicrophoneBuffer: @escaping BufferHandler,
        onSystemBuffer: @escaping BufferHandler,
        onError: @escaping ErrorHandler,
        onDiagnostics: @escaping DiagnosticsHandler
    ) {
        self.microphoneDeviceID = microphoneDeviceID
        self.onMicrophoneBuffer = onMicrophoneBuffer
        self.onSystemBuffer = onSystemBuffer
        self.onError = onError
        self.onDiagnostics = onDiagnostics
        super.init()
    }

    func start() async throws {
        guard CGPreflightScreenCaptureAccess() else {
            CGRequestScreenCaptureAccess()
            throw CaptureError.screenRecordingPermission
        }

        let content = try await SCShareableContent.excludingDesktopWindows(
            false,
            onScreenWindowsOnly: true
        )
        guard let display = content.displays.first else {
            throw CaptureError.noDisplay
        }

        let ownBundleID = Bundle.main.bundleIdentifier
        let excludedApps = content.applications.filter {
            $0.bundleIdentifier == ownBundleID
        }
        let filter = SCContentFilter(
            display: display,
            excludingApplications: excludedApps,
            exceptingWindows: []
        )

        let configuration = SCStreamConfiguration()
        configuration.width = 2
        configuration.height = 2
        configuration.minimumFrameInterval = CMTime(value: 1, timescale: 1)
        configuration.showsCursor = false
        configuration.capturesAudio = true
        configuration.captureMicrophone = true
        if !microphoneDeviceID.isEmpty {
            configuration.microphoneCaptureDeviceID = microphoneDeviceID
        }
        configuration.excludesCurrentProcessAudio = true
        configuration.sampleRate = 48_000
        configuration.channelCount = 1
        configuration.queueDepth = 3

        let stream = SCStream(filter: filter, configuration: configuration, delegate: self)
        try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: sampleQueue)
        try stream.addStreamOutput(self, type: .microphone, sampleHandlerQueue: sampleQueue)
        try await stream.startCapture()
        self.stream = stream
    }

    func stop() async {
        guard let stream else { return }
        try? await stream.stopCapture()
        self.stream = nil
    }

    func stream(
        _ stream: SCStream,
        didOutputSampleBuffer sampleBuffer: CMSampleBuffer,
        of outputType: SCStreamOutputType
    ) {
        guard sampleBuffer.isValid,
              CMSampleBufferDataIsReady(sampleBuffer)
        else {
            return
        }
        guard let buffer = sampleBuffer.audioPCMBuffer else {
            if !reportedDecodeFailure {
                reportedDecodeFailure = true
                onError("ScreenCaptureKit delivered audio that could not be decoded.")
            }
            return
        }

        switch outputType {
        case .audio:
            systemBufferCount += 1
            onSystemBuffer(BufferPacket(buffer: buffer))
        case .microphone:
            microphoneBufferCount += 1
            onMicrophoneBuffer(BufferPacket(buffer: buffer))
        default:
            break
        }

        let total = microphoneBufferCount + systemBufferCount
        if total == 1 || total.isMultiple(of: 50) {
            onDiagnostics(
                "Capture — mic \(microphoneBufferCount), system \(systemBufferCount) buffers"
            )
        }
    }

    func stream(_ stream: SCStream, didStopWithError error: any Error) {
        onError("Audio capture stopped: \(error.localizedDescription)")
    }
}

enum CaptureError: LocalizedError, Equatable {
    case noDisplay
    case screenRecordingPermission

    var errorDescription: String? {
        switch self {
        case .noDisplay:
            "No display is available for system-audio capture."
        case .screenRecordingPermission:
            "Allow MinuteMark under Screen & System Audio Recording, then quit and reopen the app."
        }
    }
}

private extension CMSampleBuffer {
    var audioPCMBuffer: AVAudioPCMBuffer? {
        guard let formatDescription = formatDescription else {
            return nil
        }
        let format = AVAudioFormat(cmAudioFormatDescription: formatDescription)

        let frames = AVAudioFrameCount(numSamples)
        guard frames > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: frames)
        else {
            return nil
        }

        buffer.frameLength = frames
        let status = CMSampleBufferCopyPCMDataIntoAudioBufferList(
            self,
            at: 0,
            frameCount: Int32(frames),
            into: buffer.mutableAudioBufferList
        )
        return status == noErr ? buffer : nil
    }
}
