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

    init(store: JSONSettingsStore = JSONSettingsStore()) {
        self.store = store
        self.host = store.string("ollama.host") ?? OllamaHTTPClient.defaultBaseURL.absoluteString
        self.pollInterval = store.int("app.pollInterval") ?? 2
        self.logPath = store.string("ollama.logPath") ?? ServerLogTailer.defaultURL.path
    }

    var baseURL: URL {
        URL(string: host) ?? OllamaHTTPClient.defaultBaseURL
    }

    var logURL: URL {
        URL(filePath: logPath)
    }

    func resetToDefaults() {
        host = OllamaHTTPClient.defaultBaseURL.absoluteString
        pollInterval = 2
        logPath = ServerLogTailer.defaultURL.path
    }
}
