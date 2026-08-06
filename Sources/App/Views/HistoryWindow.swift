import OllamaBarCore
import SwiftUI

/// Requests seen through the proxy, with the one number nothing else in the stack gives you:
/// where the wall clock actually went.
struct HistoryWindow: View {
    let model: AppModel

    @State private var selection: ProxiedExchange.ID?

    var body: some View {
        VStack(spacing: 0) {
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
                BreakdownView(exchange: selected)
            }
        }
        .frame(minWidth: 520, minHeight: 300)
        .navigationTitle("Requests")
        .navigationSubtitle(summary)
    }

    /// Newest first: the request you want is almost always the last one.
    private var rows: [ProxiedExchange] {
        model.monitor.exchanges.reversed()
    }

    private var selected: ProxiedExchange? {
        rows.first { $0.id == selection } ?? rows.first
    }

    private var summary: String {
        let exchanges = model.monitor.exchanges
        let input = exchanges.compactMap(\.promptTokens).reduce(0, +)
        let output = exchanges.compactMap(\.completionTokens).reduce(0, +)
        let spent = exchanges.compactMap(\.duration).reduce(0, +)
        return "\(exchanges.count) requests · \(Format.tokensCompact(input)) in / "
            + "\(Format.tokensCompact(output)) out · \(Format.elapsed(spent))"
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

/// The only chart in the app. It earns its place: three numbers answer "how long", the proportion
/// answers "on what" — and does it faster than comparing them in your head.
private struct BreakdownView: View {
    let exchange: ProxiedExchange

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
