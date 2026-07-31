import AppKit
import Combine
import Foundation
import MinuteMarkCore
import ServiceManagement
import Speech

struct MeetingLanguage: Identifiable, Hashable, Sendable {
    let id: String
    let label: String

    init(locale: Locale) {
        id = locale.identifier
        label = Locale.current.localizedString(forIdentifier: locale.identifier)
            ?? locale.identifier
    }
}

enum LanguageModelState: Equatable, Sendable {
    case checking
    case installed
    case downloading
    case downloadRequired
    case unsupported

    var label: String {
        switch self {
        case .checking: "Checking language model…"
        case .installed: "Installed for MinuteMark"
        case .downloading: "Language model downloading…"
        case .downloadRequired: "Download required for MinuteMark"
        case .unsupported: "Language model unavailable"
        }
    }

    var symbolName: String {
        switch self {
        case .checking: "ellipsis.circle"
        case .installed: "checkmark.circle.fill"
        case .downloading: "arrow.down.circle"
        case .downloadRequired: "arrow.down.circle"
        case .unsupported: "exclamationmark.triangle"
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
    static let automaticLanguageID = "automatic"

    @Published var selectedLanguageID: String {
        didSet {
            UserDefaults.standard.set(
                selectedLanguageID,
                forKey: "transcriptionLanguage"
            )
            Task { await refreshLanguageModelState() }
        }
    }
    @Published private(set) var languages: [MeetingLanguage] = [
        MeetingLanguage(locale: Locale(identifier: "en-US")),
        MeetingLanguage(locale: Locale(identifier: "de-DE"))
    ]
    @Published private(set) var languageModelState: LanguageModelState = .checking
    @Published private(set) var languageModelStates: [String: LanguageModelState] = [:]
    @Published private(set) var languageModelDownloadProgress: Double?
    @Published private(set) var downloadingLanguageID: String?
    @Published private(set) var languageModelDownloadError: String?
    @Published private(set) var reservedLanguageIDs: Set<String> = []
    @Published private(set) var languageModelManagementMessage: String?
    @Published var isLanguageDownloadConfirmationPresented = false
    @Published private(set) var pendingLanguageDownload: MeetingLanguage?
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

    var resolvedLanguage: MeetingLanguage {
        if selectedLanguageID != Self.automaticLanguageID,
           let selected = languages.first(where: { $0.id == selectedLanguageID }) {
            return selected
        }
        return preferredLanguage(from: languages)
    }

    var installedLanguages: [MeetingLanguage] {
        languages.filter { languageModelStates[$0.id] == .installed }
    }

    var downloadableLanguages: [MeetingLanguage] {
        languages.filter {
            let state = languageModelStates[$0.id]
            return state != .installed && state != .unsupported
        }
    }

    var resolvedLanguageIsInstalled: Bool {
        languageModelStates[resolvedLanguage.id] == .installed
    }

    var selectedMissingLanguage: MeetingLanguage? {
        guard selectedLanguageID != Self.automaticLanguageID,
              let language = languages.first(where: {
                  $0.id == selectedLanguageID
              }),
              languageModelStates[language.id] != .installed
        else {
            return nil
        }
        return language
    }

    init() {
        selectedLanguageID = UserDefaults.standard.string(
            forKey: "transcriptionLanguage"
        ) ?? Self.automaticLanguageID
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
        Task { await refreshLanguages() }
    }

    func refreshLanguages() async {
        let supportedLocales = await SpeechTranscriber.supportedLocales
        let supportedLanguages = supportedLocales
            .map(MeetingLanguage.init(locale:))
            .reduce(into: [String: MeetingLanguage]()) { result, language in
                result[language.id] = language
            }
            .values
            .sorted {
                $0.label.localizedCaseInsensitiveCompare($1.label) == .orderedAscending
            }

        guard !supportedLanguages.isEmpty else { return }
        languages = supportedLanguages
        if selectedLanguageID != Self.automaticLanguageID,
           !languages.contains(where: { $0.id == selectedLanguageID }) {
            selectedLanguageID = Self.automaticLanguageID
        }

        languageModelStates = await modelStates(for: supportedLanguages)
        await refreshReservedLanguages()
        sortLanguagesByAvailability()
        languageModelState = languageModelStates[resolvedLanguage.id] ?? .checking
    }

    func refreshLanguageModelState() async {
        let language = resolvedLanguage
        languageModelState = .checking
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: language.id),
            preset: .progressiveTranscription
        )
        let status = await AssetInventory.status(forModules: [transcriber])

        guard resolvedLanguage.id == language.id else { return }
        let state = Self.modelState(for: status)
        languageModelState = state
        languageModelStates[language.id] = state
        sortLanguagesByAvailability()
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
        await refreshLanguageModelState()

        if languageModelState == .downloadRequired {
            pendingLanguageDownload = resolvedLanguage
            isLanguageDownloadConfirmationPresented = true
            return
        }
        await beginTranscription()
    }

