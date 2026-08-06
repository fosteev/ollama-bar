import OllamaBarCore
import SwiftUI

/// The label in the menu bar itself.
///
/// Text appears only while something is happening — a permanent readout is noise the user stops
/// seeing after a day. Digits are monospaced so the item does not jitter and shove its neighbours
/// around on every update.
struct MenuBarLabel: View {
    let state: MenuBarState

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "cpu")
                .foregroundStyle(iconStyle)

            switch state {
            case .generating(let rate):
                Text(Format.rate(rate))
                    .monospacedDigit()
            case .idle(let loadedCount) where loadedCount > 0:
                Circle()
                    .frame(width: 4, height: 4)
                    .foregroundStyle(.secondary)
            case .idle, .unreachable:
                EmptyView()
            }
        }
        .accessibilityLabel(accessibilityLabel)
    }

    private var iconStyle: HierarchicalShapeStyle {
        switch state {
        case .unreachable: .tertiary
        case .idle(let loadedCount): loadedCount > 0 ? .primary : .secondary
        case .generating: .primary
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
