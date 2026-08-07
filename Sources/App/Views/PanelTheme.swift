import AppKit
import SwiftUI

/// Type, spacing and colour taken from the design spec (docs/DESIGN_BRIEF.md → Claude Design).
///
/// The mockup's flat panel fill is not reproduced: a `MenuBarExtra(.window)` panel already sits on
/// the system popover material, and painting a hex colour over it would look wrong against every
/// wallpaper. Everything else — sizes, weights, opacities, spacing — follows the spec exactly.
enum Panel {
    static let width: CGFloat = 340

    enum Metrics {
        /// Blocks: 8–9 pt vertical, 12 pt horizontal.
        static let blockVertical: CGFloat = 8
        static let blockHorizontal: CGFloat = 12
        /// Rows inside a block.
        static let rowGap: CGFloat = 3
        static let footerVertical: CGFloat = 7
        static let bannerVertical: CGFloat = 9
        /// Two lines of monospaced output at 11 pt.
        static let outputTail: CGFloat = 32
        /// Models are separated by space, not by rules — a line per model reads as a table.
        static let modelGap: CGFloat = 8
    }

    enum Typography {
        static let title = Font.system(size: 13, weight: .semibold)
        static let modelName = Font.system(size: 13, weight: .medium)
        static let meta = Font.system(size: 11, design: .monospaced)
        /// The one large number in the app: speed, or the thinking timer.
        static let headline = Font.system(size: 17, weight: .semibold, design: .monospaced)
        static let sectionLabel = Font.system(size: 12)
        static let body = Font.system(size: 11, design: .monospaced)
        static let footer = Font.system(size: 11, design: .monospaced)
        static let footerAction = Font.system(size: 11)
        static let bannerTitle = Font.system(size: 12, weight: .medium)
        static let bannerBody = Font.system(size: 11)
        static let chip = Font.system(size: 10, design: .monospaced)
    }

    enum Palette {
        static let divider = Color.primary.opacity(0.09)
        static let generating = Color.accentColor
        /// Reasoning gets its own hue so thinking never reads as answering.
        static let reasoning = Color(red: 0.36, green: 0.34, blue: 0.79)
        static let warning = Color.orange
        static let failure = Color.red
        static let chipBackground = Color.primary.opacity(0.07)

        /// The three phases of a request, wherever they are drawn. Loading borrows the reasoning
        /// hue on purpose — both mean "not answering yet".
        static let load = reasoning
        static let prompt = Color.teal
        static let generation = Color.accentColor

        static func activityTint(_ color: Color) -> Color { color.opacity(0.06) }
        static func bannerTint(_ color: Color) -> Color { color.opacity(0.16) }
    }
}

/// A full-width hairline. `Divider()` inherits list insets in some containers; this never does.
struct PanelDivider: View {
    var body: some View {
        Rectangle()
            .fill(Panel.Palette.divider)
            .frame(height: 1)
    }
}

extension View {
    func panelBlock(
        vertical: CGFloat = Panel.Metrics.blockVertical,
        bottom: CGFloat? = nil
    ) -> some View {
        padding(.top, vertical)
            .padding(.bottom, bottom ?? vertical)
            .padding(.horizontal, Panel.Metrics.blockHorizontal)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Opens the Settings scene and brings it to the front.
///
/// An `LSUIElement` app has no menu bar, so there is no Settings menu item and no ⌘, — this link
/// is the only way in. `SettingsLink` alone opens the window while the app stays inactive, which
/// leaves it behind whatever the user was looking at, so the activation is not optional.
struct OpenSettingsButton: View {
    let title: String

    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button(title) {
            // Open first, activate after: clicking the panel tears its view hierarchy down, and
            // an action dispatched after that teardown can be dropped.
            openSettings()
            DispatchQueue.main.async {
                NSApplication.shared.activate(ignoringOtherApps: true)
            }
        }
        .buttonStyle(.link)
    }
}

/// The dot that marks a live request. It pulses only while something is actually happening —
/// a permanently animating element in the menu bar is a distraction, not information.
struct ActivityDot: View {
    let color: Color
    var animated: Bool = true

    @State private var dim = false

    var body: some View {
        Circle()
            .fill(color)
            .frame(width: 6, height: 6)
            .opacity(dim ? 0.25 : 1)
            .animation(
                animated ? .easeInOut(duration: 0.7).repeatForever(autoreverses: true) : .default,
                value: dim
            )
            .onAppear { if animated { dim = true } }
    }
}
