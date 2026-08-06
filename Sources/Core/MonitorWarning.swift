import Foundation

/// Something the user would want to know but would never think to look for.
///
/// Warnings are rare and interruptive by design: they sit above everything else in the panel and
/// tint the menu bar icon. Only one is shown at a time — a stack of them is a dashboard, not a
/// warning.
public enum MonitorWarning: Sendable, Equatable, Identifiable {
    /// The prompt is approaching the window the model was loaded with. Past it the server silently
    /// drops the oldest tokens and the agent forgets its own instructions.
    case contextNearlyFull(used: Int, limit: Int)
    /// Weights are being loaded over and over — usually two models competing for VRAM.
    case modelReloads(count: Int, secondsLost: TimeInterval?)
    /// A request came back as an error. Shown verbatim: people paste these into issues.
    case requestFailed(status: Int?, path: String, message: String, client: String?, at: Date)

    public var id: String {
        switch self {
        case .contextNearlyFull(let used, let limit): "context-\(used)-\(limit)"
        case .modelReloads(let count, _): "reloads-\(count)"
        case .requestFailed(_, let path, _, _, let at): "failed-\(path)-\(at.timeIntervalSince1970)"
        }
    }

    /// Errors outrank everything: they already happened. Context overflow is next — it is about to
    /// happen. Reloads are a nuisance, not a failure.
    public var severity: Int {
        switch self {
        case .requestFailed: 3
        case .contextNearlyFull: 2
        case .modelReloads: 1
        }
    }

    public var isError: Bool {
        if case .requestFailed = self { return true }
        return false
    }
}
