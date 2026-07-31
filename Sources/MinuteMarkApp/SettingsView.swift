import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel

    var body: some View {
        Form {
            Picker("Microphone", selection: $model.selectedMicrophoneID) {
                ForEach(model.microphones) { microphone in
                    Text(microphone.name).tag(microphone.id)
                }
            }

            Picker("Input channel", selection: $model.microphoneInputChannel) {
                ForEach(MicrophoneInputChannel.allCases) { channel in
                    Text(channel.label).tag(channel)
                }
            }

            LabeledContent("Notes folder") {
                HStack {
                    Text(model.outputDirectory.path(percentEncoded: false))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button("Choose…") {
                        model.chooseOutputDirectory()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .disabled(model.isRecording || model.isBusy)
        .padding(.vertical, 8)
        .frame(width: 480, height: 230)
        .onAppear {
            if !model.isRecording {
                model.refreshMicrophones()
            }
        }
    }
}
