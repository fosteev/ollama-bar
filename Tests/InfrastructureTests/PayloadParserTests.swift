import Foundation
import Testing

import OllamaBarCore
@testable import OllamaBarInfrastructure

struct PayloadParserTests {
    /// Recorded from a live `/api/chat` stream — the model in question also emits thinking tokens.
    @Test func readsNativeStreamingChat() throws {
        var parser = PayloadParser(dialect: .ndjson)
        let events = parser.parse(try Fixtures.data("stream-api-chat.ndjson"))

        let reasoning = Self.text(in: events, kind: .reasoning)
        #expect(!reasoning.isEmpty, "the fixture is a thinking model; reasoning must survive")
        #expect(events.contains(.usage(prompt: 12, completion: 8)))
        #expect(events.contains(.done))
    }

    @Test func readsOpenAIStreamingChat() throws {
        var parser = PayloadParser(dialect: .serverSentEvents)
        let events = parser.parse(try Fixtures.data("stream-openai-chat.sse"))

        #expect(!Self.text(in: events, kind: .reasoning).isEmpty)
        #expect(events.contains(.usage(prompt: 12, completion: 8)))
        #expect(events.contains(.done))
    }

    @Test func nonStreamingBodyIsReportedOnlyOnceComplete() {
        let body = Data("""
        {"model":"m","message":{"role":"assistant","content":"hello"},"done":true,
         "prompt_eval_count":3,"eval_count":2}
        """.utf8)

        var parser = PayloadParser(dialect: .singleJSON)
        #expect(parser.parse(body).isEmpty)

        let events = parser.finish()
        #expect(events.contains(.output("hello", .content)))
        #expect(events.contains(.usage(prompt: 3, completion: 2)))
    }

    @Test func generateEndpointUsesADifferentKey() {
        var parser = PayloadParser(dialect: .ndjson)
        let events = parser.parse(Data("{\"response\":\"tok\",\"done\":false}\n".utf8))

        #expect(events == [.output("tok", .content)])
    }

    @Test func toolCallsAreNoticed() {
        var parser = PayloadParser(dialect: .ndjson)
        let line = """
        {"message":{"role":"assistant","content":"","tool_calls":[{"function":{"name":"get_time","arguments":{}}}]},"done":false}
        """
        let events = parser.parse(Data((line + "\n").utf8))

        #expect(events == [.toolCall("get_time")])
    }

    /// Deltas arrive split across TCP packets; a JSON line cut in half must not be lost.
    @Test func linesSplitAcrossPacketsAreReassembled() {
        var parser = PayloadParser(dialect: .ndjson)
        let line = "{\"response\":\"hello\",\"done\":false}\n"
        let bytes = Array(line.utf8)

        var events: [PayloadEvent] = []
        for index in stride(from: 0, to: bytes.count, by: 7) {
            events += parser.parse(Data(bytes[index..<min(index + 7, bytes.count)]))
        }

        #expect(events == [.output("hello", .content)])
    }

    @Test func unparseableLinesAreSkippedRatherThanFatal() {
        var parser = PayloadParser(dialect: .ndjson)
        let events = parser.parse(Data("not json at all\n{\"response\":\"ok\",\"done\":false}\n".utf8))

        #expect(events == [.output("ok", .content)])
    }

    @Test func opaqueBodiesAreIgnored() {
        var parser = PayloadParser(dialect: .forContentType("application/octet-stream"))
        #expect(parser.parse(Data("anything".utf8)).isEmpty)
    }

    @Test(arguments: [
        ("text/event-stream", PayloadParser.Dialect.serverSentEvents),
        ("application/x-ndjson", .ndjson),
        ("application/json; charset=utf-8", .singleJSON),
        ("text/plain", .opaque),
    ])
    func dialectFollowsContentType(contentType: String, expected: PayloadParser.Dialect) {
        #expect(PayloadParser.Dialect.forContentType(contentType) == expected)
    }

    private static func text(in events: [PayloadEvent], kind: OutputKind) -> String {
        events.reduce(into: "") { result, event in
            if case .output(let text, let eventKind) = event, eventKind == kind { result += text }
        }
    }
}
