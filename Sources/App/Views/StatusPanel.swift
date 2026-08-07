import AppKit
import OllamaBarCore
import SwiftUI

/// The panel that drops down from the menu bar item.
///
/// Layout follows the design: nothing occupies space "just in case". Each block exists only while
/// it has data, so the idle panel is three blocks and a footer and the maximum is a warning plus
/// activity plus output.
struct StatusPanel: View {
    let model: AppModel

    var body: some View {
        // One tick a second drives every relative number in the panel — eviction countdowns,
        // idle time, thinking timer, "last seen". Cheaper than a timer per label.
        TimelineView(.periodic(from: .now, by: 1)) { context in
            content(now: context.date)
        }
        .frame(width: Panel.width)
        .onAppear { model.acknowledgeAlerts() }
    }

    @ViewBuilder
    private func content(now: Date) -> some View {
        let warnings = model.monitor.warnings(now: now)

        VStack(spacing: 0) {
            if let warning = warnings.first {
                BannerView(warning: warning, extraCount: warnings.count - 1)
                PanelDivider()
            }

            header
            PanelDivider()

            switch model.monitor.connection {
            case .unknown:
                Text("Connecting…")
                    .foregroundStyle(.secondary)
                    .panelBlock(vertical: 14)
            case .unreachable(let reason):
                UnreachableBlock(reason: reason, lastSeen: model.monitor.lastSeenAt, now: now)
            case .connected:
                connected(now: now)
            }

            PanelDivider()
            FooterView(model: model, now: now)
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text("Ollama")
                .font(Panel.Typography.title)
            Spacer()
            Text(model.settings.displayHost)
                .font(Panel.Typography.meta)
                .foregroundStyle(.tertiary)
        }
        .panelBlock(vertical: 9, bottom: 8)
    }

    @ViewBuilder
    private func connected(now: Date) -> some View {
        if model.monitor.loaded.isEmpty {
            VStack(alignment: .leading, spacing: Panel.Metrics.rowGap) {
                Text("No models loaded")
                    .foregroundStyle(.secondary)
                Text("Nothing is holding memory. The next request loads a model.")
                    .font(Panel.Typography.bannerBody)
                    .foregroundStyle(.tertiary)
            }
            .panelBlock(vertical: 14)
        } else {
            VStack(alignment: .leading, spacing: Panel.Metrics.modelGap) {
                ForEach(model.monitor.loaded) { loaded in
                    ModelRow(model: loaded, now: now, actions: model)
                }
            }
            .panelBlock()

            PanelDivider()
            ActivityBlock(model: model, now: now)

            if let output = outputBlock { PanelDivider(); output }
            if let last = lastRequestRow(now: now) { PanelDivider(); last }
        }
    }

    /// Output exists only through the proxy. When it is off, the offer to turn it on appears only
    /// while something is generating — that is the moment it means anything.
    @ViewBuilder
    private var outputBlock: (some View)? {
        if case .running = model.proxyState, let active = model.monitor.activeExchange {
            LiveOutputView(exchange: active)
                .panelBlock()
        } else if model.monitor.throughput != nil, model.settings.proxyEnabled == false {
            HStack {
                Text("Output not captured")
                    .foregroundStyle(.tertiary)
                Spacer()
                OpenSettingsButton(title: "Turn on interception…")
            }
            .font(Panel.Typography.bannerBody)
            .panelBlock(vertical: Panel.Metrics.footerVertical)
        }
    }

    /// In idle the last request is a single line; it is the first thing cut when space runs short,
    /// because the history window has it anyway.
    @ViewBuilder
    private func lastRequestRow(now: Date) -> (some View)? {
        if model.monitor.throughput == nil,
           let last = model.monitor.exchanges.last(where: { !$0.isActive }) {
            LastRequestRow(exchange: last, isExpanded: model.lastRequestExpanded) {
                model.lastRequestExpanded.toggle()
            }
        }
    }
}

// MARK: - Banner

