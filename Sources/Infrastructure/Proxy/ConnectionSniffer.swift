import Foundation
import OllamaBarCore

/// Watches one proxied connection and reconstructs the exchanges flowing over it.
///
/// It only ever sees a copy of the bytes. Every failure mode here is "stop reporting", never
/// "disturb the connection" — the relay does not consult this class for anything.
/// Confined to the proxy's serial queue — every entry point is called from there.
final class ConnectionSniffer: @unchecked Sendable {
    private let emit: @Sendable (ProxyEvent) -> Void

    private var requestBuffer = Data()
    private var request: RequestInProgress?
    /// Exchanges whose responses have not arrived yet, oldest first. HTTP/1.1 answers in order.
    private var awaitingResponse: [ProxiedExchange] = []

    private var responseBuffer = Data()
    private var response: ResponseInProgress?

    init(emit: @escaping @Sendable (ProxyEvent) -> Void) {
        self.emit = emit
    }

    // MARK: - Client → server

    func clientBytes(_ data: Data) {
        requestBuffer.append(data)

        while true {
            if request == nil {
                guard let head = HTTPStreamParser.takeHead(from: &requestBuffer),
                      let target = head.requestTarget
                else { return }
                request = RequestInProgress(
                    method: target.method,
                    path: target.path,
                    client: head.value("User-Agent"),
                    framing: HTTPStreamParser.framing(for: head, isResponse: false)
                )
            }

            guard var current = request else { return }
            let consumed = current.consume(&requestBuffer)
            request = current
            guard consumed else { return }

            finishRequest(current)
            request = nil
            if requestBuffer.isEmpty { return }
        }
    }

    private func finishRequest(_ request: RequestInProgress) {
        let exchange = ProxiedExchange(
            method: request.method,
            path: request.path,
            model: Self.model(in: request.body),
            client: request.client,
            prompt: Self.prompt(in: request.body)
        )
        awaitingResponse.append(exchange)
        emit(.started(exchange))
    }

    private static func model(in body: Data) -> String? {
        json(in: body)?["model"] as? String
    }

    /// What the client actually sent. Agents bury a lot in the system message, and until you can
    /// read it the context-overflow warning is just a number.
    private static func prompt(in body: Data) -> String? {
        guard let object = json(in: body) else { return nil }

        if let messages = object["messages"] as? [[String: Any]] {
            let text = messages.map { message in
                let role = message["role"] as? String ?? "?"
                let content = message["content"] as? String ?? ""
                return "\(role):\n\(content)"
            }.joined(separator: "\n\n")
            return String(text.prefix(maxRecordedPrompt))
        }
        if let prompt = object["prompt"] as? String {
            return String(prompt.prefix(maxRecordedPrompt))
        }
        return nil
    }

    private static let maxRecordedPrompt = 8000

    private static func json(in body: Data) -> [String: Any]? {
        guard !body.isEmpty else { return nil }
        return try? JSONSerialization.jsonObject(with: body) as? [String: Any]
    }

    // MARK: - Server → client

    func serverBytes(_ data: Data) {
        responseBuffer.append(data)

        while true {
            if response == nil {
                guard let head = HTTPStreamParser.takeHead(from: &responseBuffer) else { return }
                guard !awaitingResponse.isEmpty else {
                    // A response we never saw the request for — nothing to attribute it to.
                    responseBuffer.removeAll()
                    return
                }
                let exchange = awaitingResponse.removeFirst()
                let status = head.statusCode ?? 0
                emit(.responded(id: exchange.id, status: status))
                response = ResponseInProgress(
                    id: exchange.id,
                    framing: HTTPStreamParser.framing(for: head, isResponse: true),
                    parser: PayloadParser(
                        dialect: .forContentType(head.value("Content-Type"))
                    ),
                    contentEncoding: head.value("Content-Encoding")
                )
            }

            guard var current = response else { return }
            let complete = current.consume(&responseBuffer, emit: emit)
            response = current
            guard complete else { return }

            current.complete(emit: emit)
            response = nil
            if responseBuffer.isEmpty { return }
        }
    }

    /// The connection went away. Bodies framed by connection close end here, and anything still
    /// in flight is reported as failed rather than left hanging in the UI forever.
    func closed(reason: String? = nil) {
        if var current = response {
            if case .untilClose = current.framing {
                current.complete(emit: emit)
            } else {
                emit(.failed(id: current.id, reason: reason ?? "connection closed", at: .now))
            }
            response = nil
        }
        for exchange in awaitingResponse {
            emit(.failed(id: exchange.id, reason: reason ?? "connection closed", at: .now))
        }
        awaitingResponse.removeAll()
    }
}

