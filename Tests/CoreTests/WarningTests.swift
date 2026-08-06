import Foundation
import Testing

@testable import OllamaBarCore

@MainActor
struct WarningTests {
    @Test func contextWarningFiresOnlyNearTheLimit() {
        let monitor = OllamaMonitor()
        let now = Date()

        monitor.apply(.checkpoint(checkpoint(tokens: 20_000)), now: now)
        #expect(monitor.warnings(now: now).isEmpty)

        monitor.apply(.checkpoint(checkpoint(tokens: 30_100)), now: now)
        #expect(monitor.warnings(now: now).isEmpty, "no model loaded means no known window")
    }

    @Test func contextWarningUsesTheWindowTheModelWasLoadedWith() async {
        let monitor = OllamaMonitor()
        let now = Date()
        await monitor.refreshLoaded(using: StubInventory(loaded: [model(context: 32_768)]), now: now)

        monitor.apply(.checkpoint(checkpoint(tokens: 30_100)), now: now)

        guard case .contextNearlyFull(let used, let limit)? = monitor.warnings(now: now).first else {
            Issue.record("expected a context warning, got \(monitor.warnings(now: now))")
            return
        }
        #expect(used == 30_100)
        #expect(limit == 32_768)
    }

    /// A checkpoint from an hour ago says nothing about the context right now.
    @Test func staleCheckpointsAreIgnored() async {
        let monitor = OllamaMonitor()
        let start = Date()
        await monitor.refreshLoaded(using: StubInventory(loaded: [model(context: 32_768)]), now: start)
        monitor.apply(.checkpoint(checkpoint(tokens: 31_000)), now: start)

        let later = start.addingTimeInterval(600)
        #expect(monitor.contextFill(now: later) == nil)
        #expect(monitor.warnings(now: later).isEmpty)
    }

    @Test func reloadsAreCountedWhenAModelComesBack() async {
        let monitor = OllamaMonitor()
        let loaded = StubInventory(loaded: [model()])
        let empty = StubInventory(loaded: [])
        var now = Date()

        for _ in 0..<3 {
            await monitor.refreshLoaded(using: loaded, now: now)
            now += 60
            await monitor.refreshLoaded(using: empty, now: now)
            now += 60
        }
        await monitor.refreshLoaded(using: loaded, now: now)

        // First load is not a reload; the three that followed are.
        #expect(monitor.reloads.count == 3)
        guard case .modelReloads(let count, _)? = monitor.warnings(now: now).first else {
            Issue.record("expected a reload warning, got \(monitor.warnings(now: now))")
            return
        }
        #expect(count == 3)
    }

    @Test func reloadsOlderThanAnHourStopCounting() async {
        let monitor = OllamaMonitor()
        let loaded = StubInventory(loaded: [model()])
        let empty = StubInventory(loaded: [])
        var now = Date()

        for _ in 0..<3 {
            await monitor.refreshLoaded(using: loaded, now: now)
            now += 60
            await monitor.refreshLoaded(using: empty, now: now)
            now += 60
        }
        await monitor.refreshLoaded(using: loaded, now: now)
        #expect(monitor.reloads.count == 3)

        await monitor.refreshLoaded(using: loaded, now: now.addingTimeInterval(3_700))
        #expect(monitor.reloads.isEmpty)
    }

    @Test func failedRequestOutranksEverythingAndThenExpires() async {
        let monitor = OllamaMonitor()
        let now = Date()
        await monitor.refreshLoaded(using: StubInventory(loaded: [model(context: 32_768)]), now: now)
        monitor.apply(.checkpoint(checkpoint(tokens: 31_000)), now: now)

        let exchange = ProxiedExchange(method: "POST", path: "/api/chat")
        monitor.apply(.started(exchange))
        monitor.apply(.responded(id: exchange.id, status: 500))
        monitor.apply(.failed(id: exchange.id, reason: "out of memory", at: now))

        #expect(monitor.warnings(now: now).first?.isError == true)
        #expect(monitor.warnings(now: now).count == 2)

        // A minute later the error has had its moment; the context warning remains.
        let later = now.addingTimeInterval(90)
        #expect(monitor.warnings(now: later).allSatisfy { !$0.isError })
    }

    @Test func idleTimeIsRecordedWhenGenerationStops() {
        let monitor = OllamaMonitor()
        let start = Date()
        monitor.apply(.timing(SlotTiming(
            slotID: 0,
            taskID: 1,
            tokensDecoded: 10,
            tokensPerSecond: 5,
            tokensPerSecond3s: 5
        )), now: start)

        monitor.expireStaleThroughput(now: start.addingTimeInterval(6))

        #expect(monitor.throughput == nil)
        #expect(monitor.generationEndedAt == start)
    }

    // MARK: - Helpers

    private func checkpoint(tokens: Int) -> ContextCheckpoint {
        ContextCheckpoint(slotID: 0, taskID: 1, index: 1, total: 32, tokens: tokens)
    }

    private func model(context: Int = 32_768) -> LoadedModel {
        LoadedModel(
            name: "qwen",
            size: 1_000,
            sizeVRAM: 1_000,
            contextLength: context,
            expiresAt: .distantFuture,
            details: ModelDetails(family: "f", parameterSize: "27.8B", quantizationLevel: "Q4_K_M")
        )
    }
}

private struct StubInventory: ModelInventorySource {
    var loaded: [LoadedModel] = []

    func loadedModels() async throws -> [LoadedModel] { loaded }
    func installedModels() async throws -> [InstalledModel] { [] }
}