private struct BannerView: View {
    let warning: MonitorWarning
    let extraCount: Int

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Circle()
                .fill(tint)
                .frame(width: 11, height: 11)
                .padding(.top, 2)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(Panel.Typography.bannerTitle)
                    .foregroundStyle(tint)
                Text(detail)
                    .font(isError ? Panel.Typography.body : Panel.Typography.bannerBody)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let trailer {
                    HStack(spacing: 6) {
                        Text(trailer)
                            .font(Panel.Typography.bannerBody)
                            .foregroundStyle(.tertiary)
                        Button("Copy") { copy() }
                            .buttonStyle(.link)
                            .font(Panel.Typography.bannerBody)
                    }
                }
                if extraCount > 0 {
                    Text("\(extraCount) more…")
                        .font(Panel.Typography.bannerBody)
                        .foregroundStyle(.tertiary)
                }
            }
            Spacer(minLength: 0)
        }
        .panelBlock(vertical: Panel.Metrics.bannerVertical)
        .background(Panel.Palette.bannerTint(tint))
    }

    private var isError: Bool { warning.isError }
    private var tint: Color { isError ? Panel.Palette.failure : Panel.Palette.warning }

    private var title: String {
        switch warning {
        case .contextNearlyFull(let used, let limit):
            "Context nearly full — \(Format.tokensCompact(used)) of \(Format.tokensCompact(limit))"
        case .modelReloads(let count, _):
            "Reloaded \(count)× in the last hour"
        case .requestFailed(let status, let path, _, _, _):
            "\(status.map(String.init) ?? "Failed") from \(path)"
        }
    }

    private var detail: String {
        switch warning {
        case .contextNearlyFull:
            "The server will silently drop the oldest tokens. Your agent forgets its own "
                + "instructions first."
        case .modelReloads(_, let secondsLost):
            secondsLost.map {
                "\(Format.phase($0)) s spent loading weights. Models are competing for memory."
            } ?? "Weights are being loaded over and over. Models are competing for memory."
        case .requestFailed(_, _, let message, _, _):
            message
        }
    }

    private var trailer: String? {
        guard case .requestFailed(_, _, _, let client, let at) = warning else { return nil }
        return [Format.clock(at), client].compactMap { $0 }.joined(separator: " · ")
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString("\(title)\n\(detail)", forType: .string)
    }
}

// MARK: - Blocks

private struct UnreachableBlock: View {
    let reason: String
    let lastSeen: Date?
    let now: Date

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Circle()
                    .fill(Panel.Palette.warning)
                    .frame(width: 11, height: 11)
                Text("Not responding")
                    .fontWeight(.medium)
                    .foregroundStyle(Panel.Palette.warning)
            }
            Text(hint)
                .font(Panel.Typography.bannerBody)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text(status)
                .font(Panel.Typography.body)
                .foregroundStyle(.tertiary)
        }
        .panelBlock(vertical: 12)
    }

    /// A refused connection has one overwhelmingly likely cause, so say it instead of echoing
    /// the socket error at someone who then has to translate it themselves.
    private var hint: String {
        let refused = reason.localizedCaseInsensitiveContains("refused")
            || reason.localizedCaseInsensitiveContains("could not connect")
        return refused ? "Ollama isn’t running — start it with ollama serve." : reason
    }

    private var status: String {
        guard let lastSeen else { return "never reached · retrying" }
        return "last seen \(Format.age(now.timeIntervalSince(lastSeen))) ago · retrying"
    }
}

