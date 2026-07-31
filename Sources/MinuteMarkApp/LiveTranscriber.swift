@preconcurrency import AVFoundation
import Foundation
import MinuteMarkCore
import Speech

struct TranscriptionUpdate: Sendable {
    let speaker: TranscriptSpeaker
    let text: String
    let isFinal: Bool
}

actor LiveTranscriber {
    typealias ResultHandler = @Sendable (TranscriptionUpdate) async -> Void
    typealias ErrorHandler = @Sendable (String) -> Void
    typealias DiagnosticsHandler = @Sendable (String) -> Void
    typealias DownloadProgressHandler = @Sendable (Double) -> Void

    private var analyzer: SpeechAnalyzer?
    private var inputContinuation: AsyncStream<AnalyzerInput>.Continuation?
    private var analysisTask: Task<Void, Never>?
    private var resultsTask: Task<Void, Never>?
    private var converter: AVAudioConverter?
    private var automaticConverters: [AVAudioConverter] = []
    private var automaticSelectedChannel = 0
    private var targetFormat: AVAudioFormat?
    private var speaker: TranscriptSpeaker?
    private var inputChannel: Int?
    private var onError: ErrorHandler?
    private var onDiagnostics: DiagnosticsHandler?
    private var receivedBufferCount = 0
    private var yieldedInputCount = 0
    private var reportedConversionFailure = false
    private var reportedFormats = false
    private var inputPeakDBFS = -Double.infinity
    private var measuredInputPeak = false

    func start(
        localeIdentifier: String,
        speaker: TranscriptSpeaker,
        inputChannel: Int?,
        onResult: @escaping ResultHandler,
        onError: @escaping ErrorHandler,
        onDiagnostics: @escaping DiagnosticsHandler,
        onDownloadProgress: @escaping DownloadProgressHandler
    ) async throws {
        guard SpeechTranscriber.isAvailable else {
            throw TranscriptionError.unavailable
        }

        let requestedLocale = Locale(identifier: localeIdentifier)
        guard let locale = await SpeechTranscriber.supportedLocale(equivalentTo: requestedLocale) else {
            throw TranscriptionError.unsupportedLanguage(localeIdentifier)
        }

        let transcriber = SpeechTranscriber(
            locale: locale,
            preset: .progressiveTranscription
        )
        let modules: [any SpeechModule] = [transcriber]
        let status = await AssetInventory.status(forModules: modules)
        if status != .installed {
            guard let request = try await AssetInventory.assetInstallationRequest(
                supporting: modules
            ) else {
                throw TranscriptionError.modelUnavailable(localeIdentifier)
            }
            let progressTask = Task {
                while !Task.isCancelled {
                    onDownloadProgress(request.progress.fractionCompleted)
                    try? await Task.sleep(for: .milliseconds(200))
                }
            }
            defer { progressTask.cancel() }
            try await request.downloadAndInstall()
            onDownloadProgress(1)
        }
        _ = try await AssetInventory.reserve(locale: locale)

        guard let format = await SpeechAnalyzer.bestAvailableAudioFormat(
            compatibleWith: modules
        ) else {
            throw TranscriptionError.noAudioFormat
        }

        let (stream, continuation) = AsyncStream<AnalyzerInput>.makeStream()
        let analyzer = SpeechAnalyzer(modules: modules)
        try await analyzer.prepareToAnalyze(in: format)

        self.analyzer = analyzer
        self.speaker = speaker
        self.inputChannel = inputChannel
        self.onError = onError
        self.onDiagnostics = onDiagnostics
        targetFormat = format
        inputContinuation = continuation

        analysisTask = Task {
            do {
                let lastSampleTime = try await analyzer.analyzeSequence(stream)
                if let lastSampleTime {
                    try await analyzer.finalizeAndFinish(through: lastSampleTime)
                } else {
                    await analyzer.cancelAndFinishNow()
                }
            } catch {
                onError("\(speaker.rawValue) analyzer failed: \(error.localizedDescription)")
            }
        }

        resultsTask = Task {
            do {
                for try await result in transcriber.results {
                    let text = String(result.text.characters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !text.isEmpty else { continue }
                    await onResult(
                        TranscriptionUpdate(
                            speaker: speaker,
                            text: text,
                            isFinal: result.isFinal
                        )
                    )
                }
            } catch {
                onError("\(speaker.rawValue) results failed: \(error.localizedDescription)")
            }
        }
    }

    func consume(_ packet: AudioCapture.BufferPacket) {
        let input = packet.buffer
        guard let targetFormat, let inputContinuation else { return }
        receivedBufferCount += 1
        if let peak = input.peakDBFS {
            measuredInputPeak = true
            inputPeakDBFS = max(inputPeakDBFS, peak)
        }

        if !reportedFormats, let speaker {
            reportedFormats = true
            onDiagnostics?(
                "\(speaker.rawValue) format — source \(Int(input.format.sampleRate)) Hz/\(input.format.channelCount) ch format=\(input.format.commonFormat.rawValue) interleaved=\(input.format.isInterleaved), analyzer \(Int(targetFormat.sampleRate)) Hz/\(targetFormat.channelCount) ch"
            )
        }

        if input.format == targetFormat {
            inputContinuation.yield(AnalyzerInput(buffer: input))
            yieldedInputCount += 1
            reportProgressIfNeeded()
            return
        }

        if inputChannel == -1, input.format.channelCount > 1 {
            consumeAutomatically(
                input,
                targetFormat: targetFormat,
                continuation: inputContinuation
            )
            return
        }

        if converter == nil || converter?.inputFormat != input.format {
            converter = AVAudioConverter(from: input.format, to: targetFormat)
            if let inputChannel,
               inputChannel < Int(input.format.channelCount),
               targetFormat.channelCount == 1 {
                converter?.channelMap = [NSNumber(value: inputChannel)]
                onDiagnostics?(
                    "\(speaker?.rawValue ?? "Audio") routing — input \(inputChannel + 1) to analyzer mono"
                )
            }
        }
        guard let converter else {
            reportConversionFailure("could not create an audio converter")
            return
        }

        let conversion = convert(input, with: converter, to: targetFormat)
        if let output = conversion.buffer {
            inputContinuation.yield(AnalyzerInput(buffer: output))
            yieldedInputCount += 1
            reportProgressIfNeeded()
        } else if let error = conversion.error {
            reportConversionFailure(error.localizedDescription)
        }
    }

    private func consumeAutomatically(
        _ input: AVAudioPCMBuffer,
        targetFormat: AVAudioFormat,
        continuation: AsyncStream<AnalyzerInput>.Continuation
    ) {
        let channelCount = Int(input.format.channelCount)
        if automaticConverters.count != channelCount ||
            automaticConverters.first?.inputFormat != input.format {
            automaticConverters = (0..<channelCount).compactMap { channel in
                guard let converter = AVAudioConverter(
                    from: input.format,
                    to: targetFormat
                ) else {
                    return nil
                }
                converter.channelMap = [NSNumber(value: channel)]
                return converter
            }
            automaticSelectedChannel = min(automaticSelectedChannel, channelCount - 1)
            onDiagnostics?(
                "\(speaker?.rawValue ?? "Audio") routing — automatic across \(channelCount) inputs"
            )
        }

        guard automaticConverters.count == channelCount else {
            reportConversionFailure("could not create automatic channel converters")
            return
        }

        let conversions = automaticConverters.map {
            convert(input, with: $0, to: targetFormat)
        }
        let levels = conversions.map {
            $0.buffer?.peakDBFS ?? -Double.infinity
        }
        guard let loudestChannel = levels.indices.max(by: {
            levels[$0] < levels[$1]
        }) else {
            return
        }

        let currentLevel = levels[automaticSelectedChannel]
        let loudestLevel = levels[loudestChannel]
        if loudestChannel != automaticSelectedChannel,
           loudestLevel > currentLevel + 6 {
            automaticSelectedChannel = loudestChannel
            onDiagnostics?(
                "\(speaker?.rawValue ?? "Audio") routing — selected input \(loudestChannel + 1) at \(String(format: "%.1f", loudestLevel)) dBFS"
            )
        }

        if let output = conversions[automaticSelectedChannel].buffer {
            continuation.yield(AnalyzerInput(buffer: output))
            yieldedInputCount += 1
            reportProgressIfNeeded()
        } else if let error = conversions[automaticSelectedChannel].error {
            reportConversionFailure(error.localizedDescription)
        }
    }

    private func convert(
        _ input: AVAudioPCMBuffer,
        with converter: AVAudioConverter,
        to targetFormat: AVAudioFormat
    ) -> (buffer: AVAudioPCMBuffer?, error: NSError?) {
        let ratio = targetFormat.sampleRate / input.format.sampleRate
        let capacity = AVAudioFrameCount((Double(input.frameLength) * ratio).rounded(.up)) + 1
        guard let output = AVAudioPCMBuffer(
            pcmFormat: targetFormat,
            frameCapacity: capacity
        ) else {
            return (
                nil,
                NSError(
                    domain: "MinuteMark.AudioConversion",
                    code: 1,
                    userInfo: [
                        NSLocalizedDescriptionKey: "Could not allocate a converted audio buffer."
                    ]
                )
            )
        }

        var conversionError: NSError?
        let source = ConverterInputSource(buffer: input)
        let status = converter.convert(to: output, error: &conversionError) { _, outStatus in
            source.next(status: outStatus)
        }

        guard status != .error, output.frameLength > 0 else {
            return (nil, conversionError)
        }
        return (output, nil)
    }

    private func reportProgressIfNeeded() {
        guard yieldedInputCount == 1 || yieldedInputCount.isMultiple(of: 50),
              let speaker
        else {
            return
        }
        onDiagnostics?(
            "\(speaker.rawValue) analyzer — received \(receivedBufferCount), submitted \(yieldedInputCount), peak \(formattedPeak) dBFS"
        )
        inputPeakDBFS = -Double.infinity
        measuredInputPeak = false
    }

    private var formattedPeak: String {
        guard measuredInputPeak else { return "n/a" }
        return inputPeakDBFS.isFinite ? String(format: "%.1f", inputPeakDBFS) : "-∞"
    }

    private func reportConversionFailure(_ reason: String) {
        guard !reportedConversionFailure else { return }
        reportedConversionFailure = true
        onError?("\(speaker?.rawValue ?? "Audio") conversion failed: \(reason)")
    }

    func stop() async {
        inputContinuation?.finish()
        _ = await analysisTask?.result
        _ = await resultsTask?.result
        analysisTask = nil
        resultsTask = nil
        inputContinuation = nil
        analyzer = nil
        converter = nil
        automaticConverters = []
        automaticSelectedChannel = 0
        targetFormat = nil
        speaker = nil
        inputChannel = nil
        onError = nil
        onDiagnostics = nil
        receivedBufferCount = 0
        yieldedInputCount = 0
        reportedConversionFailure = false
        reportedFormats = false
        inputPeakDBFS = -Double.infinity
        measuredInputPeak = false
    }
}

private extension AVAudioPCMBuffer {
    var peakDBFS: Double? {
        guard frameLength > 0 else { return nil }
        let frameCount = Int(frameLength)
        let channelCount = Int(format.channelCount)
        var peak: Double = 0

        switch format.commonFormat {
        case .pcmFormatFloat32:
            guard let channels = floatChannelData else { return nil }
            if format.isInterleaved {
                for sample in 0..<(frameCount * channelCount) {
                    peak = max(peak, Double(abs(channels[0][sample])))
                }
            } else {
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        peak = max(peak, Double(abs(channels[channel][frame])))
                    }
                }
            }
        case .pcmFormatFloat64:
            return nil
        case .pcmFormatInt16:
            guard let channels = int16ChannelData else { return nil }
            if format.isInterleaved {
                for sample in 0..<(frameCount * channelCount) {
                    peak = max(peak, Double(abs(Int(channels[0][sample]))) / 32_768)
                }
            } else {
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        peak = max(peak, Double(abs(Int(channels[channel][frame]))) / 32_768)
                    }
                }
            }
        case .pcmFormatInt32:
            guard let channels = int32ChannelData else { return nil }
            if format.isInterleaved {
                for sample in 0..<(frameCount * channelCount) {
                    peak = max(peak, Double(abs(Int64(channels[0][sample]))) / 2_147_483_648)
                }
            } else {
                for channel in 0..<channelCount {
                    for frame in 0..<frameCount {
                        peak = max(peak, Double(abs(Int64(channels[channel][frame]))) / 2_147_483_648)
                    }
                }
            }
        default:
            return nil
        }

        guard peak > 0 else { return -Double.infinity }
        return 20 * log10(peak)
    }
}

private final class ConverterInputSource: @unchecked Sendable {
    private let lock = NSLock()
    private let buffer: AVAudioPCMBuffer
    private var supplied = false

    init(buffer: AVAudioPCMBuffer) {
        self.buffer = buffer
    }

    func next(status: UnsafeMutablePointer<AVAudioConverterInputStatus>) -> AVAudioBuffer? {
        lock.lock()
        defer { lock.unlock() }

        guard !supplied else {
            status.pointee = .noDataNow
            return nil
        }
        supplied = true
        status.pointee = .haveData
        return buffer
    }
}

enum TranscriptionError: LocalizedError {
    case unavailable
    case unsupportedLanguage(String)
    case modelUnavailable(String)
    case noAudioFormat

    var errorDescription: String? {
        switch self {
        case .unavailable:
            "On-device transcription is unavailable on this Mac."
        case .unsupportedLanguage(let locale):
            "The on-device speech model does not support \(locale)."
        case .modelUnavailable(let locale):
            "The \(locale) speech model could not be downloaded."
        case .noAudioFormat:
            "The speech model did not provide a compatible audio format."
        }
    }
}
