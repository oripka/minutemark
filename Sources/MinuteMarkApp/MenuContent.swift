import AppKit
import SwiftUI

struct MenuContent: View {
    @ObservedObject var model: AppModel

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
            }

            HStack {
                Text("Title")
                    .foregroundStyle(.secondary)
                TextField("e.g. Product planning", text: $model.transcriptTitle)
                    .textFieldStyle(.roundedBorder)
            }
            .disabled(model.isRecording || model.isBusy)

            HStack {
                Text("Language")
                    .foregroundStyle(.secondary)
                Spacer()
                Picker("", selection: $model.language) {
                    ForEach(MeetingLanguage.allCases) { language in
                        Text(language.label).tag(language)
                    }
                }
                .labelsHidden()
                .frame(width: 145)
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
    }
}
