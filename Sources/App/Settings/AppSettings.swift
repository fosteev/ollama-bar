import AppKit
import Foundation
import OllamaBarCore
import OllamaBarInfrastructure

/// Appearance override. "System" is the default and the right answer for most people; the other
/// two exist because a menu bar panel is often the only bright thing on a dark screen, or the
/// reverse, and following the system is not always what you want for one small window.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: String { rawValue }

    var title: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }

    var nsAppearance: NSAppearance? {
        switch self {
        case .system: nil
        case .light: NSAppearance(named: .aqua)
        case .dark: NSAppearance(named: .darkAqua)
        }
    }
}

/// Observable facade over the JSON settings file. Writes through on every change.
@MainActor
@Observable
final class AppSettings {
    private let store: JSONSettingsStore

    var host: String {
        didSet { store.set(host, for: "ollama.host") }
    }

    var pollInterval: Int {
        didSet { store.set(pollInterval, for: "app.pollInterval") }
    }

    var logPath: String {
        didSet { store.set(logPath, for: "ollama.logPath") }
    }

    /// Interception is opt-in: it only helps once clients are repointed at the proxy port.
    var proxyEnabled: Bool {
        didSet { store.set(proxyEnabled, for: "proxy.enabled") }
    }

    var proxyPort: Int {
        didSet { store.set(proxyPort, for: "proxy.port") }
    }

    var appearance: AppAppearance {
        didSet { store.set(appearance.rawValue, for: "app.appearance") }
    }

    /// Writing history down is what makes it survive a restart. Off means the app forgets
    /// everything on quit, as it did before.
    var historyEnabled: Bool {
        didSet { store.set(historyEnabled, for: "history.enabled") }
    }

    var historyRetentionDays: Int {
        didSet { store.set(historyRetentionDays, for: "history.retentionDays") }
    }

    init(store: JSONSettingsStore = JSONSettingsStore()) {
        self.store = store
        self.host = store.string("ollama.host") ?? OllamaHTTPClient.defaultBaseURL.absoluteString
        self.pollInterval = store.int("app.pollInterval") ?? 2
        self.logPath = store.string("ollama.logPath") ?? ServerLogTailer.defaultURL.path
        self.proxyEnabled = store.bool("proxy.enabled") ?? false
        self.proxyPort = store.int("proxy.port") ?? 11435
        self.appearance = store.string("app.appearance")
            .flatMap(AppAppearance.init(rawValue:)) ?? .system
        self.historyEnabled = store.bool("history.enabled") ?? true
        self.historyRetentionDays = (store.int("history.retentionDays") ?? HistoryStore.defaultRetentionDays)
            .clamped(to: 1...365)
    }

    var baseURL: URL {
        URL(string: host) ?? OllamaHTTPClient.defaultBaseURL
    }

    var logURL: URL {
        URL(filePath: logPath)
    }

    var upstreamHost: String { baseURL.host() ?? "127.0.0.1" }
    var upstreamPort: UInt16 { UInt16(baseURL.port ?? 11434) }

    /// The panel header has no room for a scheme, and it never varies anyway.
    var displayHost: String {
        host
            .replacingOccurrences(of: "http://", with: "")
            .replacingOccurrences(of: "https://", with: "")
    }

    func resetToDefaults() {
        host = OllamaHTTPClient.defaultBaseURL.absoluteString
        pollInterval = 2
        logPath = ServerLogTailer.defaultURL.path
        proxyEnabled = false
        proxyPort = 11435
        appearance = .system
        historyEnabled = true
        historyRetentionDays = HistoryStore.defaultRetentionDays
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
