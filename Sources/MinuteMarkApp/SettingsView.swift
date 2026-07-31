import SwiftUI

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @StateObject private var microphoneMeter = MicrophoneLevelMonitor()

    var body: some View {
        Form {
            Section("Audio") {
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

                MicrophoneLevelView(
                    level: microphoneMeter.level,
                    statusMessage: microphoneMeter.statusMessage
                )
            }
            .disabled(model.isRecording || model.isBusy)

            Section("General") {
                Toggle(
                    "Launch MinuteMark at login",
                    isOn: Binding(
                        get: { model.launchAtLoginEnabled },
                        set: { enabled in
                            model.setLaunchAtLogin(enabled)
                        }
                    )
                )

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
        }
        .formStyle(.grouped)
        .padding(.vertical, 8)
        .frame(width: 500, height: 350)
        .onAppear {
            if !model.isRecording {
                model.refreshMicrophones()
            }
            updateMicrophoneMeter()
        }
        .onDisappear {
            microphoneMeter.stop()
        }
        .onChange(of: model.selectedMicrophoneID) {
            updateMicrophoneMeter()
        }
        .onChange(of: model.microphoneInputChannel) {
            updateMicrophoneMeter()
        }
        .onChange(of: model.isRecording) {
            updateMicrophoneMeter()
        }
        .alert(
            "Couldn’t Update Login Item",
            isPresented: Binding(
                get: { model.launchAtLoginError != nil },
                set: { if !$0 { model.clearLaunchAtLoginError() } }
            )
        ) {
            Button("OK") {
                model.clearLaunchAtLoginError()
            }
        } message: {
            Text(model.launchAtLoginError ?? "An unknown error occurred.")
        }
    }

    private func updateMicrophoneMeter() {
        if model.isRecording || model.isBusy {
            microphoneMeter.stop()
        } else {
            microphoneMeter.start(
                deviceID: model.selectedMicrophoneID,
                inputChannel: model.microphoneInputChannel.rawValue
            )
        }
    }
}

private struct MicrophoneLevelView: View {
    let level: Double
    let statusMessage: String?

    var body: some View {
        LabeledContent("Input level") {
            VStack(alignment: .leading, spacing: 4) {
                GeometryReader { geometry in
                    ZStack(alignment: .leading) {
                        Capsule()
                            .fill(Color.secondary.opacity(0.18))
                        Capsule()
                            .fill(meterColor)
                            .frame(width: geometry.size.width * level)
                    }
                }
                .frame(width: 210, height: 8)

                if let statusMessage {
                    Text(statusMessage)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("Live preview only — audio is not stored")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        }
        .accessibilityValue("\(Int(level * 100)) percent")
    }

    private var meterColor: Color {
        if level > 0.9 { return .red }
        if level > 0.72 { return .orange }
        return .green
    }
}
