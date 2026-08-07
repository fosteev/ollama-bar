import OllamaBarCore
import SwiftUI

/// Only what a user actually changes is on the surface: where Ollama is, and whether traffic is
/// intercepted. Everything else has a working default and lives under Advanced. There is no Apply
/// button — settings take effect when the field loses focus.
struct SettingsView: View {
    @Bindable var settings: AppSettings
    private let loginItem: LoginItem
    private let onApply: () -> Void
    private let onAppearanceChange: () -> Void
    private let reachable: () -> Bool

    @State private var showAdvanced = false

    init(model: AppModel) {
        self.settings = model.settings
        self.loginItem = model.loginItem
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
                LaunchAtLoginRow(item: loginItem)
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
                    LabeledContent("History") {
                        HStack(spacing: 10) {
                            Toggle("", isOn: $settings.historyEnabled)
                                .labelsHidden()
                                .onChange(of: settings.historyEnabled) { onApply() }
                            if settings.historyEnabled {
                                Stepper(
                                    "keep \(settings.historyRetentionDays)d",
                                    value: $settings.historyRetentionDays,
                                    in: 1...365
                                )
                            }
                        }
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
                            Text("log path · poll \(settings.pollInterval)s · "
                                 + (settings.historyEnabled
                                    ? "history \(settings.historyRetentionDays)d"
                                    : "no history"))
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

/// The toggle is the easy half. The other half is that macOS can accept the registration and then
/// wait for the user to confirm it in System Settings — silently, unless we say so.
private struct LaunchAtLoginRow: View {
    let item: LoginItem

    var body: some View {
        LabeledContent("Launch at login") {
            VStack(alignment: .leading, spacing: 4) {
                Toggle("", isOn: Binding(
                    get: { item.state.isEnabled },
                    set: { item.set($0) }
                ))
                .labelsHidden()

                switch item.state {
                case .waitingForApproval:
                    Button("Approve in System Settings…") { item.openSystemSettings() }
                        .buttonStyle(.link)
                        .font(.system(size: 11))
                case .failed(let reason):
                    Text(reason)
                        .font(.system(size: 11))
                        .foregroundStyle(Panel.Palette.warning)
                        .lineLimit(2)
                case .on, .off:
                    EmptyView()
                }
            }
        }
        // The user can flip this in System Settings while the window is open.
        .onAppear { item.refresh() }
    }
}
