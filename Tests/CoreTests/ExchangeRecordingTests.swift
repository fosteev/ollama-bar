import Foundation
import Testing

@testable import OllamaBarCore

/// The monitor's job in persistence is narrow: say which exchanges left the live set, and say it
/// exactly once. Everything downstream trusts that.
@MainActor
struct ExchangeRecordingTests {
    @Test func terminalEventsReportTheFinishedExchange() {
        let monitor = OllamaMonitor()
        let started = ProxiedExchange(method: "POST", path: "/api/chat", model: "m")

        #expect(monitor.apply(.started(started)).isEmpty)
        #expect(monitor.apply(.responded(id: started.id, status: 200)).isEmpty)
        #expect(monitor.apply(.output(id: started.id, delta: "hi", kind: .content)).isEmpty)
        #expect(monitor.apply(.toolCall(id: started.id, name: "get_time")).isEmpty)

        let finished = monitor.apply(
            .completed(
                id: started.id,
                promptTokens: 12,
                completionTokens: 8,
                timings: ExchangeTimings(load: 1, prompt: 0.4, generation: 1.6),
                at: started.startedAt.addingTimeInterval(2)
            )
        )

        #expect(finished.count == 1)
        #expect(finished.first?.id == started.id)
        #expect(finished.first?.completionTokens == 8)
        #expect(finished.first?.timings?.load == 1)
    }

    @Test func failureIsReportedToo() {
        let monitor = OllamaMonitor()
        let started = ProxiedExchange(method: "POST", path: "/api/chat")
        monitor.apply(.started(started))

        let finished = monitor.apply(.failed(id: started.id, reason: "connection closed", at: .now))

        #expect(finished.count == 1)
        #expect(finished.first?.failure == "connection closed")
    }

    @Test func eventsForAnUnknownExchangeReportNothing() {
        let monitor = OllamaMonitor()
        #expect(monitor.apply(.completed(
            id: UUID(),
            promptTokens: nil,
            completionTokens: nil,
            timings: nil,
            at: .now
        )).isEmpty)
    }

    /// The one path where data used to vanish silently: an exchange still streaming when the
    /// history limit pushes it out.
    @Test func evictionReportsTheExchangeItDrops() {
        let monitor = OllamaMonitor()
        let first = ProxiedExchange(method: "POST", path: "/api/chat", model: "m")
        monitor.apply(.started(first))
        for _ in 1..<OllamaMonitor.exchangeHistoryLimit {
            monitor.apply(.started(ProxiedExchange(method: "POST", path: "/api/chat")))
        }

        let evicted = monitor.apply(.started(ProxiedExchange(method: "POST", path: "/api/chat")))

        #expect(evicted.count == 1)
        #expect(evicted.first?.id == first.id)
        #expect(monitor.exchanges.count == OllamaMonitor.exchangeHistoryLimit)
        #expect(!monitor.exchanges.contains { $0.id == first.id })
    }

    @Test func evictionDoesNotReportAnAlreadyFinishedExchange() {
        let monitor = OllamaMonitor()
        let first = ProxiedExchange(method: "POST", path: "/api/chat")
        monitor.apply(.started(first))
        // Reported once here; reporting it again on eviction would write it twice.
        monitor.apply(.completed(
            id: first.id,
            promptTokens: 1,
            completionTokens: 1,
            timings: nil,
            at: .now
        ))
        for _ in 1..<OllamaMonitor.exchangeHistoryLimit {
            monitor.apply(.started(ProxiedExchange(method: "POST", path: "/api/chat")))
        }

        #expect(monitor.apply(.started(ProxiedExchange(method: "POST", path: "/api/chat"))).isEmpty)
    }

    @Test func driverForwardsFinishedExchangesToTheRecorder() async {
        let monitor = OllamaMonitor()
        let exchange = ProxiedExchange(method: "POST", path: "/api/chat", model: "m")
        let recorder = SpyRecorder()
        let proxy = ScriptedProxy(script: [
            .started(exchange),
            .responded(id: exchange.id, status: 200),
            .output(id: exchange.id, delta: "hi", kind: .content),
            .completed(
                id: exchange.id,
                promptTokens: 3,
                completionTokens: 4,
                timings: nil,
                at: .now
            ),
        ])
        let driver = MonitorDriver(
            monitor: monitor,
            inventory: SilentInventory(),
            events: SilentLog(),
            proxy: proxy,
            recorder: recorder
        )

        driver.start()
        await recorder.waitForRecord()
        driver.stop()

        let recorded = recorder.recorded
        #expect(recorded.count == 1)
        #expect(recorded.first?.id == exchange.id)
        #expect(recorded.first?.completionTokens == 4)
    }
}

// MARK: - Helpers

private final class SpyRecorder: ExchangeRecorder, @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [ProxiedExchange] = []
    private let arrived = DispatchSemaphore(value: 0)

    var recorded: [ProxiedExchange] {
        lock.lock()
        defer { lock.unlock() }
        return storage
    }

    func record(_ exchanges: [ProxiedExchange]) {
        lock.lock()
        storage.append(contentsOf: exchanges)
        lock.unlock()
        arrived.signal()
    }

    func waitForRecord() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.global().async {
                _ = self.arrived.wait(timeout: .now() + 2)
                continuation.resume()
            }
        }
    }
}

private struct ScriptedProxy: ProxyEventSource {
    let script: [ProxyEvent]

    func events() -> AsyncStream<ProxyEvent> {
        AsyncStream { continuation in
            for event in script { continuation.yield(event) }
            // Left open: the driver's loop must survive a stream that never finishes.
        }
    }
}

private struct SilentInventory: ModelInventorySource {
    func loadedModels() async throws -> [LoadedModel] { [] }
    func installedModels() async throws -> [InstalledModel] { [] }
}

private struct SilentLog: LogEventSource {
    func events() -> AsyncStream<LogEvent> { AsyncStream { _ in } }
}
