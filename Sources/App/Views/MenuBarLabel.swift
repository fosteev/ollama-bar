import OllamaBarCore
import SwiftUI

/// The label in the menu bar itself.
///
/// Text appears only while something is happening — a permanent readout is noise the user stops
/// seeing after a day. A warning changes the icon's colour rather than adding text: colour costs
/// no width, reads in peripheral vision, and no warning fits in a menu bar sentence anyway.
struct MenuBarLabel: View {
    /// How long a model sits unused before the dot stops asking for attention.
    static let dimAfter: TimeInterval = 30

    let state: MenuBarState
    let alert: AppModel.AlertLevel
    /// When generation last stopped, for the fade below.
    let idleSince: Date?

    @State private var dimmed = false

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
                    .opacity(dimmed ? 0.45 : 1)
                    .animation(.easeInOut(duration: 0.6), value: dimmed)
            case .idle, .unreachable:
                EmptyView()
            }
        }
        // One sleep, armed when generation stops and cancelled when it resumes — not a timer
        // ticking forever to change one dot's opacity. That trade is why this was deferred.
        .task(id: fadeKey) {
            dimmed = false
            guard case .idle(let loadedCount) = state, loadedCount > 0, let idleSince else { return }
            let remaining = Self.dimAfter - Date.now.timeIntervalSince(idleSince)
            if remaining > 0 {
                try? await Task.sleep(for: .seconds(remaining))
                guard !Task.isCancelled else { return }
            }
            dimmed = true
        }
        .accessibilityLabel(accessibilityLabel)
    }

    /// Deliberately not sensitive to the loaded count: a model appearing in memory is not the kind
    /// of activity that should make the dot bright again.
    private var fadeKey: String {
        if case .generating = state { return "generating" }
        return "idle-\(idleSince?.timeIntervalSince1970 ?? 0)"
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
