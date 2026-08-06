import Foundation
import Network
import Testing

import OllamaBarCore
@testable import OllamaBarInfrastructure

/// The proxy sits in the path of real agent runs, so the bar is not "it mostly works" but
/// "the client cannot tell the difference". These tests compare a proxied request against the
/// same request made directly to the origin.
struct ProxyServerTests {
    @Test func proxiedResponseIsIdenticalToTheDirectOne() async throws {
        let origin = StubOrigin(response: Self.streamingResponse)
        let originPort = try await origin.start()
        defer { origin.stop() }

        let proxy = ProxyServer(listenPort: 0, upstreamHost: "127.0.0.1", upstreamPort: originPort)
        proxy.start()
        defer { proxy.stop() }
        let proxyPort = try await Self.runningPort(of: proxy)

        let direct = try await Self.post(port: originPort, body: Self.requestBody)
        let proxied = try await Self.post(port: proxyPort, body: Self.requestBody)

        #expect(direct.status == proxied.status)
        #expect(direct.body == proxied.body)
        #expect(direct.headers == proxied.headers)
    }

    @Test func upstreamSeesTheRequestUnchanged() async throws {
        let origin = StubOrigin(response: Self.streamingResponse)
        let originPort = try await origin.start()
        defer { origin.stop() }

        let proxy = ProxyServer(listenPort: 0, upstreamHost: "127.0.0.1", upstreamPort: originPort)
        proxy.start()
        defer { proxy.stop() }
        let proxyPort = try await Self.runningPort(of: proxy)

        _ = try await Self.post(port: originPort, body: Self.requestBody)
        _ = try await Self.post(port: proxyPort, body: Self.requestBody)

        let received = origin.requests
        #expect(received.count == 2)
        // Only the Host header may differ — it names the port the client dialled.
        let normalized = received.map { raw in
            raw.split(separator: "\r\n")
                .filter { !$0.lowercased().hasPrefix("host:") }
                .joined(separator: "\r\n")
        }
        #expect(normalized[0] == normalized[1])
    }

    @Test func exchangeIsReconstructedFromTheCopiedBytes() async throws {
        let origin = StubOrigin(response: Self.streamingResponse)
        let originPort = try await origin.start()
        defer { origin.stop() }

        let proxy = ProxyServer(listenPort: 0, upstreamHost: "127.0.0.1", upstreamPort: originPort)
        let recorder = ProxyEventRecorder()
        let consumer = Task { for await event in proxy.events() { recorder.record(event) } }
        defer { consumer.cancel() }

        proxy.start()
        defer { proxy.stop() }
        let proxyPort = try await Self.runningPort(of: proxy)

        _ = try await Self.post(port: proxyPort, body: Self.requestBody)
        try await recorder.waitForCompletion()

        #expect(recorder.paths == ["/api/chat"])
        #expect(recorder.models == ["test-model"])
        #expect(recorder.statuses == [200])
        #expect(recorder.content == "Hello there")
        #expect(recorder.completions.first?.prompt == 12)
        #expect(recorder.completions.first?.completion == 3)
    }

