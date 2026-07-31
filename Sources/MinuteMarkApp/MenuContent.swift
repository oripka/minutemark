import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    let onOpenTranscripts: () -> Void
    @State private var showsLanguageDownloads = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Image(systemName: "waveform.badge.mic")
                    .font(.title2)
                    .foregroundStyle(model.isRecording ? Color.red : Color.accentColor)
                VStack(alignment: .leading, spacing: 2) {
                    Text("MinuteMark")
                        .font(.headline)
                    Text(model.status)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer()
                Button(action: onOpenTranscripts) {
                    Label(
                        "Transcripts",
                        systemImage: "doc.text.magnifyingglass"
                    )
                }
                .buttonStyle(.borderless)
                .help("Browse past transcripts")
            }

            HStack {
                Text("Title")
                    .foregroundStyle(.secondary)
                    .frame(width: 72, alignment: .leading)
                TextField("e.g. Product planning", text: $model.transcriptTitle)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(model.isRecording || model.isBusy)

            VStack(alignment: .trailing, spacing: 4) {
                HStack {
                    Text("Language")
                        .foregroundStyle(.secondary)
                        .frame(width: 72, alignment: .leading)
                    Spacer()
                    if model.installedLanguages.isEmpty {
                        Button("Download Language Model…") {
                            showsLanguageDownloads = true
                        }
                    } else {
                        Picker("", selection: $model.selectedLanguageID) {
                            Label(
                                "Automatic — \(model.resolvedLanguage.label)",
                                systemImage: model.resolvedLanguageIsInstalled
                                    ? "checkmark.circle.fill"
                                    : "arrow.down.circle"
                            )
                                .tag(AppModel.automaticLanguageID)
                            Divider()
                            Section("Installed for MinuteMark") {
                                ForEach(model.installedLanguages) { language in
                                    Label(
                                        language.label,
                                        systemImage: "checkmark.circle.fill"
                                    )
                                    .tag(language.id)
                                }
                            }
                            if let missing = model.selectedMissingLanguage {
                                Divider()
                                Label(
                                    missing.label,
                                    systemImage: "arrow.down.circle"
                                )
                                .tag(missing.id)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 190)
                    }
                }

                if let progress = model.languageModelDownloadProgress {
                    HStack(spacing: 8) {
                        ProgressView(value: progress)
                            .frame(width: 130)
                        Text("\(Int((progress * 100).rounded()))%")
                            .monospacedDigit()
                            .frame(width: 34, alignment: .trailing)
                    }
                    .font(.caption)
                } else {
                    HStack(spacing: 10) {
                        Label(
                            model.languageModelState.label,
                            systemImage: model.languageModelState.symbolName
                        )
                        .font(.caption)
                        .foregroundStyle(.secondary)

                        if !model.installedLanguages.isEmpty {
                            Button("Download More…") {
                                showsLanguageDownloads = true
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                        }
                    }
                }
            }
            .disabled(model.isRecording || model.isBusy)

            VStack(alignment: .leading, spacing: 5) {
                Text("Live transcript")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(model.latestLine ?? (model.isRecording ? "Listening…" : "Start transcription to see speech here."))
                    .font(.body)
                    .lineLimit(5)
                    .frame(maxWidth: .infinity, minHeight: 54, alignment: .topLeading)
                    .padding(10)
                    .background(.quaternary, in: RoundedRectangle(cornerRadius: 8))
                    .textSelection(.enabled)
            }

            if let error = model.errorMessage {
                VStack(alignment: .leading, spacing: 6) {
                    Text(error)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .fixedSize(horizontal: false, vertical: true)
                    if model.needsScreenPermission {
                        Button("Open Privacy Settings") {
                            model.openScreenRecordingSettings()
                        }
                    }
                }
            }

            HStack {
                Button(model.isRecording ? "Stop transcription" : "Start transcription") {
                    Task {
                        if model.isRecording {
                            await model.stop()
                        } else {
                            await model.start()
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(model.isRecording ? .red : .accentColor)
                .disabled(model.isBusy)

                if model.transcriptURL != nil {
                    Button("Open note") {
                        model.openTranscriptInTextEdit()
                    }
                }

                Spacer()
            }
        }
        .padding(16)
        .frame(width: 380)
        .sheet(isPresented: $showsLanguageDownloads) {
            LanguageModelDownloadsView(model: model)
        }
        .confirmationDialog(
            "Download language model?",
            isPresented: $model.isLanguageDownloadConfirmationPresented,
            titleVisibility: .visible
        ) {
            Button("Download and Start") {
                Task {
                    await model.confirmLanguageDownloadAndStart()
                }
            }
            Button("Cancel", role: .cancel) {
                model.cancelLanguageDownload()
            }
        } message: {
            Text(
                "MinuteMark needs Apple’s on-device \(model.pendingLanguageDownload?.label ?? "selected language") model. It will be downloaded once and used locally."
            )
        }
    }
}

private struct LanguageModelDownloadsView: View {
    @ObservedObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var searchText = ""
    @State private var pendingRelease: MeetingLanguage?
    @State private var showsReleaseConfirmation = false

    private var visibleInstalledLanguages: [MeetingLanguage] {
        filtered(model.installedLanguages)
    }

    private var visibleDownloadableLanguages: [MeetingLanguage] {
        filtered(model.downloadableLanguages)
    }

    private func filtered(
        _ languages: [MeetingLanguage]
    ) -> [MeetingLanguage] {
        guard !searchText.isEmpty else { return languages }
        return languages.filter {
            $0.label.localizedCaseInsensitiveContains(searchText)
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Download Language Models")
                        .font(.title2)
                        .fontWeight(.semibold)
                    Text("Models are provided by Apple and remain on this Mac.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") {
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
            }
            .padding(20)

            TextField("Search languages", text: $searchText)
                .textFieldStyle(.roundedBorder)
                .padding(.horizontal, 20)
                .padding(.bottom, 12)

            Divider()

            if visibleInstalledLanguages.isEmpty &&
                visibleDownloadableLanguages.isEmpty {
                ContentUnavailableView(
                    "No matches",
                    systemImage: "magnifyingglass"
                )
            } else {
                List {
                    if !visibleInstalledLanguages.isEmpty {
                        Section("Installed") {
                            ForEach(visibleInstalledLanguages) { language in
                                installedRow(language)
                            }
                        }
                    }
                    if !visibleDownloadableLanguages.isEmpty {
                        Section("Available to Download") {
                            ForEach(visibleDownloadableLanguages) { language in
                                downloadableRow(language)
                            }
                        }
                    }
                }
            }
        }
        .frame(width: 520, height: 520)
        .task {
            await model.refreshReservedLanguages()
        }
        .confirmationDialog(
            "Release language model?",
            isPresented: $showsReleaseConfirmation,
            titleVisibility: .visible
        ) {
            Button("Release to macOS") {
                guard let language = pendingRelease else { return }
                Task {
                    await model.releaseLanguageModel(language)
                    pendingRelease = nil
                }
            }
            Button("Cancel", role: .cancel) {
                pendingRelease = nil
            }
        } message: {
            Text(
                "MinuteMark will stop reserving \(pendingRelease?.label ?? "this model"). macOS decides when to reclaim the storage, so it may remain installed for a while."
            )
        }
        .alert(
            "Couldn’t Download Language Model",
            isPresented: Binding(
                get: { model.languageModelDownloadError != nil },
                set: { if !$0 { model.clearLanguageModelDownloadError() } }
            )
        ) {
            Button("OK") {
                model.clearLanguageModelDownloadError()
            }
        } message: {
            Text(model.languageModelDownloadError ?? "An unknown error occurred.")
        }
        .alert(
            "Language Model Released",
            isPresented: Binding(
                get: { model.languageModelManagementMessage != nil },
                set: { if !$0 { model.clearLanguageModelManagementMessage() } }
            )
        ) {
            Button("OK") {
                model.clearLanguageModelManagementMessage()
            }
        } message: {
            Text(model.languageModelManagementMessage ?? "")
        }
    }

    private func installedRow(_ language: MeetingLanguage) -> some View {
        HStack(spacing: 12) {
            modelDescription(language)
            Spacer()
            if model.isLanguageReserved(language) {
                Button("Release…") {
                    pendingRelease = language
                    showsReleaseConfirmation = true
                }
                .disabled(model.isRecording || model.isBusy)
            } else {
                Text("Managed by macOS")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 5)
    }

    private func downloadableRow(_ language: MeetingLanguage) -> some View {
        HStack(spacing: 12) {
            modelDescription(language)
            Spacer()

            if model.downloadingLanguageID == language.id,
               let progress = model.languageModelDownloadProgress {
                ProgressView(value: progress)
                    .frame(width: 90)
                Text("\(Int((progress * 100).rounded()))%")
                    .font(.caption)
                    .monospacedDigit()
                    .frame(width: 34, alignment: .trailing)
            } else {
                Button("Download") {
                    Task {
                        await model.downloadLanguageModel(language)
                    }
                }
                .disabled(model.downloadingLanguageID != nil)
            }
        }
        .padding(.vertical, 5)
    }

    private func modelDescription(_ language: MeetingLanguage) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(language.label)
            Text("Apple on-device speech model")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}
