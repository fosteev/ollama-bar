import Foundation

/// A line of `server.log` that carried something we care about.
///
/// The log is not an API: llama.cpp can change these lines between releases. Anything
/// unrecognised is dropped rather than treated as an error — see `Risks` in docs/PLAN.md.
public enum LogEvent: Sendable, Equatable {
    case timing(SlotTiming)
    case request(RequestLogEntry)
    case checkpoint(ContextCheckpoint)
    case slotReuse(SlotReuse)
}

/// `slot get_availabl` — how much of the prompt the server could reuse from the slot's KV cache
/// instead of evaluating again.
///
/// This is the answer to "why is the same agent instant one minute and a minute slow the next".
/// Nothing else in the stack reports it, and for agent runs it is the single most expensive thing
/// you cannot see.
public struct SlotReuse: Sendable, Equatable {
    public let slotID: Int
    /// Longest-common-prefix similarity between the new prompt and what the slot already holds.
    public let similarity: Double
    /// Below this the server takes a cold slot instead. It is a server-side setting, not ours.
    public let threshold: Double

    public init(slotID: Int, similarity: Double, threshold: Double) {
        self.slotID = slotID
        self.similarity = similarity
        self.threshold = threshold
    }

    /// A near-perfect match means the prompt continues where the last one left off — the cheap
    /// case. Anything much lower means the context is being evaluated from scratch.
    public var isHit: Bool { similarity >= 0.9 }
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

    /// Endpoints that produce tokens. Their completion means generation has stopped.
    public var isGeneration: Bool {
        [
            "/api/chat",
            "/api/generate",
            "/v1/chat/completions",
            "/v1/completions",
            "/v1/responses",
        ].contains(path)
    }

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
