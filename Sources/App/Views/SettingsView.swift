import OllamaBarCore
import SwiftUI

/// Only what a user actually changes is on the surface: where Ollama is, and whether traffic is
/// intercepted. Everything else has a working default and lives under Advanced. There is no Apply
/// button — settings take effect when the field loses focus.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    private let onApply: () -> Void
    private let onAppearanceChange: () -> Void
    private let reachable: () -> Bool

    @State private var showAdvanced = false

    init(model: AppModel) {
        self.settings = model.settings
        self.onApply = model.restart
        self.onAppearanceChange = model.applyAppearance
        self.reachable = { if case .connected = model.monitor.connection { true } else { false } }
    }

    var body: some View {
        Form {
            Section {
                LabeledContent("Ollama") {
                    HStack(spacing: 8) {
                        TextField("", text: $settings.host)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 12, design: .monospaced))
                            .onSubmit(onApply)
                        Circle()
                            .fill(reachable() ? Color.green : Color.secondary.opacity(0.4))
                            .frame(width: 7, height: 7)
                            .help(reachable() ? "Responding" : "Not responding")
                    }
                }

                LabeledContent("Interception") {
                    HStack(spacing: 10) {
                        Toggle("", isOn: $settings.proxyEnabled)
                            .labelsHidden()
                            .onChange(of: settings.proxyEnabled) { onApply() }
                        if settings.proxyEnabled {
                            TextField("", value: $settings.proxyPort, format: .number.grouping(.never))
                                .textFieldStyle(.roundedBorder)
                                .font(.system(size: 12, design: .monospaced))
                                .frame(width: 70)
                                .onSubmit(onApply)
                            Text("point your agent here")
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                Picker("Appearance", selection: $settings.appearance) {
                    ForEach(AppAppearance.allCases) { Text($0.title).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: settings.appearance) { onAppearanceChange() }
            } footer: {
                Text("Without interception the app shows models, memory and speed. Interception "
                     + "adds the prompt, live output and reasoning.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section {
                DisclosureGroup(isExpanded: $showAdvanced) {
                    LabeledContent("Log file") {
                        TextField("", text: $settings.logPath)
                            .textFieldStyle(.roundedBorder)
                            .font(.system(size: 11, design: .monospaced))
                            .onSubmit(onApply)
                    }
                    LabeledContent("Refresh") {
                        Stepper(
                            "every \(settings.pollInterval)s",
                            value: $settings.pollInterval,
                            in: 1...30
                        )
                        .onChange(of: settings.pollInterval) { onApply() }
                    }
                    Button("Restore defaults") {
                        settings.resetToDefaults()
                        onApply()
                    }
                } label: {
                    HStack {
                        Text("Advanced")
                        Spacer()
                        if !showAdvanced {
                            Text("log path · poll \(settings.pollInterval)s")
                                .font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 420)
        .fixedSize(horizontal: false, vertical: true)
    }
}
