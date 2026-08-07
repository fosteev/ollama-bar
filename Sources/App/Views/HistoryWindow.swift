import OllamaBarCore
import OllamaBarInfrastructure
import SwiftUI

/// Requests seen through the proxy, with the one number nothing else in the stack gives you:
/// where the wall clock actually went. Rows come from `AppModel`, which merges what is still in
/// memory with what was written down — so this window survives a restart.
struct HistoryWindow: View {
    let model: AppModel

    @State private var selection: ProxiedExchange.ID?
    @State private var selectedBody: ExchangeBody?

    var body: some View {
        VStack(spacing: 0) {
            if let filter = model.historyFilter {
                FilterBar(model: filter) { model.historyFilter = nil }
                Divider()
            }

            Table(rows, selection: $selection) {
                TableColumn("Time") { row in
                    Text(Format.clock(row.startedAt)).monospacedDigit()
                }
                .width(66)

                TableColumn("Model") { row in
                    Text(row.model ?? row.path)
                        .foregroundStyle(row.isFailure ? Panel.Palette.failure : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }

                TableColumn("Client") { row in
                    Text(row.client ?? "—").foregroundStyle(.secondary).lineLimit(1)
                }
                .width(96)

                TableColumn("Load · Prompt · Gen") { row in
                    Text(phases(row)).monospacedDigit().foregroundStyle(.secondary)
                }
                .width(110)

                TableColumn("Tokens") { row in
                    Text(tokens(row)).monospacedDigit()
                }
                .width(80)

                TableColumn("Total") { row in
                    Text(row.duration.map { "\(Format.phase($0)) s" } ?? "—").monospacedDigit()
                }
                .width(56)
            }
            .font(.system(size: 11, design: .monospaced))

            if let selected {
                Divider()
                BreakdownView(exchange: selected, text: selectedBody)
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .navigationTitle("Requests")
        .navigationSubtitle(summary)
        .task { await model.refreshHistory() }
        .onChange(of: model.historyGeneration) {
            Task { await model.refreshHistory() }
        }
        .onChange(of: model.historyFilter) {
            Task { await model.refreshHistory() }
        }
        // The texts are the expensive half of a record — fetched only for the row being read.
        .task(id: selected?.id) {
            selectedBody = nil
            guard let selected else { return }
            selectedBody = await model.historyBody(for: selected)
        }
    }

    /// Newest first: the request you want is almost always the last one.
    private var rows: [ProxiedExchange] {
        model.historyRows
    }

    private var selected: ProxiedExchange? {
        rows.first { $0.id == selection } ?? rows.first
    }

    /// Today rather than "everything in memory": with history on disk the second number would
    /// grow without bound and mean nothing.
    private var summary: String {
        guard let today = model.today else { return "—" }
        let totals = model.historyFilter
            .flatMap { name in today.byModel.first { $0.model == name } }
        let requests = totals?.requests ?? today.requests
        let input = totals?.promptTokens ?? today.promptTokens
        let output = totals?.completionTokens ?? today.completionTokens

        var parts = [
            "Today: \(requests) requests",
            "\(Format.tokensCompact(input)) in / \(Format.tokensCompact(output)) out",
        ]
        if totals == nil {
            parts.append(Format.elapsed(today.duration))
            if today.loadTime > 1 {
                parts.append("\(Format.elapsed(today.loadTime)) loading")
            }
            if today.failures > 0 {
                parts.append("\(today.failures) failed")
            }
        }
        return parts.joined(separator: " · ")
    }

    private func phases(_ exchange: ProxiedExchange) -> String {
        guard let timings = exchange.timings else {
            return exchange.isFailure ? (exchange.failure ?? "failed") : "—"
        }
        return [timings.load, timings.prompt, timings.generation]
            .map(Format.phase)
            .joined(separator: " · ")
    }

    private func tokens(_ exchange: ProxiedExchange) -> String {
        guard let prompt = exchange.promptTokens, let completion = exchange.completionTokens else {
            return "—"
        }
        return "\(Format.tokensCompact(prompt))→\(Format.tokensCompact(completion))"
    }
}

/// Shown while the table is narrowed to one model, so the subtitle's numbers are never read as
/// "everything".
private struct FilterBar: View {
    let model: String
    let clear: () -> Void

    var body: some View {
        HStack(spacing: 8) {
            Text("Showing").foregroundStyle(.secondary)
            Text(model).fontWeight(.medium)
            Spacer()
            Button("Show all", action: clear).buttonStyle(.link)
        }
        .font(Panel.Typography.body)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }
}

/// The only chart in the app. It earns its place: three numbers answer "how long", the proportion
/// answers "on what" — and does it faster than comparing them in your head.
private struct BreakdownView: View {
    let exchange: ProxiedExchange
    /// Loaded lazily; nil until it arrives, or for a request that carried no text at all.
    let text: ExchangeBody?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(heading)
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)

            if let timings = exchange.timings, timings.total > 0 {
                GeometryReader { proxy in
                    HStack(spacing: 2) {
                        segment("load", timings.load, timings.total, proxy.size.width, .purple)
                        segment("prompt", timings.prompt, timings.total, proxy.size.width, .teal)
                        segment("gen", timings.generation, timings.total, proxy.size.width, .blue)
                    }
                }
                .frame(height: 22)

                HStack(spacing: 16) {
                    Text("load \(Format.phase(timings.load)) s")
                    Text("prompt \(Format.phase(timings.prompt)) s")
                    Text("gen \(Format.phase(timings.generation)) s")
                    Spacer()
                    if let dominant = timings.dominantPhase, dominant.share > 0.5 {
                        Text("\(Int(dominant.share * 100))% of it was \(dominant.name)")
                            .foregroundStyle(Panel.Palette.warning)
                    }
                }
                .font(.system(size: 11, design: .monospaced))
                .foregroundStyle(.secondary)
            } else {
                Text(exchange.failure ?? "No timing reported for this request.")
                    .font(.system(size: 11, design: .monospaced))
                    .foregroundStyle(.secondary)
            }

            if let text, !text.output.isEmpty || !text.reasoning.isEmpty {
                Divider()
                ScrollView {
                    Text(text.output.isEmpty ? text.reasoning : text.output)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(text.output.isEmpty ? .secondary : .primary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(height: 90)
            }
        }
        .padding(12)
    }

    private var heading: String {
        [
            Format.clock(exchange.startedAt),
            exchange.model,
            exchange.client,
            "\(exchange.path) \(exchange.status.map(String.init) ?? "")",
        ]
        .compactMap { $0 }
        .joined(separator: " · ")
    }

    @ViewBuilder
    private func segment(
        _ label: String,
        _ value: TimeInterval,
        _ total: TimeInterval,
        _ width: CGFloat,
        _ color: Color
    ) -> some View {
        let share = value / total
        if share > 0.001 {
            RoundedRectangle(cornerRadius: 3)
                .fill(color.opacity(0.8))
                .frame(width: max(2, width * share))
                .overlay {
                    if share > 0.18 {
                        Text("\(label) \(Format.phase(value)) s")
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                    }
                }
        }
    }
}
