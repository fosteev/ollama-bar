import OllamaBarCore
import SwiftUI

/// Everything on disk, and what is currently holding memory.
///
/// The panel answers "what is loaded right now"; this answers "what could be". It stays a
/// monitor's list — no pulling, no deleting, that is `ollama` CLI's job — but each row can be
/// warmed, evicted, or opened as a chat in the terminal.
struct ModelsWindow: View {
    let model: AppModel

    @Environment(\.openWindow) private var openWindow
    @State private var selection: String?

    var body: some View {
        Table(model.modelListings, selection: $selection) {
            TableColumn("Model") { listing in
                HStack(spacing: 6) {
                    Circle()
                        .fill(listing.loaded != nil ? Color.accentColor : .clear)
                        .frame(width: 5, height: 5)
                    Text(listing.installed.name)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }

            TableColumn("Params") { listing in
                Text(listing.installed.details.parameterSize).foregroundStyle(.secondary)
            }
            .width(56)

            TableColumn("Quant") { listing in
                Text(listing.installed.details.quantizationLevel).foregroundStyle(.secondary)
            }
            .width(70)

            TableColumn("Size") { listing in
                Text(Format.bytes(listing.installed.size)).monospacedDigit()
            }
            .width(72)

            TableColumn("State") { listing in
                if let loaded = listing.loaded {
                    Text(Format.eviction(loaded.timeUntilEviction()))
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                } else {
                    Text("on disk").foregroundStyle(.tertiary)
                }
            }
            .width(110)

            TableColumn("Last used") { listing in
                Text(listing.lastUsed.map { Format.clock($0) } ?? "—")
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .width(70)
        }
        .font(Panel.Typography.body)
        .contextMenu(forSelectionType: String.self) { ids in
            if let name = ids.first {
                menu(for: name)
            }
        } primaryAction: { ids in
            if let name = ids.first { TerminalLauncher.chat(with: name) }
        }
        .frame(minWidth: 560, minHeight: 280)
        .navigationTitle("Models")
        .navigationSubtitle(summary)
    }

    @ViewBuilder
    private func menu(for name: String) -> some View {
        // A real chat, in the tool that already is one. Double-clicking a row does the same.
        Button("Chat in Terminal…") { TerminalLauncher.chat(with: name) }
        Divider()
        if model.monitor.loaded.contains(where: { $0.name == name }) {
            Button("Unload now") { model.unload(name) }
            Button("Keep loaded until quit") { model.pin(name) }
        } else {
            Button("Load into memory") { model.pin(name) }
        }
        Divider()
        Button("Show requests for this model…") {
            model.showHistory(for: name)
            NSApplication.shared.activate(ignoringOtherApps: true)
            openWindow(id: "history")
        }
        Divider()
        Button("Copy name") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(name, forType: .string)
        }
        Button("Copy ollama run command") {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString("ollama run \(name)", forType: .string)
        }
    }

    private var summary: String {
        let listings = model.modelListings
        let onDisk = listings.reduce(Int64(0)) { $0 + $1.installed.size }
        let loaded = listings.filter { $0.loaded != nil }.count
        return "\(listings.count) installed · \(Format.bytes(onDisk)) on disk · \(loaded) loaded"
    }
}
