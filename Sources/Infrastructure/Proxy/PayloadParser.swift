import Foundation
import OllamaBarCore

/// What a decoded response body told us.
enum PayloadEvent: Equatable {
    case output(String, OutputKind)
    case toolCall(String)
    case usage(prompt: Int?, completion: Int?)
    case done
}

/// Reassembles model output from a response body.
///
/// Ollama speaks two dialects and this covers both, chosen by `Content-Type`:
/// newline-delimited JSON on `/api/*`, and SSE on the OpenAI-compatible `/v1/*` routes.
/// A single JSON object is the non-streaming case.
struct PayloadParser {
    enum Dialect: Equatable {
        case ndjson
        case serverSentEvents
        case singleJSON
        case opaque

        static func forContentType(_ contentType: String?) -> Dialect {
            guard let contentType = contentType?.lowercased() else { return .opaque }
            if contentType.contains("text/event-stream") { return .serverSentEvents }
            if contentType.contains("x-ndjson") { return .ndjson }
            if contentType.contains("application/json") { return .singleJSON }
            return .opaque
        }
    }

    private let dialect: Dialect
    private var buffer = Data()

    init(dialect: Dialect) {
        self.dialect = dialect
    }

    /// Feed decoded body bytes; get back whatever became complete.
    mutating func parse(_ incoming: Data) -> [PayloadEvent] {
        switch dialect {
        case .opaque:
            return []
        case .singleJSON:
            buffer.append(incoming)
            return []
        case .ndjson, .serverSentEvents:
            buffer.append(incoming)
            return drainLines()
        }
    }

    /// Called once the body is complete — the non-streaming case has nothing to emit until then.
    mutating func finish() -> [PayloadEvent] {
        guard case .singleJSON = dialect else { return [] }
        defer { buffer.removeAll() }
        guard let object = Self.json(from: buffer) else { return [] }
        return Self.events(from: object) + [.done]
    }

    private mutating func drainLines() -> [PayloadEvent] {
        var events: [PayloadEvent] = []
        while let newline = buffer.firstIndex(of: 0x0A) {
            let lineData = buffer[buffer.startIndex..<newline]
            buffer.removeSubrange(buffer.startIndex...newline)
            guard var line = String(data: lineData, encoding: .utf8)?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                  !line.isEmpty
            else { continue }

            if case .serverSentEvents = dialect {
                guard line.hasPrefix("data:") else { continue }
                line = String(line.dropFirst("data:".count)).trimmingCharacters(in: .whitespaces)
                if line == "[DONE]" {
                    events.append(.done)
                    continue
                }
            }

            guard let object = Self.json(from: Data(line.utf8)) else { continue }
            events.append(contentsOf: Self.events(from: object))
        }
        return events
    }

    private static func json(from data: Data) -> [String: Any]? {
        try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    // MARK: - Field extraction
    //
    // Key names differ between the native and OpenAI-compatible APIs, and a reasoning model puts
    // its thinking in yet another field. All of them are optional: a missing key means the dialect
    // does not use it, not that anything went wrong.

    static func events(from object: [String: Any]) -> [PayloadEvent] {
        var events: [PayloadEvent] = []

        // Native /api/chat and /api/generate.
        if let message = object["message"] as? [String: Any] {
            events += deltas(content: message["content"], reasoning: message["thinking"])
            events += toolCalls(in: message["tool_calls"])
        }
        if let response = object["response"] as? String, !response.isEmpty {
            events.append(.output(response, .content))
        }
        if let thinking = object["thinking"] as? String, !thinking.isEmpty {
            events.append(.output(thinking, .reasoning))
        }

        // OpenAI-compatible /v1/chat/completions.
        if let choices = object["choices"] as? [[String: Any]], let choice = choices.first {
            let payload = (choice["delta"] as? [String: Any])
                ?? (choice["message"] as? [String: Any])
            if let payload {
                events += deltas(content: payload["content"], reasoning: payload["reasoning"])
                events += toolCalls(in: payload["tool_calls"])
            }
        }

        if let usage = object["usage"] as? [String: Any] {
            events.append(
                .usage(prompt: usage["prompt_tokens"] as? Int, completion: usage["completion_tokens"] as? Int)
            )
        }
        if object["prompt_eval_count"] != nil || object["eval_count"] != nil {
            events.append(
                .usage(prompt: object["prompt_eval_count"] as? Int, completion: object["eval_count"] as? Int)
            )
        }
        if object["done"] as? Bool == true {
            events.append(.done)
        }
        return events
    }

    private static func deltas(content: Any?, reasoning: Any?) -> [PayloadEvent] {
        var events: [PayloadEvent] = []
        if let text = content as? String, !text.isEmpty {
            events.append(.output(text, .content))
        }
        if let text = reasoning as? String, !text.isEmpty {
            events.append(.output(text, .reasoning))
        }
        return events
    }

    private static func toolCalls(in value: Any?) -> [PayloadEvent] {
        guard let calls = value as? [[String: Any]] else { return [] }
        return calls.compactMap { call in
            guard let function = call["function"] as? [String: Any],
                  let name = function["name"] as? String
            else { return nil }
            return .toolCall(name)
        }
    }
}