    func confirmLanguageDownloadAndStart() async {
        guard let pendingLanguageDownload,
              pendingLanguageDownload.id == resolvedLanguage.id
        else {
            cancelLanguageDownload()
            return
        }
        self.pendingLanguageDownload = nil
        isLanguageDownloadConfirmationPresented = false
        await beginTranscription()
    }

    func cancelLanguageDownload() {
        pendingLanguageDownload = nil
        isLanguageDownloadConfirmationPresented = false
    }

    func downloadLanguageModel(_ language: MeetingLanguage) async {
        guard downloadingLanguageID == nil else { return }
        downloadingLanguageID = language.id
        languageModelDownloadError = nil
        languageModelDownloadProgress = 0
        languageModelStates[language.id] = .downloading

        defer {
            downloadingLanguageID = nil
            languageModelDownloadProgress = nil
        }

        do {
            guard let locale = await SpeechTranscriber.supportedLocale(
                equivalentTo: Locale(identifier: language.id)
            ) else {
                throw TranscriptionError.unsupportedLanguage(language.id)
            }
            let transcriber = SpeechTranscriber(
                locale: locale,
                preset: .progressiveTranscription
            )
            let modules: [any SpeechModule] = [transcriber]
            let status = await AssetInventory.status(forModules: modules)
            if status != .installed {
                guard let request = try await AssetInventory
                    .assetInstallationRequest(supporting: modules)
                else {
                    throw TranscriptionError.modelUnavailable(language.id)
                }

                let progressTask = Task { @MainActor [weak self] in
                    while !Task.isCancelled {
                        let fraction = request.progress.fractionCompleted
                        self?.languageModelDownloadProgress = fraction.isFinite
                            ? min(1, max(0, fraction))
                            : 0
                        try? await Task.sleep(for: .milliseconds(200))
                    }
                }
                defer { progressTask.cancel() }
                try await request.downloadAndInstall()
            }

            languageModelStates[language.id] = .installed
            sortLanguagesByAvailability()
            selectedLanguageID = language.id
            languageModelState = .installed
        } catch {
            languageModelDownloadError = error.localizedDescription
            await refreshLanguageModelState(for: language)
        }
    }

    func clearLanguageModelDownloadError() {
        languageModelDownloadError = nil
    }

    func refreshReservedLanguages() async {
        let reservedLocales = await AssetInventory.reservedLocales
        reservedLanguageIDs = Set(reservedLocales.map {
            Self.normalizedLocaleIdentifier($0.identifier)
        })
    }

    func isLanguageReserved(_ language: MeetingLanguage) -> Bool {
        reservedLanguageIDs.contains(
            Self.normalizedLocaleIdentifier(language.id)
        )
    }

    func releaseLanguageModel(_ language: MeetingLanguage) async {
        guard !isRecording, !isBusy else { return }
        guard let locale = await SpeechTranscriber.supportedLocale(
            equivalentTo: Locale(identifier: language.id)
        ) else {
            languageModelManagementMessage = "The \(language.label) model is no longer supported on this Mac."
            return
        }

        let released = await AssetInventory.release(reservedLocale: locale)
        await refreshReservedLanguages()
        await refreshLanguageModelState(for: language)

        if released {
            languageModelManagementMessage = "MinuteMark released the \(language.label) model. macOS will decide when to reclaim its storage."
        } else {
            languageModelManagementMessage = "The \(language.label) model is managed by macOS or another app and cannot be released by MinuteMark."
        }
    }

    func clearLanguageModelManagementMessage() {
        languageModelManagementMessage = nil
    }

