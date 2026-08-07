import Foundation
import OllamaBarCore
import Testing

@testable import OllamaBarInfrastructure

struct HistoryStoreTests {
    @Test func roundTripsAnExchange() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory)
        let exchange = Self.exchange(
            model: "qwen3:8b",
            client: "codex",
            output: "Hello",
            reasoning: "thinking",
            toolCalls: ["get_time"]
        )
        store.record([exchange])
        store.flush()

        let records = await store.recent(limit: 10, days: 7)
        let record = try #require(records.first)
        #expect(records.count == 1)
        #expect(record.id == exchange.id)
        #expect(record.model == "qwen3:8b")
        #expect(record.client == "codex")
        #expect(record.status == 200)
        #expect(record.outcome == .ok)
        #expect(record.promptTokens == 12)
        #expect(record.completionTokens == 8)
        #expect(record.loadSeconds == 1)
        #expect(record.toolCalls == 1)
        #expect(record.hasBody)

        let body = try #require(await store.body(for: record))
        #expect(body.output == "Hello")
        #expect(body.reasoning == "thinking")
        #expect(body.toolCalls == ["get_time"])
        #expect(body.prompt == "why is the sky blue")
    }

    /// The property the whole file format exists for: a day's totals never open a body.
    @Test func totalsNeverReadBodies() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory)
        let big = String(repeating: "x", count: 20_000)
        store.record([
            Self.exchange(model: "a", output: big),
            Self.exchange(model: "a", output: big),
        ])
        store.flush()

        try FileManager.default.removeItem(at: directory.appending(path: "bodies"))

        let totals = await store.totals(for: Self.day)
        #expect(totals.requests == 2)
        #expect(totals.completionTokens == 16)
    }

    @Test func recordsLandInTheDayOfTheirStart() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory)
        store.record([Self.exchange(startedAt: Self.day, model: "a")])
        store.record([Self.exchange(startedAt: Self.day.addingTimeInterval(-86_400), model: "b")])
        store.flush()

        let names = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path()))
        #expect(names.contains("2026-08-07.jsonl"))
        #expect(names.contains("2026-08-06.jsonl"))

        let totals = await store.totals(for: Self.day)
        #expect(totals.requests == 1)
        #expect(totals.byModel.first?.model == "a")
    }

    @Test func dayTotalsSumTokensTimeAndFailures() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory)
        store.record([
            Self.exchange(model: "a"),
            Self.exchange(model: "a"),
            Self.exchange(model: "b", failure: "connection closed"),
        ])
        store.flush()

        let totals = await store.totals(for: Self.day)
        #expect(totals.requests == 3)
        #expect(totals.failures == 1)
        #expect(totals.promptTokens == 36)
        #expect(totals.completionTokens == 24)
        #expect(totals.duration == 6)
        #expect(totals.loadTime == 3)
        #expect(totals.byModel.count == 2)
        #expect(totals.byModel.first?.model == "a")
        #expect(totals.byModel.first?.requests == 2)
    }

    @Test func filterByModelReturnsOnlyThatModel() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory)
        store.record([Self.exchange(model: "a"), Self.exchange(model: "b"), Self.exchange(model: "a")])
        store.flush()

        let records = await store.recent(limit: 10, days: 7, model: "a")
        #expect(records.count == 2)
        #expect(records.allSatisfy { $0.model == "a" })
    }

    @Test func recentIsNewestFirstAndRespectsLimit() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory)
        let yesterday = Self.day.addingTimeInterval(-86_400)
        store.record([
            Self.exchange(startedAt: yesterday, model: "old"),
            Self.exchange(startedAt: Self.day.addingTimeInterval(60), model: "middle"),
            Self.exchange(startedAt: Self.day.addingTimeInterval(120), model: "newest"),
        ])
        store.flush()

        let all = await store.recent(limit: 10, days: 7)
        #expect(all.map(\.model) == ["newest", "middle", "old"])

        let capped = await store.recent(limit: 2, days: 7)
        #expect(capped.map(\.model) == ["newest", "middle"])
    }

    /// The index is a journal: a restart can write the same exchange twice, first as abandoned
    /// and later as complete.
    @Test func lastRecordForAnIDWins() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory)
        let id = UUID()
        store.record([Self.exchange(id: id, model: "a", finishedAt: nil)])
        store.record([Self.exchange(id: id, model: "a")])
        store.flush()

        let records = await store.recent(limit: 10, days: 7)
        #expect(records.count == 1)
        #expect(records.first?.outcome == .ok)

        let totals = await store.totals(for: Self.day)
        #expect(totals.requests == 1)
        #expect(totals.failures == 0)
    }

    @Test func corruptLineIsSkipped() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory)
        store.record([Self.exchange(model: "a")])
        store.flush()

        let index = directory.appending(path: "2026-08-07.jsonl")
        var contents = try String(contentsOf: index, encoding: .utf8)
        contents = "{ this is not json\n" + contents + "half a lin"
        try Data(contents.utf8).write(to: index)

        let records = await store.recent(limit: 10, days: 7)
        #expect(records.count == 1)
        #expect(records.first?.model == "a")
    }

    @Test func unknownVersionIsSkipped() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory)
        store.record([Self.exchange(model: "a")])
        store.flush()

        let index = directory.appending(path: "2026-08-07.jsonl")
        let future = #"{"v":99,"id":"\#(UUID().uuidString)","startedAt":"2026-08-07T10:00:00.000Z",""#
            + #""method":"POST","path":"/api/chat","outcome":"ok","toolCalls":0,"truncated":false,"body":false}"#
        let handle = try FileHandle(forWritingTo: index)
        try handle.seekToEnd()
        try handle.write(contentsOf: Data((future + "\n").utf8))
        try handle.close()

        let records = await store.recent(limit: 10, days: 7)
        #expect(records.count == 1)
        #expect(records.first?.model == "a")
    }

    @Test func pruneDropsOldDaysAndLeavesStrangersAlone() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory, retentionDays: 2)
        store.record([
            Self.exchange(startedAt: Self.day, model: "fresh"),
            Self.exchange(startedAt: Self.day.addingTimeInterval(-10 * 86_400), model: "stale"),
        ])
        store.flush()

        let stranger = directory.appending(path: "notes.txt")
        try Data("keep me".utf8).write(to: stranger)
        try FileManager.default.createDirectory(
            at: directory.appending(path: "bodies/whatever"),
            withIntermediateDirectories: true
        )

        store.prune(now: Self.day)
        store.flush()

        let manager = FileManager.default
        #expect(!manager.fileExists(atPath: directory.appending(path: "2026-07-28.jsonl").path()))
        #expect(!manager.fileExists(atPath: directory.appending(path: "bodies/2026-07-28").path()))
        #expect(manager.fileExists(atPath: directory.appending(path: "2026-08-07.jsonl").path()))
        #expect(manager.fileExists(atPath: stranger.path()))
        #expect(manager.fileExists(atPath: directory.appending(path: "bodies/whatever").path()))
    }

    @Test func missingDirectoryReadsAsEmpty() async {
        let store = Self.store(at: Self.tempDirectory())
        #expect(await store.recent(limit: 10, days: 7).isEmpty)
        #expect(await store.totals(for: Self.day).requests == 0)
        #expect(await store.hasRecords() == false)
    }

    @Test func hasRecordsSeesAWrittenDay() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let store = Self.store(at: directory)
        #expect(await store.hasRecords() == false)

        store.record([Self.exchange(model: "a")])
        store.flush()

        #expect(await store.hasRecords() == true)
    }

    /// Two processes share one day file. `O_APPEND` plus one `write(2)` per record is the whole
    /// defence — if it ever stops holding, lines start eating each other.
    @Test func concurrentAppendsDoNotInterleave() async throws {
        let directory = Self.tempDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }

        let count = 40
        let one = Self.store(at: directory)
        let two = Self.store(at: directory)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<count {
                group.addTask { one.record([Self.exchange(model: "one-\(index)")]) }
                group.addTask { two.record([Self.exchange(model: "two-\(index)")]) }
            }
        }
        one.flush()
        two.flush()

        let contents = try String(
            contentsOf: directory.appending(path: "2026-08-07.jsonl"),
            encoding: .utf8
        )
        let lines = contents.split(separator: "\n")
        #expect(lines.count == count * 2)

        let records = await one.recent(limit: 1_000, days: 7)
        #expect(records.count == count * 2)
    }

    // MARK: - Helpers

    /// Fixed so day-boundary tests do not depend on where the machine thinks it is.
    private static var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }

    /// 2026-08-07 10:00 UTC.
    private static let day = Date(timeIntervalSince1970: 1_786_096_800)

    private static func store(at directory: URL, retentionDays: Int = 14) -> HistoryStore {
        HistoryStore(directory: directory, retentionDays: retentionDays, calendar: calendar)
    }

    private static func tempDirectory() -> URL {
        URL(filePath: NSTemporaryDirectory())
            .appending(path: "ollama-bar-history-\(UUID().uuidString)")
    }

    private static func exchange(
        id: UUID = UUID(),
        startedAt: Date = HistoryStoreTests.day,
        model: String? = nil,
        client: String? = nil,
        finishedAt: Date? = HistoryStoreTests.day.addingTimeInterval(2),
        output: String = "",
        reasoning: String = "",
        toolCalls: [String] = [],
        failure: String? = nil
    ) -> ProxiedExchange {
        ProxiedExchange(
            id: id,
            startedAt: startedAt,
            method: "POST",
            path: "/api/chat",
            model: model,
            client: client,
            prompt: "why is the sky blue",
            status: 200,
            finishedAt: finishedAt,
            promptTokens: 12,
            completionTokens: 8,
            timings: ExchangeTimings(load: 1, prompt: 0.4, generation: 1.6),
            output: output,
            reasoning: reasoning,
            toolCalls: toolCalls,
            outputTruncated: false,
            failure: failure
        )
    }
}
