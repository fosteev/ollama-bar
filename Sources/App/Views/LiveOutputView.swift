import OllamaBarCore
import SwiftUI

/// The tail of what the model is producing, inside the panel.
///
/// Exactly two lines: enough to see movement, too little to invite reading. Anything longer
/// belongs in the output window, which does not vanish when the panel loses focus.
struct LiveOutputView: View {
    let exchange: ProxiedExchange

    @Environment(\.openWindow) private var openWindow

    private static let visibleCharacters = 220

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                Image(systemName: "chevron.down")
                    .font(.system(size: 8))
                    .foregroundStyle(.tertiary)
                Text(isReasoning ? "Reasoning" : "Output")
                Spacer()
                Button("Open window") {
                    NSApplication.shared.activate(ignoringOtherApps: true)
                    openWindow(id: "output")
                }
                .buttonStyle(.link)
                .keyboardShortcut("o")
            }
            .font(Panel.Typography.bannerBody)
            .foregroundStyle(.secondary)

            Text(visibleText)
                .font(Panel.Typography.body)
                .italic(isReasoning)
                .foregroundStyle(
                    isReasoning
                        ? AnyShapeStyle(.secondary)
                        : AnyShapeStyle(Color.primary.opacity(0.78))
                )
                .lineSpacing(2)
                .frame(maxWidth: .infinity, maxHeight: Panel.Metrics.outputTail, alignment: .bottomLeading)
                .clipped()

            if !exchange.toolCalls.isEmpty {
                HStack(spacing: 5) {
                    ForEach(collapsedToolCalls, id: \.self) { call in
                        Text(call)
                            .font(Panel.Typography.chip)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 3)
                            .background(Panel.Palette.chipBackground, in: .rect(cornerRadius: 4))
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
    }

    private var isReasoning: Bool {
        exchange.output.isEmpty && !exchange.reasoning.isEmpty
    }

    private var visibleText: String {
        let text = isReasoning ? exchange.reasoning : exchange.output
        guard text.count > Self.visibleCharacters else { return text }
        return "…" + text.suffix(Self.visibleCharacters)
    }

    /// Agents call the same tool repeatedly; `read_file ×3` says more than three identical chips.
    private var collapsedToolCalls: [String] {
        var counts: [(name: String, count: Int)] = []
        for call in exchange.toolCalls {
            if let index = counts.firstIndex(where: { $0.name == call }) {
                counts[index].count += 1
            } else {
                counts.append((call, 1))
            }
        }
        return counts.suffix(3).map { $0.count > 1 ? "\($0.name) ×\($0.count)" : $0.name }
    }
}
