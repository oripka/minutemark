import AppKit
import Combine
import Foundation
import MinuteMarkCore
import ServiceManagement

enum MeetingLanguage: String, CaseIterable, Identifiable {
    case english = "en-US"
    case german = "de-DE"

    var id: String { rawValue }
    var label: String {
        switch self {
        case .english: "English"
        case .german: "Deutsch"
        }
    }
}

enum MicrophoneInputChannel: Int, CaseIterable, Identifiable {
    case automatic = -1
    case input1 = 0
    case input2 = 1

    var id: Int { rawValue }
    var label: String {
        switch self {
        case .automatic: "Automatic"
        case .input1: "Input 1"
        case .input2: "Input 2"
        }
    }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var language: MeetingLanguage = .english
    @Published var transcriptTitle = ""
    @Published var outputDirectory: URL
    @Published var selectedMicrophoneID: String {
        didSet {
            UserDefaults.standard.set(selectedMicrophoneID, forKey: "microphoneDeviceID")
        }
    }
    @Published var microphoneInputChannel: MicrophoneInputChannel {
        didSet {
            UserDefaults.standard.set(
                microphoneInputChannel.rawValue,
                forKey: "microphoneInputChannelMode"
            )
        }
    }
    @Published private(set) var microphones: [MicrophoneDevice] = []
    @Published private(set) var isRecording = false
    @Published private(set) var isBusy = false
    @Published private(set) var status = "Ready"
    @Published private(set) var latestLine: String?
    @Published private(set) var transcriptURL: URL?
    @Published private(set) var errorMessage: String?
    @Published private(set) var needsScreenPermission = false
    @Published private(set) var pipelineStatus: String?
    @Published private(set) var launchAtLoginEnabled = false
    @Published private(set) var launchAtLoginError: String?

    private var recorder: MeetingRecorder?

    init() {
        selectedMicrophoneID = UserDefaults.standard.string(
            forKey: "microphoneDeviceID"
        ) ?? ""
        microphoneInputChannel = MicrophoneInputChannel(
            rawValue: UserDefaults.standard.object(forKey: "microphoneInputChannelMode") as? Int ?? -1
        ) ?? .automatic
        if let savedPath = UserDefaults.standard.string(forKey: "outputDirectory") {
            outputDirectory = URL(fileURLWithPath: savedPath, isDirectory: true)
        } else {
            outputDirectory = FileManager.default.homeDirectoryForCurrentUser
                .appending(path: "Documents/Meeting Notes", directoryHint: .isDirectory)
        }
        refreshLaunchAtLoginStatus()
        refreshMicrophones()
    }

    func setLaunchAtLogin(_ enabled: Bool) {
        launchAtLoginError = nil
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            launchAtLoginError = error.localizedDescription
        }
        refreshLaunchAtLoginStatus()
    }

    func clearLaunchAtLoginError() {
        launchAtLoginError = nil
    }

    func refreshMicrophones() {
        microphones = MicrophoneDevice.available()
        if !microphones.contains(where: { $0.id == selectedMicrophoneID }) {
            selectedMicrophoneID = ""
        }
    }

    private func refreshLaunchAtLoginStatus() {
        launchAtLoginEnabled = SMAppService.mainApp.status == .enabled
    }

    func chooseOutputDirectory() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"

        if panel.runModal() == .OK, let url = panel.url {
            outputDirectory = url
            UserDefaults.standard.set(url.path, forKey: "outputDirectory")
        }
    }

    func openScreenRecordingSettings() {
        guard let url = URL(
            string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ScreenCapture"
        ) else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    func openTranscriptInTextEdit(_ url: URL? = nil) {
        guard let transcriptURL = url ?? transcriptURL,
              let textEditURL = NSWorkspace.shared.urlForApplication(
                withBundleIdentifier: "com.apple.TextEdit"
              )
        else {
            return
        }

        NSWorkspace.shared.open(
            [transcriptURL],
            withApplicationAt: textEditURL,
            configuration: NSWorkspace.OpenConfiguration()
        )
    }

    func start() async {
        guard !isBusy, !isRecording else { return }
        isBusy = true
        errorMessage = nil
        needsScreenPermission = false
        latestLine = nil
        pipelineStatus = nil
        status = "Preparing \(language.label) model…"

        do {
            let recorder = MeetingRecorder()
            let url = try await recorder.start(
                title: transcriptTitle,
                localeIdentifier: language.rawValue,
                microphoneDeviceID: selectedMicrophoneID,
                microphoneInputChannel: microphoneInputChannel.rawValue,
                outputDirectory: outputDirectory
            ) { [weak self] update in
                Task { @MainActor [weak self] in
                    self?.latestLine = "\(update.speaker.rawValue): \(update.text)"
                }
            } onError: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.errorMessage = message
                    self?.status = "Transcription error"
                }
            } onDiagnostics: { [weak self] message in
                Task { @MainActor [weak self] in
                    self?.pipelineStatus = message
                }
            }
            self.recorder = recorder
            transcriptURL = url
            isRecording = true
            status = "Transcribing microphone + meeting audio"
        } catch {
            errorMessage = error.localizedDescription
            needsScreenPermission = (error as? CaptureError) == .screenRecordingPermission
            status = "Could not start"
        }
        isBusy = false
    }

    func stop() async {
        guard !isBusy, let recorder else { return }
        isBusy = true
        status = "Finishing transcript…"
        await recorder.stop()
        self.recorder = nil
        isRecording = false
        isBusy = false
        status = "Saved \(transcriptURL?.lastPathComponent ?? "transcript")"
    }
}
