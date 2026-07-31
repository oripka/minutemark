import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel
    let onOpenTranscripts: () -> Void

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
                    Picker("", selection: $model.selectedLanguageID) {
                        Text("Automatic (\(model.resolvedLanguage.label))")
                            .tag(AppModel.automaticLanguageID)
                        Divider()
                        ForEach(model.languages) { language in
                            Text(language.label).tag(language.id)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 190)
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
                    Label(
                        model.languageModelState.label,
                        systemImage: model.languageModelState.symbolName
                    )
                    .font(.caption)
                    .foregroundStyle(.secondary)
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
