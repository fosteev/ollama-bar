import Foundation
import Testing

@testable import OllamaBarCore

@MainActor
struct ProxyExchangeTests {
    @Test func exchangeIsBuiltUpAcrossItsLifetime() {
        let monitor = OllamaMonitor()
        let started = ProxiedExchange(method: "POST", path: "/api/chat", model: "m")

        monitor.apply(.started(started))
        monitor.apply(.responded(id: started.id, status: 200))
        monitor.apply(.output(id: started.id, delta: "Hel", kind: .content))
        monitor.apply(.output(id: started.id, delta: "lo", kind: .content))
        monitor.apply(.output(id: started.id, delta: "hmm", kind: .reasoning))
        monitor.apply(.toolCall(id: started.id, name: "get_time"))

        let exchange = monitor.exchanges.first
        #expect(exchange?.status == 200)
        #expect(exchange?.output == "Hello")
        #expect(exchange?.reasoning == "hmm")
        #expect(exchange?.toolCalls == ["get_time"])
        #expect(monitor.activeExchange?.id == started.id)
    }

    @Test func completionEndsTheExchangeAndRecordsUsage() {
        let monitor = OllamaMonitor()
        let started = ProxiedExchange(startedAt: Date(), method: "POST", path: "/api/chat")
        monitor.apply(.started(started))
        monitor.apply(.responded(id: started.id, status: 200))

        monitor.apply(
            .completed(
                id: started.id,
                promptTokens: 12,
                completionTokens: 8,
                timings: ExchangeTimings(load: 0, prompt: 0.4, generation: 1.6),
                at: started.startedAt.addingTimeInterval(2)
            )
        )

        let exchange = monitor.exchanges.first
        #expect(exchange?.promptTokens == 12)
        #expect(exchange?.completionTokens == 8)
        #expect(exchange?.isActive == false)
        #expect(exchange?.tokensPerSecond == 4)
        #expect(monitor.activeExchange == nil)
    }

    @Test func failureIsRecordedRatherThanLeftHanging() {
        let monitor = OllamaMonitor()
        let started = ProxiedExchange(method: "POST", path: "/api/chat")
        monitor.apply(.started(started))

        monitor.apply(.failed(id: started.id, reason: "connection closed", at: .now))

        #expect(monitor.exchanges.first?.failure == "connection closed")
        #expect(monitor.exchanges.first?.isActive == false)
        #expect(monitor.activeExchange == nil)
    }

    /// A single completion can be enormous, and several can be in flight at once.
    @Test func outputIsCappedInsteadOfGrowingWithoutBound() {
        let monitor = OllamaMonitor()
        let started = ProxiedExchange(method: "POST", path: "/api/chat")
        monitor.apply(.started(started))

        let block = String(repeating: "x", count: 4096)
        for _ in 0..<20 {
            monitor.apply(.output(id: started.id, delta: block, kind: .content))
        }

        let exchange = monitor.exchanges.first
        #expect(exchange?.outputTruncated == true)
        #expect((exchange?.output.utf8.count ?? 0) <= OllamaMonitor.outputLimit + block.utf8.count)
    }

    @Test func historyIsCapped() {
        let monitor = OllamaMonitor()
        let overflow = OllamaMonitor.exchangeHistoryLimit + 5

        for index in 0..<overflow {
            monitor.apply(.started(ProxiedExchange(method: "POST", path: "/req/\(index)")))
        }

        #expect(monitor.exchanges.count == OllamaMonitor.exchangeHistoryLimit)
        #expect(monitor.exchanges.last?.path == "/req/\(overflow - 1)")
    }

    /// Events for an exchange that already fell out of the history must not crash or resurrect it.
    @Test func eventsForForgottenExchangesAreIgnored() {
        let monitor = OllamaMonitor()
        let evicted = ProxiedExchange(method: "POST", path: "/gone")
        monitor.apply(.started(evicted))
        for index in 0..<OllamaMonitor.exchangeHistoryLimit {
            monitor.apply(.started(ProxiedExchange(method: "POST", path: "/req/\(index)")))
        }

        monitor.apply(.output(id: evicted.id, delta: "late", kind: .content))

        #expect(monitor.exchanges.allSatisfy { $0.path != "/gone" })
        #expect(monitor.exchanges.count == OllamaMonitor.exchangeHistoryLimit)
    }

    /// Until the response head arrives there is nothing to show, so the panel should stay quiet.
    @Test func requestWithoutAResponseIsNotShownAsActive() {
        let monitor = OllamaMonitor()
        monitor.apply(.started(ProxiedExchange(method: "POST", path: "/api/chat")))

        #expect(monitor.activeExchange == nil)
    }
}
