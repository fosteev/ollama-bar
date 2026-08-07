import Foundation

/// Something that happened to the server and might be worth saying outside the panel.
///
/// Deliberately small. The panel is where state lives; this is only for the handful of things a
/// user would want to hear about while looking at something else.
public enum MonitorEvent: Sendable, Equatable {
    case modelLoaded(String)
    /// Went away without us asking. Ollama expires models on its own timer.
    case modelEvicted(String)
    /// One model displaced another inside the same poll — the expensive case, because the one that
    /// left has to be loaded from disk again next time it is used.
    case modelSwapped(from: String, to: String)
    case requestFailed(model: String?, path: String, reason: String)
}

/// Where `MonitorEvent`s go. Implemented by the notifier in the app; nil everywhere else.
public protocol MonitorEventObserver: Sendable {
    func observe(_ events: [MonitorEvent])
}
