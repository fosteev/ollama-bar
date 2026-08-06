import Foundation
import Testing

@testable import OllamaBarCore

@MainActor
struct OllamaMonitorTests {
    /// Measured on a live run: `tg` moved 29.7→30.2 while `tg_3s` swung 22.8→30.9 over the same
    /// samples. The steady figure is the one worth showing.
    @Test func throughputUsesTheSteadyFigure() {
        let monitor = OllamaMonitor()
        monitor.apply(.timing(timing(tg: 5.69, tg3s: 5.27)))

        #expect(monitor.throughput?.tokensPerSecond == 5.69)
        #expect(monitor.menuBarState == .generating(tokensPerSecond: 5.69))
    }

    /// llama.cpp prints these lines every three seconds, so the reading has to outlive that gap —
    /// a shorter timeout made the panel blink between every pair of lines.
    @Test func throughputSurvivesTheGapBetweenLogLines() {
        let monitor = OllamaMonitor()
        let start = Date()
        monitor.apply(.timing(timing()), now: start)

        monitor.expireStaleThroughput(now: start.addingTimeInterval(3.5))
        #expect(monitor.throughput != nil, "3 s is the normal cadence, not a stall")

        monitor.expireStaleThroughput(now: start.addingTimeInterval(5.1))
        #expect(monitor.throughput == nil)
    }

    @Test func finishedGenerationRequestClearsTheReadingImmediately() {
        let monitor = OllamaMonitor()
        let start = Date()
        monitor.apply(.timing(timing()), now: start)

        monitor.apply(.request(request(path: "/api/chat")), now: start.addingTimeInterval(0.2))

        #expect(monitor.throughput == nil)
        #expect(monitor.generationEndedAt != nil)
    }

    @Test func pollingRequestsDoNotClearTheReading() {
        let monitor = OllamaMonitor()
        monitor.apply(.timing(timing()))

        monitor.apply(.request(request(path: "/api/ps")))

        #expect(monitor.throughput != nil)
    }

    @Test func menuBarShowsLoadedCountWhenIdle() async {
        let monitor = OllamaMonitor()
        await monitor.refreshInventory(using: StubInventory(loaded: [model()]))

        #expect(monitor.menuBarState == .idle(loadedCount: 1))
    }

    @Test func unreachableServerOutranksEverythingElse() async {
        let monitor = OllamaMonitor()
        await monitor.refreshInventory(using: StubInventory(loaded: [model()]))
        monitor.apply(.timing(timing()))

        await monitor.refreshInventory(using: StubInventory(error: StubError.down))

        #expect(monitor.menuBarState == .unreachable)
        if case .unreachable = monitor.connection {} else {
            Issue.record("expected connection to be unreachable, got \(monitor.connection)")
        }
    }

    @Test func inventoryIsKeptFromTheLastSuccessfulPoll() async {
        let monitor = OllamaMonitor()
        await monitor.refreshInventory(using: StubInventory(loaded: [model(), model(name: "b")]))

        #expect(monitor.loaded.count == 2)
        #expect(monitor.residentBytes == 2_000)
    }

    @Test func requestHistoryIsCapped() {
        let monitor = OllamaMonitor()
        let overflow = OllamaMonitor.requestHistoryLimit + 10

        for index in 0..<overflow {
            monitor.apply(.request(request(path: "/req/\(index)")))
        }

        #expect(monitor.recentRequests.count == OllamaMonitor.requestHistoryLimit)
        #expect(monitor.recentRequests.last?.path == "/req/\(overflow - 1)")
        #expect(monitor.recentRequests.first?.path == "/req/10")
    }

    @Test func failedInstalledPollKeepsTheKnownList() async {
        let monitor = OllamaMonitor()
        let installed = InstalledModel(
            name: "a",
            size: 1,
            modifiedAt: .distantPast,
            details: ModelDetails(family: "f", parameterSize: "7B", quantizationLevel: "Q4_K_M")
        )
        await monitor.refreshInventory(using: StubInventory(installed: [installed]))

        await monitor.refreshInstalled(using: StubInventory(error: StubError.down))

        #expect(monitor.installed.count == 1)
    }

    @Test func ourOwnPollingIsRecognisable() {
        // The app polls these itself once a second — they would otherwise bury real traffic.
        #expect(request(path: "/api/ps").isInventoryPoll)
        #expect(request(path: "/api/tags").isInventoryPoll)
        #expect(!request(path: "/api/chat").isInventoryPoll)
    }

    @Test func evictionCountdownNeverGoesNegative() {
        let expired = model(expiresAt: Date().addingTimeInterval(-30))
        #expect(expired.timeUntilEviction() == 0)
    }

    @Test func partiallyOffloadedModelReportsItsVRAMShare() {
        let partial = LoadedModel(
            name: "partial",
            size: 1_000,
            sizeVRAM: 250,
            contextLength: 4096,
            expiresAt: .distantFuture,
            details: ModelDetails(family: "x", parameterSize: "7B", quantizationLevel: "Q4_K_M")
        )

        #expect(!partial.isFullyOnGPU)
        #expect(partial.vramFraction == 0.25)
    }
}

// MARK: - Helpers

private enum StubError: Error { case down }

private struct StubInventory: ModelInventorySource {
    var loaded: [LoadedModel] = []
    var installed: [InstalledModel] = []
    var error: Error?

    func loadedModels() async throws -> [LoadedModel] {
        if let error { throw error }
        return loaded
    }

    func installedModels() async throws -> [InstalledModel] {
        if let error { throw error }
        return installed
    }
}

private func model(
    name: String = "a",
    expiresAt: Date = Date().addingTimeInterval(300)
) -> LoadedModel {
    LoadedModel(
        name: name,
        size: 1_000,
        sizeVRAM: 1_000,
        contextLength: 32_768,
        expiresAt: expiresAt,
        details: ModelDetails(family: "qwen35", parameterSize: "27.8B", quantizationLevel: "Q4_K_M")
    )
}

private func timing(tg: Double = 5.0, tg3s: Double = 5.0) -> SlotTiming {
    SlotTiming(slotID: 0, taskID: 1, tokensDecoded: 100, tokensPerSecond: tg, tokensPerSecond3s: tg3s)
}

private func request(path: String) -> RequestLogEntry {
    RequestLogEntry(
        timestamp: Date(),
        status: 200,
        duration: 0.0001,
        clientIP: "127.0.0.1",
        method: "GET",
        path: path
    )
}