    private func beginTranscription() async {
        guard !isBusy, !isRecording else { return }
        isBusy = true
        errorMessage = nil
        needsScreenPermission = false
        latestLine = nil
        pipelineStatus = nil
        languageModelDownloadProgress = nil
        let language = resolvedLanguage
        if languageModelState == .downloadRequired {
            status = "Downloading \(language.label) model…"
            languageModelState = .downloading
        } else {
            status = "Preparing \(language.label) model…"
        }

        do {
            let recorder = MeetingRecorder()
            let url = try await recorder.start(
                title: transcriptTitle,
                localeIdentifier: language.id,
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
            } onDownloadProgress: { [weak self] progress in
                Task { @MainActor [weak self] in
                    self?.languageModelState = .downloading
                    self?.languageModelDownloadProgress = progress.isFinite
                        ? min(1, max(0, progress))
                        : 0
                }
            }
            self.recorder = recorder
            transcriptURL = url
            isRecording = true
            status = "Transcribing microphone + meeting audio"
            languageModelState = .installed
            languageModelStates[language.id] = .installed
            await refreshReservedLanguages()
            sortLanguagesByAvailability()
            languageModelDownloadProgress = nil
        } catch {
            errorMessage = error.localizedDescription
            needsScreenPermission = (error as? CaptureError) == .screenRecordingPermission
            status = "Could not start"
            languageModelDownloadProgress = nil
        }
        isBusy = false
    }

    private func preferredLanguage(
        from supportedLanguages: [MeetingLanguage]
    ) -> MeetingLanguage {
        for preferredIdentifier in Locale.preferredLanguages {
            let preferredLocale = Locale(identifier: preferredIdentifier)
            if let exact = supportedLanguages.first(where: {
                $0.id.replacingOccurrences(of: "_", with: "-")
                    .caseInsensitiveCompare(
                        preferredIdentifier.replacingOccurrences(of: "_", with: "-")
                    ) == .orderedSame
            }) {
                return exact
            }
            if let regionalMatch = supportedLanguages.first(where: {
                let locale = Locale(identifier: $0.id)
                return locale.language.languageCode
                        == preferredLocale.language.languageCode &&
                    locale.region == preferredLocale.region
            }) {
                return regionalMatch
            }
            if let exact = supportedLanguages.first(where: {
                Locale(identifier: $0.id).language.languageCode
                    == preferredLocale.language.languageCode
            }) {
                return exact
            }
        }
        return supportedLanguages.first(where: {
            Locale(identifier: $0.id).language.languageCode?.identifier == "en"
        }) ?? supportedLanguages[0]
    }

    private func modelStates(
        for supportedLanguages: [MeetingLanguage]
    ) async -> [String: LanguageModelState] {
        await withTaskGroup(
            of: (String, LanguageModelState).self,
            returning: [String: LanguageModelState].self
        ) { group in
            for language in supportedLanguages {
                group.addTask {
                    let transcriber = SpeechTranscriber(
                        locale: Locale(identifier: language.id),
                        preset: .progressiveTranscription
                    )
                    let status = await AssetInventory.status(
                        forModules: [transcriber]
                    )
                    return (language.id, Self.modelState(for: status))
                }
            }

            var states: [String: LanguageModelState] = [:]
            for await (identifier, state) in group {
                states[identifier] = state
            }
            return states
        }
    }

    private func refreshLanguageModelState(
        for language: MeetingLanguage
    ) async {
        let transcriber = SpeechTranscriber(
            locale: Locale(identifier: language.id),
            preset: .progressiveTranscription
        )
        let status = await AssetInventory.status(forModules: [transcriber])
        languageModelStates[language.id] = Self.modelState(for: status)
        sortLanguagesByAvailability()
    }

    private static nonisolated func modelState(
        for status: AssetInventory.Status
    ) -> LanguageModelState {
        switch status {
        case .installed: .installed
        case .downloading: .downloading
        case .supported: .downloadRequired
        case .unsupported: .unsupported
        @unknown default: .checking
        }
    }

    private static nonisolated func normalizedLocaleIdentifier(
        _ identifier: String
    ) -> String {
        identifier.replacingOccurrences(of: "_", with: "-").lowercased()
    }

    private func sortLanguagesByAvailability() {
        languages.sort { lhs, rhs in
            let lhsInstalled = languageModelStates[lhs.id] == .installed
            let rhsInstalled = languageModelStates[rhs.id] == .installed
            if lhsInstalled != rhsInstalled {
                return lhsInstalled
            }
            return lhs.label.localizedCaseInsensitiveCompare(rhs.label)
                == .orderedAscending
        }
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
