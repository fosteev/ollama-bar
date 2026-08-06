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

/// The one thing this app changes rather than observes: handing memory back.
public protocol ModelController: Sendable {
    func unload(model: String) async throws
    /// Keeps a model resident indefinitely instead of letting it expire.
    func pin(model: String) async throws
}
