import OllamaBarCore
import SwiftUI

/// What the model is producing right now, as seen through the proxy.
///
/// Reasoning is shown when there is no answer text yet — otherwise a thinking model looks frozen
/// for the first thirty seconds of every request.
struct LiveOutputView: View {
    let exchange: ProxiedExchange

    /// Enough to see the shape of what is coming out without rendering a novel every tick.
    private static let visibleCharacters = 800

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Text(exchange.model ?? "unknown model")
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(exchange.path)
                    .foregroundStyle(.secondary)
                Spacer()
                if isThinking {
                    Text("thinking")
                        .foregroundStyle(.tertiary)
                }
            }
            .font(.caption)

            ScrollView {
                Text(visibleText)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(isThinking ? .secondary : .primary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(maxHeight: 130)

            if !exchange.toolCalls.isEmpty {
                Text("tools: " + exchange.toolCalls.joined(separator: ", "))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var isThinking: Bool {
        exchange.output.isEmpty && !exchange.reasoning.isEmpty
    }

    private var visibleText: String {
        let text = exchange.output.isEmpty ? exchange.reasoning : exchange.output
        guard text.count > Self.visibleCharacters else { return text }
        return "…" + text.suffix(Self.visibleCharacters)
    }
}

/// A finished exchange, one line in the history.
struct ExchangeRow: View {
    let exchange: ProxiedExchange

    var body: some View {
        HStack(spacing: 6) {
            Text(Format.clock(exchange.startedAt))
                .monospacedDigit()
                .foregroundStyle(.secondary)
            Text(exchange.model ?? exchange.path)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer()
            if let failure = exchange.failure {
                Text(failure)
                    .foregroundStyle(.orange)
                    .lineLimit(1)
            } else {
                if let tokens = exchange.completionTokens {
                    Text("\(tokens) tok")
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
                // Wall-clock average, so it includes model loading and prompt evaluation and
                // will read lower than the live figure from the log. "avg" keeps them apart.
                if let rate = exchange.tokensPerSecond {
                    Text("avg " + Format.rate(rate))
                        .monospacedDigit()
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(.caption)
    }
}