private struct ModelRow: View {
    let model: LoadedModel
    let now: Date
    let actions: AppModel

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: Panel.Metrics.rowGap) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(model.name)
                    .font(Panel.Typography.modelName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 4)
                Text(Format.eviction(model.timeUntilEviction(now: now)))
                    .font(Panel.Typography.meta)
                    .foregroundStyle(isDue ? AnyShapeStyle(Panel.Palette.warning) : AnyShapeStyle(.secondary))
                    .fixedSize()
            }

            HStack(spacing: 8) {
                Text(model.details.parameterSize)
                Text(model.details.quantizationLevel)
                Text(Format.bytes(model.size))
                Text(placement)
                Text("ctx \(Format.tokens(model.contextLength))")
            }
            .font(Panel.Typography.meta)
            .foregroundStyle(.secondary)
        }
        .contentShape(.rect)
        // The only destructive action in the app does not get a permanently visible button next
        // to a countdown that is already ticking down toward the same result.
        .contextMenu {
            Button("Unload now") { actions.unload(model.name) }
            Button("Keep loaded until quit") { actions.pin(model.name) }
            Divider()
            // Talking to the model is a chat client's job, and `ollama run` already is one.
            Button("Chat in Terminal…") { TerminalLauncher.chat(with: model.name) }
            Button("Show requests for this model…") {
                actions.showHistory(for: model.name)
                NSApplication.shared.activate(ignoringOtherApps: true)
                openWindow(id: "history")
            }
            Button("Copy name") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.name, forType: .string)
            }
        }
    }

    private var isDue: Bool { model.timeUntilEviction(now: now) <= 0 }

    private var placement: String {
        model.isFullyOnGPU ? "GPU" : "GPU \(Int((model.vramFraction * 100).rounded()))%"
    }
}

private struct ActivityBlock: View {
    let model: AppModel
    let now: Date

    var body: some View {
        if let activity = model.activity(now: now) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    ActivityDot(color: activity.tint)
                    Text(activity.label)
                        .font(Panel.Typography.sectionLabel)
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Text(activity.headline)
                        .font(Panel.Typography.headline)
                        .monospacedDigit()
                }

                if !activity.meta.isEmpty || activity.reuse != nil {
                    HStack(spacing: 8) {
                        ForEach(activity.meta, id: \.self) { Text($0) }
                        if let reuse = activity.reuse {
                            PromptReuseChip(reuse: reuse)
                        }
                    }
                    .font(Panel.Typography.meta)
                    .foregroundStyle(.secondary)
                }

                if let fill = activity.contextFill, fill.fraction >= 0.7 {
                    ContextBar(fill: fill)
                }
            }
            .panelBlock(vertical: 9)
            .background(Panel.Palette.activityTint(activity.tint))
        } else {
            HStack {
                Text("Generating")
                    .foregroundStyle(.secondary)
                Spacer()
                Text(idleLabel)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .font(Panel.Typography.sectionLabel)
            .panelBlock(vertical: Panel.Metrics.footerVertical)
        }
    }

    /// "idle" alone would leave you wondering whether the app is still watching.
    private var idleLabel: String {
        guard let ended = model.monitor.generationEndedAt else { return "idle" }
        return "idle · \(Format.age(now.timeIntervalSince(ended)))"
    }
}

/// Whether the server could continue from the prompt it already had, or is evaluating the whole
/// context again. For an agent looping over the same conversation this is the difference between
/// an instant reply and a minute of waiting, and nothing else in the stack reports it.
private struct PromptReuseChip: View {
    let reuse: SlotReuse

    var body: some View {
        Text(label)
            .font(Panel.Typography.chip)
            .padding(.horizontal, 5)
            .padding(.vertical, 1)
            .background(tint.opacity(0.16), in: .rect(cornerRadius: 4))
            .foregroundStyle(tint)
            .help(reuse.isHit
                  ? "The server continued from the prompt it already had."
                  : "The prompt did not match the cache — the context is being evaluated again.")
    }

    private var label: String {
        reuse.isHit ? "cache \(Int((reuse.similarity * 100).rounded()))%" : "cache miss"
    }

    private var tint: Color {
        reuse.isHit ? Panel.Palette.generating : Panel.Palette.warning
    }
}

private struct ContextBar: View {
    let fill: OllamaMonitor.ContextFill

