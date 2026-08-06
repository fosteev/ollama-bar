import Foundation
import OllamaBarCore

/// Recorded from a live Ollama 0.32.6 on macOS — see docs/PLAN.md.
enum Fixtures {
    static let directory = URL(filePath: #filePath)
        .deletingLastPathComponent()  // InfrastructureTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // package root
        .appending(path: "Fixtures")

    static func data(_ name: String) throws -> Data {
        try Data(contentsOf: directory.appending(path: name))
    }

    static func lines(_ name: String) throws -> [String] {
        let text = try String(contentsOf: directory.appending(path: name), encoding: .utf8)
        return text.split(separator: "\n").map(String.init)
    }
}

/// Drains a log event source, giving up after `timeout` so a broken tailer fails instead of hanging.
func collect(
    from source: some LogEventSource,
    count: Int,
    timeout: Duration = .seconds(5)
) async -> [LogEvent] {
    await withTaskGroup(of: [LogEvent]?.self) { group in
        group.addTask {
            var collected: [LogEvent] = []
            for await event in source.events() {
                collected.append(event)
                if collected.count >= count { break }
            }
            return collected
        }
        group.addTask {
            try? await Task.sleep(for: timeout)
            return nil
        }
        let result = await group.next() ?? nil
        group.cancelAll()
        return result ?? []
    }
}
