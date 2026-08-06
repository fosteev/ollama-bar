import Foundation

/// Where model inventory comes from. Implemented by the HTTP client in Infrastructure,
/// stubbed in tests.
public protocol ModelInventorySource: Sendable {
    func loadedModels() async throws -> [LoadedModel]
    func installedModels() async throws -> [InstalledModel]
}

/// A stream of parsed `server.log` events. Never finishes on its own while the tailer runs.
public protocol LogEventSource: Sendable {
    func events() -> AsyncStream<LogEvent>
}