    var body: some View {
        HStack(spacing: 6) {
            Text("ctx")
            GeometryReader { proxy in
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.primary.opacity(0.12))
                    Capsule()
                        .fill(isTight ? Panel.Palette.warning : Color.primary.opacity(0.4))
                        .frame(width: proxy.size.width * fill.fraction)
                }
            }
            .frame(height: 3)
            Text("\(Format.tokensCompact(fill.used)) / \(Format.tokensCompact(fill.limit))")
                .fixedSize()
        }
        .font(Panel.Typography.meta)
        .foregroundStyle(isTight ? AnyShapeStyle(Panel.Palette.warning) : AnyShapeStyle(.secondary))
    }

    private var isTight: Bool { fill.fraction >= 0.9 }
}

private struct LastRequestRow: View {
    let exchange: ProxiedExchange
    let isExpanded: Bool
    let toggle: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Button(action: toggle) {
                HStack(spacing: 6) {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 8))
                        .foregroundStyle(.tertiary)
                    Text(Format.clock(exchange.startedAt))
                        .monospacedDigit()
                    Text(exchange.path)
                        .foregroundStyle(exchange.isFailure ? Panel.Palette.failure : .primary)
                        .lineLimit(1)
                    Spacer(minLength: 4)
                    Text(summary)
                        .monospacedDigit()
                        .foregroundStyle(exchange.isFailure ? AnyShapeStyle(Panel.Palette.failure) : AnyShapeStyle(.secondary))
                }
                .font(Panel.Typography.bannerBody)
                .foregroundStyle(.secondary)
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            if isExpanded, let timings = exchange.timings {
                HStack(spacing: 12) {
                    Text("load \(Format.phase(timings.load)) s")
                    Text("prompt \(Format.phase(timings.prompt)) s")
                    Text("gen \(Format.phase(timings.generation)) s")
                }
                .font(Panel.Typography.meta)
                .foregroundStyle(.secondary)
            }
        }
        .panelBlock(vertical: Panel.Metrics.footerVertical)
    }

    private var summary: String {
        if exchange.isFailure {
            let status = exchange.status.map(String.init) ?? "failed"
            return "\(status) · \(Format.phase(exchange.duration ?? 0)) s"
        }
        let tokens = [exchange.promptTokens, exchange.completionTokens]
        let counts = tokens.allSatisfy { $0 != nil }
            ? "\(tokens[0]!)→\(tokens[1]!) · "
            : ""
        return counts + "\(Format.phase(exchange.duration ?? 0)) s"
    }
}

private struct FooterView: View {
    let model: AppModel
    let now: Date

    @Environment(\.openWindow) private var openWindow

    var body: some View {
        HStack {
            if isUnreachable {
                Button("Retry now") { model.restart() }
                    .buttonStyle(.link)
                    .font(Panel.Typography.footerAction)
                    .foregroundStyle(.secondary)
            } else {
                // The counter is the way into the full list — a fourth link would crowd a footer
                // the design deliberately keeps to three.
                Button(leading) { open("models") }
                    .buttonStyle(.plain)
                    .font(Panel.Typography.footer)
                    .foregroundStyle(.tertiary)
                    .help("Show all installed models")
            }
            Spacer()
            HStack(spacing: 12) {
                if model.hasHistory {
                    Button("History…") { open("history") }
                        .buttonStyle(.link)
                }
                OpenSettingsButton(title: "Settings…")
                Button("Quit") { NSApplication.shared.terminate(nil) }
                    .buttonStyle(.link)
            }
            .font(Panel.Typography.footerAction)
        }
        .panelBlock(vertical: Panel.Metrics.footerVertical, bottom: 8)
    }

    private var isUnreachable: Bool {
        if case .unreachable = model.monitor.connection { return true }
        return false
    }

    private var leading: String {
        if model.monitor.loaded.isEmpty { return "\(model.monitor.installed.count) installed" }
        return "\(Format.bytes(model.monitor.residentBytes)) resident"
    }

    private func open(_ id: String) {
        NSApplication.shared.activate(ignoringOtherApps: true)
        openWindow(id: id)
    }
}
