import Foundation

public enum ConnectionState: Sendable, Equatable {
    case unknown
    case connected
    case unreachable(String)
}

/// Current generation speed, attributed to the slot that produced it.
public struct Throughput: Sendable, Equatable {
    public let tokensPerSecond: Double
    public let slotID: Int
    public let updatedAt: Date

    public init(tokensPerSecond: Double, slotID: Int, updatedAt: Date) {
        self.tokensPerSecond = tokensPerSecond
        self.slotID = slotID
        self.updatedAt = updatedAt
    }
}

/// What the menu bar itself shows. Deliberately small and separate from the full state so the
/// menu-bar label does not redraw whenever the inventory changes — see docs/PLAN.md.
public enum MenuBarState: Sendable, Equatable {
    case unreachable
    case idle(loadedCount: Int)
    case generating(tokensPerSecond: Double)
}

/// Single source of truth for everything the app knows about the local Ollama server.
///
/// Pure state machine: it never performs I/O on its own schedule. `MonitorDriver` feeds it.
@MainActor
@Observable
public final class OllamaMonitor {
    /// How long after the last `print_timing` line generation is considered finished.
    /// Ollama never logs "generation ended", so silence is the only available signal.
    public static let generationTimeout: TimeInterval = 2

    /// How many access-log entries to keep in memory.
    public static let requestHistoryLimit = 200

    public private(set) var connection: ConnectionState = .unknown
    public private(set) var loaded: [LoadedModel] = []
    public private(set) var installed: [InstalledModel] = []
    public private(set) var throughput: Throughput?
    public private(set) var recentRequests: [RequestLogEntry] = []
    public private(set) var lastCheckpoint: ContextCheckpoint?

    public init() {}

    public var menuBarState: MenuBarState {
        if case .unreachable = connection { return .unreachable }
        if let throughput { return .generating(tokensPerSecond: throughput.tokensPerSecond) }
        return .idle(loadedCount: loaded.count)
    }

    /// Total resident bytes across all loaded models.
    public var residentBytes: Int64 {
        loaded.reduce(0) { $0 + $1.size }
    }

    /// Loaded models change constantly — this is the hot path, polled on every tick.
    public func refreshLoaded(using source: ModelInventorySource) async {
        do {
            loaded = try await source.loadedModels()
            connection = .connected
        } catch {
            connection = .unreachable(error.localizedDescription)
        }
    }

    /// The disk inventory changes only when someone pulls or deletes a model. A failure here keeps
    /// the previous list rather than blanking the UI.
    public func refreshInstalled(using source: ModelInventorySource) async {
        if let models = try? await source.installedModels() {
            installed = models
        }
    }

    public func refreshInventory(using source: ModelInventorySource) async {
        await refreshLoaded(using: source)
        await refreshInstalled(using: source)
    }

    public func apply(_ event: LogEvent, now: Date = .now) {
        switch event {
        case .timing(let timing):
            throughput = Throughput(
                tokensPerSecond: timing.tokensPerSecond3s,
                slotID: timing.slotID,
                updatedAt: now
            )
        case .request(let entry):
            recentRequests.append(entry)
            if recentRequests.count > Self.requestHistoryLimit {
                recentRequests.removeFirst(recentRequests.count - Self.requestHistoryLimit)
            }
        case .checkpoint(let checkpoint):
            lastCheckpoint = checkpoint
        }
    }

    /// Drops the throughput reading once the log has been quiet for `generationTimeout`.
    public func expireStaleThroughput(now: Date = .now) {
        guard let throughput else { return }
        if now.timeIntervalSince(throughput.updatedAt) >= Self.generationTimeout {
            self.throughput = nil
        }
    }
}
