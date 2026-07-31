import AVFoundation
import Foundation

final class MicrophoneLevelMonitor: NSObject, ObservableObject, @unchecked Sendable {
    @Published private(set) var level: Double = 0
    @Published private(set) var statusMessage: String?

    private let session = AVCaptureSession()
    private let sessionQueue = DispatchQueue(
        label: "app.minutemark.microphone-meter",
        qos: .userInitiated
    )
    private var selectedChannel = -1

    func start(deviceID: String, inputChannel: Int) {
        sessionQueue.async { [weak self] in
            self?.configureAndStart(
                deviceID: deviceID,
                inputChannel: inputChannel
            )
        }
    }

    func stop() {
        sessionQueue.async { [weak self] in
            guard let self else { return }
            if session.isRunning {
                session.stopRunning()
            }
            publish(level: 0, statusMessage: nil)
        }
    }

    private func configureAndStart(deviceID: String, inputChannel: Int) {
        if session.isRunning {
            session.stopRunning()
        }

        session.beginConfiguration()
        session.inputs.forEach(session.removeInput)
        session.outputs.forEach(session.removeOutput)

        guard let device = microphoneDevice(for: deviceID) else {
            session.commitConfiguration()
            publish(level: 0, statusMessage: "Microphone unavailable")
            return
        }

        do {
            let input = try AVCaptureDeviceInput(device: device)
            guard session.canAddInput(input) else {
                session.commitConfiguration()
                publish(level: 0, statusMessage: "Microphone unavailable")
                return
            }
            session.addInput(input)

            let output = AVCaptureAudioDataOutput()
            output.setSampleBufferDelegate(self, queue: sessionQueue)
            guard session.canAddOutput(output) else {
                session.commitConfiguration()
                publish(level: 0, statusMessage: "Audio meter unavailable")
                return
            }
            session.addOutput(output)
            selectedChannel = inputChannel
        } catch {
            session.commitConfiguration()
            publish(level: 0, statusMessage: error.localizedDescription)
            return
        }

        session.commitConfiguration()
        session.startRunning()
        publish(level: 0, statusMessage: nil)
    }

    private func microphoneDevice(for id: String) -> AVCaptureDevice? {
        guard !id.isEmpty else {
            return AVCaptureDevice.default(for: .audio)
        }
        return AVCaptureDevice(uniqueID: id)
    }

    private func publish(level: Double, statusMessage: String?) {
        DispatchQueue.main.async { [weak self] in
            self?.level = level
            self?.statusMessage = statusMessage
        }
    }
}

extension MicrophoneLevelMonitor: AVCaptureAudioDataOutputSampleBufferDelegate {
    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        let channels = connection.audioChannels
        guard !channels.isEmpty else { return }

        let decibels: Float
        if selectedChannel >= 0, channels.indices.contains(selectedChannel) {
            decibels = channels[selectedChannel].averagePowerLevel
        } else {
            decibels = channels.map(\.averagePowerLevel).max() ?? -160
        }

        // Map the useful speech range (-60...0 dBFS) to a readable meter.
        let normalized = min(1, max(0, (Double(decibels) + 60) / 60))
        publish(level: normalized, statusMessage: nil)
    }
}
