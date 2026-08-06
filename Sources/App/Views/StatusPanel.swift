import AppKit
import OllamaBarCore
import SwiftUI

/// The panel that drops down from the menu bar item.
struct StatusPanel: View {
    let model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header

            switch model.monitor.connection {
            case .unreachable(let reason):
                unreachable(reason)
            case .unknown:
                Text("Connecting…")
                    .foregroundStyle(.secondary)
            case .connected:
                inventory
                throughput
                requests
            }

            Divider()
            footer
        }
        .padding(12)
        .frame(width: 340)
    }

    private var header: some View {
        HStack {
            Text("Ollama")
                .font(.headline)
            Spacer()
            Text(model.settings.host.replacing("http://", with: ""))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func unreachable(_ reason: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Label("Not responding", systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange)
            Text(reason)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder
    private var inventory: some View {
        if model.monitor.loaded.isEmpty {
            Text("No models loaded")
                .foregroundStyle(.secondary)
        } else {
            // Ticks once a second purely to keep the eviction countdown honest — the inventory
            // itself only changes when the poller says so.
            TimelineView(.periodic(from: .now, by: 1)) { context in
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(model.monitor.loaded) { loaded in
                        LoadedModelRow(model: loaded, now: context.date)
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var throughput: some View {
        Divider()
        HStack {
            Text("Generating")
                .foregroundStyle(.secondary)
            Spacer()
            if let throughput = model.monitor.throughput {
                Text(Format.rate(throughput.tokensPerSecond))
                    .monospacedDigit()
                    .fontWeight(.medium)
            } else {
                Text("idle")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.callout)
    }

    @ViewBuilder
    private var requests: some View {
        let recent = model.monitor.recentRequests.filter { !$0.isInventoryPoll }.suffix(4)
        if !recent.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 3) {
                ForEach(recent) { request in
                    HStack(spacing: 6) {
                        Text(Format.clock(request.timestamp))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                        Text(request.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Text(Format.duration(request.duration))
                            .monospacedDigit()
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .font(.caption)
        }
    }

    private var footer: some View {
        HStack {
            if !model.monitor.loaded.isEmpty {
                Text("\(Format.bytes(model.monitor.residentBytes)) resident")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            SettingsLink {
                Text("Settings…")
            }
            .buttonStyle(.link)
            Button("Quit") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.link)
        }
        .font(.caption)
    }
}

/// One loaded model: what it is, what it costs, and how long it has left.
struct LoadedModelRow: View {
    let model: LoadedModel
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.name)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer()
                Text(Format.eviction(model.timeUntilEviction(now: now)))
                    .font(.caption)
                    .monospacedDigit()
                    .foregroundStyle(evictionStyle)
            }

            HStack(spacing: 6) {
                Text(model.details.parameterSize)
                Text(model.details.quantizationLevel)
                Text(Format.bytes(model.size))
                Text(placement)
                Text("ctx \(Format.tokens(model.contextLength))")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    /// Amber once eviction is due — the model is still resident, but only until Ollama gets to it.
    private var evictionStyle: Color {
        model.timeUntilEviction(now: now) > 0 ? .secondary : .orange
    }

    private var placement: String {
        model.isFullyOnGPU
            ? "GPU"
            : "GPU \(Int((model.vramFraction * 100).rounded()))%"
    }
}
