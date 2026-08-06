import Foundation
import OllamaBarCore
import OllamaBarInfrastructure

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

    init(store: JSONSettingsStore = JSONSettingsStore()) {
        self.store = store
        self.host = store.string("ollama.host") ?? OllamaHTTPClient.defaultBaseURL.absoluteString
        self.pollInterval = store.int("app.pollInterval") ?? 2
        self.logPath = store.string("ollama.logPath") ?? ServerLogTailer.defaultURL.path
        self.proxyEnabled = store.bool("proxy.enabled") ?? false
        self.proxyPort = store.int("proxy.port") ?? 11435
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
    }
}