    /// An upstream that is not there must surface as a failed connection, not a hang.
    @Test func deadUpstreamFailsFast() async throws {
        let proxy = ProxyServer(listenPort: 0, upstreamHost: "127.0.0.1", upstreamPort: 1)
        proxy.start()
        defer { proxy.stop() }
        let proxyPort = try await Self.runningPort(of: proxy)

        await #expect(throws: (any Error).self) {
            _ = try await Self.post(port: proxyPort, body: Self.requestBody, timeout: 5)
        }
    }

    // MARK: - Fixtures and helpers

    private static let requestBody = Data(#"{"model":"test-model","stream":true}"#.utf8)

    private static var streamingResponse: Data {
        let chunks = [
            #"{"message":{"content":"Hello"},"done":false}"# + "\n",
            #"{"message":{"content":" there"},"done":false}"# + "\n",
            #"{"done":true,"prompt_eval_count":12,"eval_count":3}"# + "\n",
        ]
        var raw = "HTTP/1.1 200 OK\r\n"
        raw += "Content-Type: application/x-ndjson\r\n"
        raw += "Transfer-Encoding: chunked\r\n\r\n"
        for chunk in chunks {
            raw += String(chunk.utf8.count, radix: 16) + "\r\n" + chunk + "\r\n"
        }
        raw += "0\r\n\r\n"
        return Data(raw.utf8)
    }

    private static func runningPort(of proxy: ProxyServer) async throws -> UInt16 {
        for _ in 0..<200 {
            if case .running(let port) = proxy.state { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProxyTestError.timedOut("proxy never became ready")
    }

    private static func post(
        port: UInt16,
        body: Data,
        timeout: TimeInterval = 10
    ) async throws -> (status: Int, headers: [String: String], body: Data) {
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(port)/api/chat")!)
        request.httpMethod = "POST"
        request.httpBody = body
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")

        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        let session = URLSession(configuration: configuration)
        defer { session.invalidateAndCancel() }

        let (data, response) = try await session.data(for: request)
        let http = response as! HTTPURLResponse
        let headers = Dictionary(
            uniqueKeysWithValues: http.allHeaderFields.map { (String(describing: $0.key), String(describing: $0.value)) }
        )
        return (http.statusCode, headers, data)
    }
}

private enum ProxyTestError: Error {
    case timedOut(String)
}

/// A minimal HTTP origin that replies with one canned response per connection.
private final class StubOrigin: @unchecked Sendable {
    private let response: Data
    private let queue = DispatchQueue(label: "stub-origin")
    private var listener: NWListener?
    private let lock = NSLock()
    private var received: [String] = []

    init(response: Data) {
        self.response = response
    }

    var requests: [String] { lock.withLock { received } }

    func start() async throws -> UInt16 {
        let parameters = NWParameters.tcp
        parameters.allowLocalEndpointReuse = true
        let listener = try NWListener(using: parameters, on: .any)
        listener.newConnectionHandler = { [weak self] connection in self?.serve(connection) }
        listener.start(queue: queue)
        self.listener = listener

        for _ in 0..<200 {
            if case .ready = listener.state, let port = listener.port?.rawValue { return port }
            try await Task.sleep(for: .milliseconds(10))
        }
        throw ProxyTestError.timedOut("origin never became ready")
    }

    func stop() {
        listener?.cancel()
        listener = nil
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        read(connection, accumulated: Data())
    }

    private func read(_ connection: NWConnection, accumulated: Data) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64 * 1024) {
            [weak self] data, _, isComplete, _ in
            guard let self else { return }

            var buffer = accumulated
            if let data { buffer.append(data) }

            if Self.isCompleteRequest(buffer) {
                self.lock.withLock {
                    self.received.append(String(data: buffer, encoding: .utf8) ?? "")
                }
                connection.send(content: self.response, completion: .contentProcessed { _ in
                    connection.send(content: nil, isComplete: true, completion: .contentProcessed { _ in })
                })
                return
            }
            if isComplete { return }
            self.read(connection, accumulated: buffer)
        }
    }

    private static func isCompleteRequest(_ buffer: Data) -> Bool {
        guard let headEnd = buffer.range(of: Data("\r\n\r\n".utf8)) else { return false }
        let head = String(data: buffer[..<headEnd.lowerBound], encoding: .utf8) ?? ""
        let contentLength = head.split(separator: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        return buffer.count - headEnd.upperBound >= contentLength
    }
}

private final class ProxyEventRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [ProxyEvent] = []

    func record(_ event: ProxyEvent) {
        lock.lock()
        events.append(event)
        lock.unlock()
    }

    private var snapshot: [ProxyEvent] { lock.withLock { events } }

    var paths: [String] {
        snapshot.compactMap { if case .started(let exchange) = $0 { exchange.path } else { nil } }
    }

    var models: [String?] {
        snapshot.compactMap { if case .started(let exchange) = $0 { exchange.model } else { nil } }
    }

    var statuses: [Int] {
        snapshot.compactMap { if case .responded(_, let status) = $0 { status } else { nil } }
    }

    var completions: [(prompt: Int?, completion: Int?)] {
        snapshot.compactMap {
            if case .completed(_, let prompt, let completion, _) = $0 { (prompt, completion) } else { nil }
        }
    }

    var content: String {
        snapshot.reduce(into: "") { result, event in
            if case .output(_, let delta, .content) = event { result += delta }
        }
    }

    /// Events arrive on the proxy queue slightly after the HTTP client is done.
    func waitForCompletion(timeout: Duration = .seconds(5)) async throws {
        let deadline = ContinuousClock.now + timeout
        while ContinuousClock.now < deadline {
            if !completions.isEmpty { return }
            try await Task.sleep(for: .milliseconds(20))
        }
        throw ProxyTestError.timedOut("no completion event")
    }
}
