import Foundation
import Testing

import OllamaBarCore
@testable import OllamaBarInfrastructure

struct ServerLogTailerTests {
    @Test func replaysAnExistingFileFromTheBeginning() async throws {
        let file = try TempLog()
        try file.append(Self.timingLine(tg3s: 5.27))
        try file.append(Self.timingLine(tg3s: 6.11))

        let events = await collect(
            from: ServerLogTailer(url: file.url, start: .beginning, pollInterval: .milliseconds(20)),
            count: 2
        )

        #expect(events.count == 2)
        guard case .timing(let first)? = events.first else {
            Issue.record("expected timing events, got \(events)")
            return
        }
        #expect(first.tokensPerSecond3s == 5.27)
    }

    @Test func startingAtTheEndSkipsHistory() async throws {
        let file = try TempLog()
        try file.append(Self.timingLine(tg3s: 1.0))  // history — must not be reported

        let tailer = ServerLogTailer(url: file.url, start: .end, pollInterval: .milliseconds(20))
        async let collected = collect(from: tailer, count: 1, timeout: .seconds(3))

        try await Task.sleep(for: .milliseconds(200))
        try file.append(Self.timingLine(tg3s: 2.0))

        let events = await collected
        #expect(events.count == 1)
        guard case .timing(let timing)? = events.first else {
            Issue.record("expected a timing event, got \(events)")
            return
        }
        #expect(timing.tokensPerSecond3s == 2.0)
    }

    /// Log rotation replaces the file, so following by path alone silently goes deaf.
    @Test func survivesRotation() async throws {
        let file = try TempLog()
        try file.append(Self.timingLine(tg3s: 1.0))

        let tailer = ServerLogTailer(url: file.url, start: .beginning, pollInterval: .milliseconds(20))
        async let collected = collect(from: tailer, count: 2, timeout: .seconds(5))

        try await Task.sleep(for: .milliseconds(200))
        try file.rotate()
        try file.append(Self.timingLine(tg3s: 9.0))

        let events = await collected
        #expect(events.count == 2)
        guard case .timing(let afterRotation)? = events.last else {
            Issue.record("expected a timing event after rotation, got \(events)")
            return
        }
        #expect(afterRotation.tokensPerSecond3s == 9.0)
    }

    @Test func partialLinesAreHeldUntilComplete() async throws {
        let file = try TempLog()

        let tailer = ServerLogTailer(url: file.url, start: .beginning, pollInterval: .milliseconds(20))
        async let collected = collect(from: tailer, count: 1, timeout: .seconds(3))

        try await Task.sleep(for: .milliseconds(100))
        let line = Self.timingLine(tg3s: 7.5)
        try file.appendRaw(String(line.dropLast(20)))  // half a line, no newline
        try await Task.sleep(for: .milliseconds(100))
        try file.appendRaw(String(line.suffix(20)))

        let events = await collected
        #expect(events.count == 1)
        guard case .timing(let timing)? = events.first else {
            Issue.record("expected a timing event, got \(events)")
            return
        }
        #expect(timing.tokensPerSecond3s == 7.5)
    }

    @Test func missingFileIsNotFatal() async throws {
        let url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "ollama-bar-absent-\(UUID().uuidString).log")

        let events = await collect(
            from: ServerLogTailer(url: url, start: .beginning, pollInterval: .milliseconds(20)),
            count: 1,
            timeout: .milliseconds(300)
        )

        #expect(events.isEmpty)
    }

    private static func timingLine(tg3s: Double) -> String {
        "slot print_timing: id  0 | task 8510 | n_decoded =    116, tg =   5.69 t/s, tg_3s =   \(tg3s) t/s\n"
    }
}

/// A throwaway log file that can be appended to and rotated.
private struct TempLog {
    let url: URL

    init() throws {
        url = URL(filePath: NSTemporaryDirectory())
            .appending(path: "ollama-bar-test-\(UUID().uuidString).log")
        try Data().write(to: url)
    }

    func append(_ line: String) throws {
        try appendRaw(line)
    }

    func appendRaw(_ text: String) throws {
        let handle = try FileHandle(forWritingTo: url)
        defer { try? handle.close() }
        try handle.seekToEnd()
        try handle.write(contentsOf: Data(text.utf8))
    }

    /// Mimics `logrotate`: the old file is moved aside and a fresh one takes its place.
    func rotate() throws {
        let archived = url.deletingPathExtension().appendingPathExtension("1.log")
        try? FileManager.default.removeItem(at: archived)
        try FileManager.default.moveItem(at: url, to: archived)
        try Data().write(to: url)
    }
}
