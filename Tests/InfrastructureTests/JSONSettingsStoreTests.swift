import Foundation
import Testing

@testable import OllamaBarInfrastructure

struct JSONSettingsStoreTests {
    @Test func roundTripsThroughTheFile() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = JSONSettingsStore(url: url)
        store.set("http://192.168.0.10:11434", for: "ollama.host")
        store.set(5, for: "app.pollInterval")
        store.set(true, for: "proxy.enabled")

        let reopened = JSONSettingsStore(url: url)
        #expect(reopened.string("ollama.host") == "http://192.168.0.10:11434")
        #expect(reopened.int("app.pollInterval") == 5)
        #expect(reopened.bool("proxy.enabled") == true)
    }

    @Test func nestedKeysShareTheirParent() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = JSONSettingsStore(url: url)
        store.set(1, for: "app.pollInterval")
        store.set("dark", for: "app.theme")

        let json = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any]
        let app = try #require(json?["app"] as? [String: Any])
        #expect(app.count == 2)
    }

    @Test func missingFileReadsAsEmpty() {
        let store = JSONSettingsStore(url: Self.tempURL())
        #expect(store.string("ollama.host") == nil)
        #expect(store.int("app.pollInterval") == nil)
    }

    @Test func removingAKeyLeavesTheRest() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let store = JSONSettingsStore(url: url)
        store.set(1, for: "app.pollInterval")
        store.set("dark", for: "app.theme")
        store.set(nil, for: "app.theme")

        let reopened = JSONSettingsStore(url: url)
        #expect(reopened.int("app.pollInterval") == 1)
        #expect(reopened.string("app.theme") == nil)
    }

    @Test func corruptFileDoesNotTakeTheAppDown() throws {
        let url = Self.tempURL()
        defer { try? FileManager.default.removeItem(at: url) }
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try Data("{ this is not json".utf8).write(to: url)

        let store = JSONSettingsStore(url: url)
        #expect(store.int("app.pollInterval") == nil)

        store.set(2, for: "app.pollInterval")
        #expect(JSONSettingsStore(url: url).int("app.pollInterval") == 2)
    }

    private static func tempURL() -> URL {
        URL(filePath: NSTemporaryDirectory())
            .appending(path: "ollama-bar-settings-\(UUID().uuidString)/settings.json")
    }
}
