import AVFoundation
import Foundation

struct MicrophoneDevice: Identifiable, Hashable, Sendable {
    static let systemDefault = MicrophoneDevice(id: "", name: "System Default")

    let id: String
    let name: String

    static func available() -> [MicrophoneDevice] {
        let discovery = AVCaptureDevice.DiscoverySession(
            deviceTypes: [.microphone],
            mediaType: .audio,
            position: .unspecified
        )
        let devices = discovery.devices
            .map { MicrophoneDevice(id: $0.uniqueID, name: $0.localizedName) }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
        return [.systemDefault] + devices
    }
}
