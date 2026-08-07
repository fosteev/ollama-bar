import Foundation
import OllamaBarCore

/// How an exchange ended, as far as the recorder could tell.
public enum ExchangeOutcome: String, Codable, Sendable {
    case ok
    case failed
    /// The history limit evicted it while it was still streaming — we never saw the end.
    case abandoned
}

/// One line of the day index. Deliberately not `ProxiedExchange` itself: the file format is a
/// versioned contract that must survive renames in the live struct, and the mapping is not 1:1 —
/// the texts move to a body file and the tool calls collapse to a count. That is what keeps a
/// day's totals cheap: they never open a body.
public struct ExchangeRecord: Codable, Sendable, Equatable, Identifiable {
    public static let currentVersion = 1
    /// Enough for a transport error; anything longer is a stack trace we do not want on disk.
    static let failureLimit = 500

    public let version: Int
    public let id: UUID
    public let startedAt: Date
    public let finishedAt: Date?
    public let method: String
    public let path: String
    public let model: String?
    public let client: String?
    public let status: Int?
    public let outcome: ExchangeOutcome
    public let promptTokens: Int?
    public let completionTokens: Int?
    public let loadSeconds: Double?
    public let promptSeconds: Double?
    public let genSeconds: Double?
    /// A count, not the names. The names live in the body.
    public let toolCalls: Int
    public let truncated: Bool
    public let failure: String?
    public let hasBody: Bool

    enum CodingKeys: String, CodingKey {
        case version = "v"
        case hasBody = "body"
        case id, startedAt, finishedAt, method, path, model, client, status, outcome
        case promptTokens, completionTokens, loadSeconds, promptSeconds, genSeconds
        case toolCalls, truncated, failure
    }

    public init(_ exchange: ProxiedExchange, outcome: ExchangeOutcome, hasBody: Bool) {
        self.version = Self.currentVersion
        self.id = exchange.id
        self.startedAt = exchange.startedAt
        self.finishedAt = exchange.finishedAt
        self.method = exchange.method
        self.path = exchange.path
        self.model = exchange.model
        self.client = exchange.client
        self.status = exchange.status
        self.outcome = outcome
        self.promptTokens = exchange.promptTokens
        self.completionTokens = exchange.completionTokens
        self.loadSeconds = exchange.timings?.load
        self.promptSeconds = exchange.timings?.prompt
        self.genSeconds = exchange.timings?.generation
        self.toolCalls = exchange.toolCalls.count
        self.truncated = exchange.outputTruncated
        self.failure = exchange.failure.map { String($0.prefix(Self.failureLimit)) }
        self.hasBody = hasBody
    }

    /// Back into the type the history table speaks. Texts stay empty — they are loaded lazily
    /// from the body file only when a row is selected.
    public var exchange: ProxiedExchange {
        ProxiedExchange(
            id: id,
            startedAt: startedAt,
            method: method,
            path: path,
            model: model,
            client: client,
            prompt: nil,
            status: status,
            finishedAt: finishedAt,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            timings: timings,
            output: "",
            reasoning: "",
            toolCalls: [],
            outputTruncated: truncated,
            // Without this an abandoned row would read as still running, forever.
            failure: outcome == .abandoned ? (failure ?? "abandoned while in flight") : failure
        )
    }

    private var timings: ExchangeTimings? {
        guard let loadSeconds, let promptSeconds, let genSeconds else { return nil }
        return ExchangeTimings(load: loadSeconds, prompt: promptSeconds, generation: genSeconds)
    }
}

/// The expensive half, kept out of the index so scanning a day stays cheap.
public struct ExchangeBody: Codable, Sendable, Equatable {
    public let id: UUID
    public let prompt: String?
    public let output: String
    public let reasoning: String
    public let toolCalls: [String]

    public init(_ exchange: ProxiedExchange) {
        self.id = exchange.id
        self.prompt = exchange.prompt
        self.output = exchange.output
        self.reasoning = exchange.reasoning
        self.toolCalls = exchange.toolCalls
    }