// MARK: - Per-message state

private struct RequestInProgress {
    let method: String
    let path: String
    let client: String?
    var framing: HTTPStreamParser.BodyFraming
    var body = Data()
    private var remaining: Int?
    private var chunked = ChunkedDecoder()

    init(method: String, path: String, client: String?, framing: HTTPStreamParser.BodyFraming) {
        self.method = method
        self.path = path
        self.client = client
        self.framing = framing
        if case .length(let length) = framing { remaining = length }
    }

    /// Returns true once the whole body has been seen.
    mutating func consume(_ buffer: inout Data) -> Bool {
        switch framing {
        case .none:
            return true

        case .length:
            guard var remaining = remaining else { return true }
            let take = min(remaining, buffer.count)
            append(buffer.prefix(take))
            buffer.removeFirst(take)
            remaining -= take
            self.remaining = remaining
            return remaining == 0

        case .chunked:
            append(chunked.decode(buffer))
            buffer.removeAll()
            return chunked.isFinished

        case .untilClose:
            append(buffer)
            buffer.removeAll()
            return false
        }
    }

    private mutating func append(_ data: some DataProtocol) {
        guard body.count < ConnectionSnifferLimits.maxRequestBody else { return }
        body.append(contentsOf: data)
    }
}

private enum ConnectionSnifferLimits {
    /// Request bodies are read only to learn the model name; anything larger is not worth keeping.
    static let maxRequestBody = 1 << 20
}

private struct ResponseInProgress {
    let id: UUID
    let framing: HTTPStreamParser.BodyFraming
    var parser: PayloadParser
    private var remaining: Int?
    private var chunked = ChunkedDecoder()
    private var promptTokens: Int?
    private var completionTokens: Int?
    private var timings: ExchangeTimings?
    private let inflater: GzipInflater?
    /// The body is compressed in a way we cannot read. The relay still forwards it perfectly; we
    /// just stop pretending the bytes are text.
    private let unreadable: Bool

    init(
        id: UUID,
        framing: HTTPStreamParser.BodyFraming,
        parser: PayloadParser,
        contentEncoding: String? = nil
    ) {
        self.id = id
        self.framing = framing
        self.parser = parser
        if case .length(let length) = framing { remaining = length }

        switch contentEncoding?.lowercased().trimmingCharacters(in: .whitespaces) {
        case nil, "", "identity":
            inflater = nil
            unreadable = false
        case "gzip", "x-gzip":
            let inflater = GzipInflater()
            self.inflater = inflater
            unreadable = inflater == nil
        default:
            // br, zstd, and zlib-wrapped deflate. Clients of Ollama do not ask for these today.
            inflater = nil
            unreadable = true
        }
    }

    mutating func consume(_ buffer: inout Data, emit: (ProxyEvent) -> Void) -> Bool {
        var payload = Data()
        var complete = false

        switch framing {
        case .none:
            complete = true

        case .length:
            guard var remaining = remaining else { return true }
            let take = min(remaining, buffer.count)
            payload = Data(buffer.prefix(take))
            buffer.removeFirst(take)
            remaining -= take
            self.remaining = remaining
            complete = remaining == 0

        case .chunked:
            payload = chunked.decode(buffer)
            buffer.removeAll()
            complete = chunked.isFinished

        case .untilClose:
            payload = buffer
            buffer.removeAll()
        }

        if !payload.isEmpty, !unreadable {
            let decoded = inflater.map { $0.inflate(payload) } ?? payload
            if !decoded.isEmpty { forward(parser.parse(decoded), emit: emit) }
        }
        return complete
    }

    mutating func complete(emit: (ProxyEvent) -> Void) {
        forward(parser.finish(), emit: emit)
        emit(
            .completed(
                id: id,
                promptTokens: promptTokens,
                completionTokens: completionTokens,
                timings: timings,
                at: .now
            )
        )
    }

    private mutating func forward(_ events: [PayloadEvent], emit: (ProxyEvent) -> Void) {
        for event in events {
            switch event {
            case .output(let text, let kind):
                emit(.output(id: id, delta: text, kind: kind))
            case .toolCall(let name):
                emit(.toolCall(id: id, name: name))
            case .usage(let prompt, let completion):
                promptTokens = prompt ?? promptTokens
                completionTokens = completion ?? completionTokens
            case .timings(let value):
                timings = value
            case .done:
                break
            }
        }
    }
}
