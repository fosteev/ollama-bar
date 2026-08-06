import Foundation

/// A line of `server.log` that carried something we care about.
///
/// The log is not an API: llama.cpp can change these lines between releases. Anything
/// unrecognised is dropped rather than treated as an error — see `Risks` in docs/PLAN.md.
public enum LogEvent: Sendable, Equatable {
    case timing(SlotTiming)
    case request(RequestLogEntry)
    case checkpoint(ContextCheckpoint)
}

/// `slot print_timing` — generation speed for one slot.
public struct SlotTiming: Sendable, Equatable {
    public let slotID: Int
    public let taskID: Int
    public let tokensDecoded: Int
    /// Instantaneous tokens/sec for the whole decode so far.
    public let tokensPerSecond: Double
    /// Three-second moving average. This is what the UI shows — `tokensPerSecond` jitters.
    public let tokensPerSecond3s: Double

    public init(
        slotID: Int,
        taskID: Int,
        tokensDecoded: Int,
        tokensPerSecond: Double,
        tokensPerSecond3s: Double
    ) {
        self.slotID = slotID
        self.taskID = taskID
        self.tokensDecoded = tokensDecoded
        self.tokensPerSecond = tokensPerSecond
        self.tokensPerSecond3s = tokensPerSecond3s
    }
}

/// A `[GIN]` access-log line.
public struct RequestLogEntry: Sendable, Equatable, Identifiable {
    public let timestamp: Date
    public let status: Int
    public let duration: TimeInterval
    public let clientIP: String
    public let method: String
    public let path: String

    public var id: String { "\(timestamp.timeIntervalSince1970)-\(method)-\(path)" }

    /// True for the endpoints this app polls itself. Our own traffic shows up in the access log
    /// exactly like anyone else's, and at one poll per second it would drown the history.
    public var isInventoryPoll: Bool {
        path == "/api/ps" || path == "/api/tags"
    }

    public init(
        timestamp: Date,
        status: Int,
        duration: TimeInterval,
        clientIP: String,
        method: String,
        path: String
    ) {
        self.timestamp = timestamp
        self.status = status
        self.duration = duration
        self.clientIP = clientIP
        self.method = method
        self.path = path
    }
}

/// `slot create_check` — context checkpoint, a proxy for how full the context is.
public struct ContextCheckpoint: Sendable, Equatable {
    public let slotID: Int
    public let taskID: Int
    public let index: Int
    public let total: Int
    public let tokens: Int

    public init(slotID: Int, taskID: Int, index: Int, total: Int, tokens: Int) {
        self.slotID = slotID
        self.taskID = taskID
        self.index = index
        self.total = total
        self.tokens = tokens
    }
}
