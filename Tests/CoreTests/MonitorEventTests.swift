import Foundation
import Testing

@testable import OllamaBarCore

/// What the monitor is willing to interrupt someone about. Getting this wrong in either direction
/// is bad: a missed swap hides the expensive event, a spurious one trains people to ignore it.
@MainActor
struct MonitorEventTests {
    @Test func theFirstPollDescribesTheWorldRatherThanAnEvent() async {
        let monitor = OllamaMonitor()
        let source = StubInventory(loaded: [model(name: "a"), model(name: "b")])

        #expect(await monitor.refreshLoaded(using: source).isEmpty)
        #expect(monitor.loaded.count == 2)
    }

    @Test func aModelLeavingIsAnEviction() async {
        let monitor = OllamaMonitor()
        await monitor.refreshLoaded(using: StubInventory(loaded: [model(name: "a")]))

        let events = await monitor.refreshLoaded(using: StubInventory(loaded: []))

        #expect(events == [.modelEvicted("a")])
    }

    @Test func aModelArrivingIsALoad() async {
        let monitor = OllamaMonitor()
        await monitor.refreshLoaded(using: StubInventory(loaded: []))

        let events = await monitor.refreshLoaded(using: StubInventory(loaded: [model(name: "a")]))

        #expect(events == [.modelLoaded("a")])
    }

    /// The one people care about: the model that left will cost seconds to load again.
    @Test func oneInAndOneOutIsASwap() async {
        let monitor = OllamaMonitor()
        await monitor.refreshLoaded(using: StubInventory(loaded: [model(name: "a")]))

        let events = await monitor.refreshLoaded(using: StubInventory(loaded: [model(name: "b")]))

        #expect(events == [.modelSwapped(from: "a", to: "b")])
    }

    @Test func aStableInventoryIsSilent() async {
        let monitor = OllamaMonitor()
        let source = StubInventory(loaded: [model(name: "a")])
        await monitor.refreshLoaded(using: source)

        #expect(await monitor.refreshLoaded(using: source).isEmpty)
        #expect(await monitor.refreshLoaded(using: source).isEmpty)
    }

    @Test func anUnreachableServerReportsNothing() async {
        let monitor = OllamaMonitor()
        await monitor.refreshLoaded(using: StubInventory(loaded: [model(name: "a")]))

        let events = await monitor.refreshLoaded(using: StubInventory(error: StubError.down))

        #expect(events.isEmpty)
        // And the last known list stays, rather than reading as an eviction next time.
        #expect(monitor.loaded.count == 1)
    }

    /// Several changes at once are not a swap — that would name an arbitrary pair.
    @Test func aBulkChangeIsReportedItemByItem() async {
        let monitor = OllamaMonitor()
        await monitor.refreshLoaded(
            using: StubInventory(loaded: [model(name: "a"), model(name: "b")])
        )

        let events = await monitor.refreshLoaded(
            using: StubInventory(loaded: [model(name: "c"), model(name: "d")])
        )

        #expect(events == [
            .modelEvicted("a"), .modelEvicted("b"), .modelLoaded("c"), .modelLoaded("d"),
        ])
    }
}

// MARK: - Helpers

private enum StubError: Error { case down }

private struct StubInventory: ModelInventorySource {
    var loaded: [LoadedModel] = []
    var error: Error?

    func loadedModels() async throws -> [LoadedModel] {
        if let error { throw error }
        return loaded
    }

    func installedModels() async throws -> [InstalledModel] { [] }
}

private func model(name: String) -> LoadedModel {
    LoadedModel(
        name: name,
        size: 1_000,
        sizeVRAM: 1_000,
        contextLength: 32_768,
        expiresAt: Date().addingTimeInterval(300),
        details: ModelDetails(family: "qwen35", parameterSize: "27.8B", quantizationLevel: "Q4_K_M")
    )
}
