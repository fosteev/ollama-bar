import Foundation
import Testing

import OllamaBarCore
@testable import OllamaBarInfrastructure

struct ConnectionSnifferTests {
    @Test func reconstructsAStreamingExchange() {
        let recorder = EventRecorder()
        let sniffer = ConnectionSniffer(emit: recorder.record)

        sniffer.clientBytes(Self.request(body: #"{"model":"qwen3.5:27b","stream":true}"#))
        sniffer.serverBytes(Self.streamingResponse(chunks: [
            #"{"message":{"content":"Hel"},"done":false}"# + "\n",
            #"{"message":{"content":"lo"},"done":false}"# + "\n",
            #"{"message":{"content":""},"done":true,"prompt_eval_count":12,"eval_count":2}"# + "\n",
        ]))

        let events = recorder.events
        guard case .started(let exchange)? = events.first else {
            Issue.record("expected the request to be reported, got \(events)")
            return
        }
        #expect(exchange.method == "POST")
        #expect(exchange.path == "/api/chat")
        #expect(exchange.model == "qwen3.5:27b")

        #expect(recorder.statuses == [200])
        #expect(recorder.text(kind: .content) == "Hello")
        #expect(recorder.completions.first?.prompt == 12)
        #expect(recorder.completions.first?.completion == 2)
    }

    /// The relay hands over whatever TCP gives it; message boundaries are not packet boundaries.
    @Test(arguments: [1, 4, 16, 64])
    func survivesArbitraryPacketBoundaries(packetSize: Int) {
        let recorder = EventRecorder()
        let sniffer = ConnectionSniffer(emit: recorder.record)

        let request = Self.request(body: #"{"model":"m"}"#)
        let response = Self.streamingResponse(chunks: [
            #"{"message":{"content":"abc"},"done":false}"# + "\n",
            #"{"done":true,"eval_count":1}"# + "\n",
        ])

        for slice in Self.slices(of: request, size: packetSize) { sniffer.clientBytes(slice) }
        for slice in Self.slices(of: response, size: packetSize) { sniffer.serverBytes(slice) }

        #expect(recorder.text(kind: .content) == "abc")
        #expect(recorder.completions.count == 1)
    }

    @Test func handlesTwoRequestsOnOneKeepAliveConnection() {
        let recorder = EventRecorder()
        let sniffer = ConnectionSniffer(emit: recorder.record)

        sniffer.clientBytes(Self.request(body: #"{"model":"first"}"#))
        sniffer.serverBytes(Self.streamingResponse(chunks: [#"{"response":"one","done":true}"# + "\n"]))
        sniffer.clientBytes(Self.request(body: #"{"model":"second"}"#))
        sniffer.serverBytes(Self.streamingResponse(chunks: [#"{"response":"two","done":true}"# + "\n"]))

        #expect(recorder.startedModels == ["first", "second"])
        #expect(recorder.text(kind: .content) == "onetwo")
        #expect(recorder.completions.count == 2)
    }

    @Test func nonStreamingResponseIsReportedWhenItCompletes() {
        let recorder = EventRecorder()
        let sniffer = ConnectionSniffer(emit: recorder.record)
        let body = #"{"message":{"content":"done thinking"},"done":true,"eval_count":4}"#

        sniffer.clientBytes(Self.request(body: #"{"model":"m","stream":false}"#))
        sniffer.serverBytes(Data("""
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """.utf8))

        #expect(recorder.text(kind: .content) == "done thinking")
        #expect(recorder.completions.first?.completion == 4)
    }

    @Test func abandonedRequestIsReportedAsFailed() {
        let recorder = EventRecorder()
        let sniffer = ConnectionSniffer(emit: recorder.record)

        sniffer.clientBytes(Self.request(body: #"{"model":"m"}"#))
        sniffer.closed(reason: "client went away")

        #expect(recorder.failures == ["client went away"])
    }

    @Test func requestsWithoutABodyStillCount() {
        let recorder = EventRecorder()
        let sniffer = ConnectionSniffer(emit: recorder.record)

        sniffer.clientBytes(Data("GET /api/tags HTTP/1.1\r\nHost: x\r\n\r\n".utf8))

        guard case .started(let exchange)? = recorder.events.first else {
            Issue.record("expected a GET to be reported")
            return
        }
        #expect(exchange.method == "GET")
        #expect(exchange.model == nil)
    }

    // MARK: - Raw messages

    private static func request(body: String) -> Data {
        Data("""
        POST /api/chat HTTP/1.1\r
        Host: 127.0.0.1:11435\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """.utf8)
    }

    private static func streamingResponse(chunks: [String]) -> Data {
        var raw = "HTTP/1.1 200 OK\r\nContent-Type: application/x-ndjson\r\nTransfer-Encoding: chunked\r\n\r\n"
        for chunk in chunks {
            raw += String(chunk.utf8.count, radix: 16) + "\r\n" + chunk + "\r\n"
        }
        raw += "0\r\n\r\n"
        return Data(raw.utf8)
    }

    private static func slices(of data: Data, size: Int) -> [Data] {
        stride(from: 0, to: data.count, by: size).map { offset in
            data.subdata(in: offset..<min(offset + size, data.count))
        }
    }
}

/// Collects what the sniffer reported so tests can assert on state rather than on call order.
private final class EventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProxyEvent] = []

    var record: @Sendable (ProxyEvent) -> Void {
        { [self] event in
            lock.lock()
            storage.append(event)
            lock.unlock()
        }
    }

    var events: [ProxyEvent] { lock.withLock { storage } }

    var startedModels: [String?] {
        events.compactMap { if case .started(let exchange) = $0 { exchange.model } else { nil } }
    }

    var statuses: [Int] {
        events.compactMap { if case .responded(_, let status) = $0 { status } else { nil } }
    }

    var failures: [String] {
        events.compactMap { if case .failed(_, let reason, _) = $0 { reason } else { nil } }
    }

    var completions: [(prompt: Int?, completion: Int?)] {
        events.compactMap {
            if case .completed(_, let prompt, let completion, _, _) = $0 { (prompt, completion) } else { nil }
        }
    }

    func text(kind: OutputKind) -> String {
        events.reduce(into: "") { result, event in
            if case .output(_, let delta, let eventKind) = event, eventKind == kind { result += delta }
        }
    }
}

/// Added with the redesign: the panel names the client and the output window shows the prompt,
/// so both have to survive the trip through the sniffer.
struct RequestDetailTests {
    @Test func clientAndPromptAreRecovered() {
        let recorder = DetailRecorder()
        let sniffer = ConnectionSniffer(emit: recorder.record)
        let body = #"{"model":"m","messages":[{"role":"system","content":"be brief"},{"role":"user","content":"hi"}]}"#

        sniffer.clientBytes(Data("""
        POST /api/chat HTTP/1.1\r
        Host: 127.0.0.1:11435\r
        User-Agent: codex-cli/0.42 (macOS)\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """.utf8))

        let exchange = recorder.started.first
        #expect(exchange??.client == "codex-cli/0.42 (macOS)")
        #expect(exchange??.prompt?.contains("system:") == true)
        #expect(exchange??.prompt?.contains("be brief") == true)
    }

    @Test func timingBreakdownComesOffTheFinalChunk() {
        let recorder = DetailRecorder()
        let sniffer = ConnectionSniffer(emit: recorder.record)
        let body = #"{"done":true,"total_duration":10857075542,"load_duration":8425290417,"prompt_eval_duration":1180582000,"eval_duration":1242550000}"#

        sniffer.clientBytes(Data("GET /api/chat HTTP/1.1\r\nHost: x\r\n\r\n".utf8))
        sniffer.serverBytes(Data("""
        HTTP/1.1 200 OK\r
        Content-Type: application/json\r
        Content-Length: \(body.utf8.count)\r
        \r
        \(body)
        """.utf8))

        let timings = recorder.timings.first ?? nil
        #expect(timings != nil)
        #expect(abs((timings?.load ?? 0) - 8.425) < 0.01)
        #expect(abs((timings?.prompt ?? 0) - 1.18) < 0.01)
        #expect(abs((timings?.generation ?? 0) - 1.243) < 0.01)
        #expect(timings?.dominantPhase?.name == "load")
    }
}

private final class DetailRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProxyEvent] = []

    var record: @Sendable (ProxyEvent) -> Void {
        { [self] event in
            lock.lock()
            storage.append(event)
            lock.unlock()
        }
    }

    private var events: [ProxyEvent] { lock.withLock { storage } }

    var started: [ProxiedExchange?] {
        events.compactMap { if case .started(let exchange) = $0 { exchange } else { nil } }
    }

    var timings: [ExchangeTimings?] {
        events.compactMap { if case .completed(_, _, _, let timings, _) = $0 { timings } else { nil } }
    }
}
