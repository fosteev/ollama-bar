import Foundation

/// One request seen through the proxy, from the request line to the last streamed token.
public struct ProxiedExchange: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public let method: String
    public let path: String
    /// Taken from the request body when it is JSON with a `model` field.
    public let model: String?
    /// From the User-Agent header — which tool made the call.
    public let client: String?
    /// The request as the client sent it, truncated. Only available through the proxy.
    public let prompt: String?

    public var status: Int?
    public var finishedAt: Date?
    public var promptTokens: Int?
    public var completionTokens: Int?
    /// Where the wall clock went, straight from Ollama's own accounting. Loading weights routinely
    /// dwarfs generation, and nothing else in the stack tells you that.
    public var timings: ExchangeTimings?
    /// Text the model produced, reassembled from the stream. Truncated past `outputLimit`.
    public var output: String
    /// Reasoning tokens, kept apart from the answer. Without these a thinking model looks stuck.
    public var reasoning: String
    public var toolCalls: [String]
    public var outputTruncated: Bool
    public var failure: String?

    public init(
        id: UUID = UUID(),
        startedAt: Date = .now,
        method: String,
        path: String,
        model: String? = nil,
        client: String? = nil,
        prompt: String? = nil,
        status: Int? = nil,
        finishedAt: Date? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
        timings: ExchangeTimings? = nil,
        output: String = "",
        reasoning: String = "",
        toolCalls: [String] = [],
        outputTruncated: Bool = false,
        failure: String? = nil
    ) {
        self.id = id
        self.startedAt = startedAt
        self.method = method
        self.path = path
        self.model = model
        self.client = client
        self.prompt = prompt
        self.timings = timings
        self.status = status
        self.finishedAt = finishedAt
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.output = output
        self.reasoning = reasoning
        self.toolCalls = toolCalls
        self.outputTruncated = outputTruncated
        self.failure = failure
    }

    public var isActive: Bool { finishedAt == nil && failure == nil }

    /// Either the transport gave up or the server answered with an error.
    public var isFailure: Bool {
        failure != nil || (status.map { $0 >= 400 } ?? false)
    }

    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// Generation speed measured end to end, unlike the log's `tg` which excludes prompt handling.
    public var tokensPerSecond: Double? {
        guard let completionTokens, let duration, duration > 0 else { return nil }
        return Double(completionTokens) / duration
    }
}

/// Ollama's breakdown of where a request's time went.
public struct ExchangeTimings: Sendable, Equatable {
    /// Loading weights into memory. Zero when the model was already resident.
    public let load: TimeInterval
    /// Evaluating the prompt — grows with context and with cache misses.
    public let prompt: TimeInterval
    /// Producing tokens.
    public let generation: TimeInterval

    public init(load: TimeInterval, prompt: TimeInterval, generation: TimeInterval) {
        self.load = load
        self.prompt = prompt
        self.generation = generation
    }

    public var total: TimeInterval { load + prompt + generation }

    /// The share taken by the largest phase, and which one it was — this is the sentence a user
    /// actually wants: "78% of that was loading the model".
    public var dominantPhase: (name: String, share: Double)? {
        guard total > 0 else { return nil }
        let phases = [("load", load), ("prompt", prompt), ("generation", generation)]
        guard let largest = phases.max(by: { $0.1 < $1.1 }), largest.1 > 0 else { return nil }
        return (largest.0, largest.1 / total)
    }
}

/// Which stream a delta belongs to. Models that think out loud produce both at once.
public enum OutputKind: Sendable, Equatable {
    case content
    case reasoning
}

/// What the proxy reports while an exchange is in flight.
public enum ProxyEvent: Sendable {
    case started(ProxiedExchange)
    case responded(id: UUID, status: Int)
    case output(id: UUID, delta: String, kind: OutputKind)
    case toolCall(id: UUID, name: String)
    case completed(
        id: UUID,
        promptTokens: Int?,
        completionTokens: Int?,
        timings: ExchangeTimings?,
        at: Date
    )
    case failed(id: UUID, reason: String, at: Date)
}

public protocol ProxyEventSource: Sendable {
    func events() -> AsyncStream<ProxyEvent>
}
