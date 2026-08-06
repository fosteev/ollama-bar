import OllamaBarCore
import SwiftUI

/// The label in the menu bar itself.
///
/// Text appears only while something is happening — a permanent readout is noise the user stops
/// seeing after a day. A warning changes the icon's colour rather than adding text: colour costs
/// no width, reads in peripheral vision, and no warning fits in a menu bar sentence anyway.
struct MenuBarLabel: View {
    let state: MenuBarState
    let alert: AppModel.AlertLevel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "cpu")
                .foregroundStyle(iconColor)
                .opacity(iconOpacity)

            switch state {
            case .generating(let rate):
                // Always six characters wide, so the item resizes once per request and its
                // neighbours never shuffle.
                Text(Format.rate(rate))
                    .font(.system(size: 12, design: .monospaced))
                    .monospacedDigit()
            case .idle(let loadedCount) where loadedCount > 0:
                Circle()
                    .fill(dotColor)
                    .frame(width: 4, height: 4)
            case .idle, .unreachable:
                EmptyView()
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconColor: Color {
        switch alert {
        case .none: .primary
        case .warning: .orange
        case .error: .red
        }
    }

    private var dotColor: Color {
        alert == .none ? .secondary : iconColor
    }

    /// Absence and emptiness are different things, and the difference is worth one opacity step:
    /// 35% means "not answering", 60% means "answering, nothing loaded".
    private var iconOpacity: Double {
        guard alert == .none else { return 1 }
        switch state {
        case .unreachable: return 0.35
        case .idle(let loadedCount): return loadedCount > 0 ? 1 : 0.6
        case .generating: return 1
        }
    }

    private var accessibilityLabel: String {
        switch state {
        case .unreachable: "Ollama unreachable"
        case .idle(let count): count == 0 ? "No models loaded" : "\(count) models loaded"
        case .generating(let rate): "Generating at \(Format.rate(rate))"
        }
    }
}
