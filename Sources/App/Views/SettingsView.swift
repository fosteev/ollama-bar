import OllamaBarCore
import SwiftUI

struct SettingsView: View {
    @Bindable var settings: AppSettings
    private let onApply: () -> Void

    init(model: AppModel) {
        self.settings = model.settings
        self.onApply = model.restart
    }

    var body: some View {
        Form {
            Section {
                TextField("Host", text: $settings.host)
                    .onSubmit(onApply)
                TextField("Log file", text: $settings.logPath)
                    .onSubmit(onApply)
            } footer: {
                Text("Localhost only for now. The log gives throughput; without it the app still "
                     + "reports loaded models.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                Stepper(value: $settings.pollInterval, in: 1...30) {
                    Text("Refresh every \(settings.pollInterval)s")
                }
                .onChange(of: settings.pollInterval) { onApply() }
            }

            Section {
                Toggle("Intercept requests", isOn: $settings.proxyEnabled)
                    .onChange(of: settings.proxyEnabled) { onApply() }
                TextField("Proxy port", value: $settings.proxyPort, format: .number.grouping(.never))
                    .disabled(!settings.proxyEnabled)
                    .onSubmit(onApply)
            } footer: {
                Text("Point clients at this port instead of Ollama's to see what they send and "
                     + "what comes back. Traffic is relayed byte for byte.")
                .font(.caption)
                .foregroundStyle(.secondary)
            }

            Section {
                HStack {
                    Button("Restore defaults") {
                        settings.resetToDefaults()
                        onApply()
                    }
                    Spacer()
                    Button("Apply", action: onApply)
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