    /// Inventory polls and `/api/tags` carry nothing worth a file of their own.
    public var isEmpty: Bool {
        (prompt?.isEmpty ?? true) && output.isEmpty && reasoning.isEmpty && toolCalls.isEmpty
    }
}

public struct ModelTotals: Sendable, Equatable {
    public let model: String?
    public let requests: Int
    public let promptTokens: Int
    public let completionTokens: Int

    public init(model: String?, requests: Int, promptTokens: Int, completionTokens: Int) {
        self.model = model
        self.requests = requests
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
    }
}

/// What a single day cost, summed straight from the index.
public struct DayTotals: Sendable, Equatable {
    public let day: Date
    public let requests: Int
    public let failures: Int
    public let promptTokens: Int
    public let completionTokens: Int
    public let duration: TimeInterval
    /// Of that duration, how much went into loading weights rather than answering.
    public let loadTime: TimeInterval
    public let byModel: [ModelTotals]

    public init(
        day: Date,
        requests: Int,
        failures: Int,
        promptTokens: Int,
        completionTokens: Int,
        duration: TimeInterval,
        loadTime: TimeInterval,
        byModel: [ModelTotals]
    ) {
        self.day = day
        self.requests = requests
        self.failures = failures
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.duration = duration
        self.loadTime = loadTime
        self.byModel = byModel
    }

    public static func empty(day: Date) -> DayTotals {
        DayTotals(
            day: day,
            requests: 0,
            failures: 0,
            promptTokens: 0,
            completionTokens: 0,
            duration: 0,
            loadTime: 0,
            byModel: []
        )
    }

    static func summing(_ records: [ExchangeRecord], day: Date) -> DayTotals {
        var byModel: [String?: (requests: Int, prompt: Int, completion: Int)] = [:]
        var failures = 0
        var promptTokens = 0
        var completionTokens = 0
        var duration: TimeInterval = 0
        var loadTime: TimeInterval = 0

        for record in records {
            if record.outcome != .ok { failures += 1 }
            promptTokens += record.promptTokens ?? 0
            completionTokens += record.completionTokens ?? 0
            if let finishedAt = record.finishedAt {
                duration += finishedAt.timeIntervalSince(record.startedAt)
            }
            loadTime += record.loadSeconds ?? 0

            var bucket = byModel[record.model] ?? (0, 0, 0)
            bucket.requests += 1
            bucket.prompt += record.promptTokens ?? 0
            bucket.completion += record.completionTokens ?? 0
            byModel[record.model] = bucket
        }

        let models = byModel
            .map {
                ModelTotals(
                    model: $0.key,
                    requests: $0.value.requests,
                    promptTokens: $0.value.prompt,
                    completionTokens: $0.value.completion
                )
            }
            .sorted { ($0.requests, $0.model ?? "") > ($1.requests, $1.model ?? "") }

        return DayTotals(
            day: day,
            requests: records.count,
            failures: failures,
            promptTokens: promptTokens,
            completionTokens: completionTokens,
            duration: duration,
            loadTime: loadTime,
            byModel: models
        )
    }
}

/// One encoder and one decoder for the whole store. `ISO8601FormatStyle` is a value type, unlike
/// `ISO8601DateFormatter`, which would allocate once per timestamp — thousands of times when
/// parsing a day.
enum HistoryCoding {
    private static let dateStyle = Date.ISO8601FormatStyle(includingFractionalSeconds: true)

    static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        encoder.dateEncodingStrategy = .custom { date, encoder in
            var container = encoder.singleValueContainer()
            try container.encode(date.formatted(dateStyle))
        }
        return encoder
    }()

    static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .custom { decoder in
            let container = try decoder.singleValueContainer()
            let text = try container.decode(String.self)
            guard let date = try? Date(text, strategy: dateStyle) else {
                throw DecodingError.dataCorruptedError(
                    in: container,
                    debugDescription: "not an ISO 8601 timestamp: \(text)"
                )
            }
            return date
        }
        return decoder
    }()
}
