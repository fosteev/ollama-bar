import Foundation

/// One request seen through the proxy, from the request line to the last streamed token.
public struct ProxiedExchange: Sendable, Identifiable, Equatable {
    public let id: UUID
    public let startedAt: Date
    public let method: String
    public let path: String
    /// Taken from the request body when it is JSON with a `model` field.
    public let model: String?

    public var status: Int?
    public var finishedAt: Date?
    public var promptTokens: Int?
    public var completionTokens: Int?
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
        status: Int? = nil,
        finishedAt: Date? = nil,
        promptTokens: Int? = nil,
        completionTokens: Int? = nil,
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

    public var duration: TimeInterval? {
        finishedAt.map { $0.timeIntervalSince(startedAt) }
    }

    /// Generation speed measured end to end, unlike the log's `tg` which excludes prompt handling.
    public var tokensPerSecond: Double? {
        guard let completionTokens, let duration, duration > 0 else { return nil }
        return Double(completionTokens) / duration
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
    case completed(id: UUID, promptTokens: Int?, completionTokens: Int?, at: Date)
    case failed(id: UUID, reason: String, at: Date)
}

public protocol ProxyEventSource: Sendable {
    func events() -> AsyncStream<ProxyEvent>
}
