import Foundation
import OllamaBarCore

/// History that survives a restart. One index file per day plus a body file per exchange, under
/// `~/.ollamabar/history`. Day-sized files make retention a `rm` and make "today" a single parse.
///
/// A serial queue rather than an actor: `record(_:)` is called from the driver's `@MainActor`
/// event loop, where an actor would force either an `await` behind the disk or a `Task` per
/// record — and task ordering is not guaranteed, so records would interleave. `flush()` also
/// needs a synchronous barrier at termination, which an actor cannot give.
public final class HistoryStore: ExchangeRecorder, @unchecked Sendable {
    public static let defaultDirectory = URL(filePath: NSHomeDirectory())
        .appending(path: ".ollamabar/history")
    public static let defaultRetentionDays = 14

    private let files: HistoryFiles
    /// Write-queue state, like the descriptor below.
    private var retentionDays: Int
    private let writeQueue = DispatchQueue(label: "ollamabar.history.write", qos: .utility)
    /// Reads must not queue behind a write, and parsing a day must not stall a record.
    private let readQueue = DispatchQueue(
        label: "ollamabar.history.read",
        qos: .utility,
        attributes: .concurrent
    )

    /// Write-queue state, touched nowhere else.
    private var descriptor: Int32?
    private var openDay: String?

    public init(
        directory: URL = HistoryStore.defaultDirectory,
        retentionDays: Int = HistoryStore.defaultRetentionDays,
        calendar: Calendar = .current
    ) {
        self.files = HistoryFiles(root: directory, calendar: calendar)
        self.retentionDays = max(1, retentionDays)
        prune()
    }

    deinit {
        if let descriptor { close(descriptor) }
    }

    // MARK: - Writing

    public func record(_ exchanges: [ProxiedExchange]) {
        guard !exchanges.isEmpty else { return }
        writeQueue.async { [files] in
            for exchange in exchanges {
                let day = files.dayKey(for: exchange.startedAt)
                let body = ExchangeBody(exchange)
                // Body first: an index line must never point at a file that is not there yet.
                let hasBody = files.writeBody(body, day: day)
                let record = ExchangeRecord(
                    exchange,
                    outcome: Self.outcome(of: exchange),
                    hasBody: hasBody
                )
                guard let descriptor = self.descriptor(for: day) else { continue }
                HistoryFiles.appendLine(record, to: descriptor)
            }
        }
    }

    /// Waits for everything already enqueued to reach the disk. For application termination.
    public func flush(timeout: TimeInterval = 2) {
        let done = DispatchSemaphore(value: 0)
        writeQueue.async {
            self.closeDescriptor()
            done.signal()
        }
        _ = done.wait(timeout: .now() + timeout)
    }

    /// Takes effect on the next prune, which the caller usually triggers right after.
    public func setRetention(days: Int) {
        writeQueue.async { self.retentionDays = max(1, days) }
    }

    public func prune(now: Date = .now) {
        writeQueue.async { [files] in files.prune(before: self.cutoffKey(now)) }
    }

    private func descriptor(for day: String) -> Int32? {
        if openDay == day, let descriptor { return descriptor }
        // Day rolled over: close yesterday and take the chance to drop what aged out.
        let rolled = openDay != nil
        closeDescriptor()
        guard let opened = files.openIndex(day: day) else { return nil }
        descriptor = opened
        openDay = day
        if rolled { files.prune(before: cutoffKey(.now)) }
        return opened
    }

    private func closeDescriptor() {
        if let descriptor { close(descriptor) }
        descriptor = nil
        openDay = nil
    }

    private func cutoffKey(_ now: Date) -> String {
        files.dayKey(for: now.addingTimeInterval(-Double(retentionDays) * 86_400))
    }

    /// An exchange with no `finishedAt` never reached a terminal event — the history limit
    /// evicted it mid-stream and nobody will ever tell us how it ended.
    private static func outcome(of exchange: ProxiedExchange) -> ExchangeOutcome {
        if exchange.failure != nil { return .failed }
        guard exchange.finishedAt != nil else { return .abandoned }
        if let status = exchange.status, status >= 400 { return .failed }
        return .ok
    }

    // MARK: - Reading

    /// Newest first. Walks back day by day until `limit` is met or `days` runs out.
    public func recent(limit: Int, days: Int, model: String? = nil) async -> [ExchangeRecord] {
        await read { files in
            var result: [ExchangeRecord] = []
            var seen: Set<UUID> = []
            for day in files.indexDays().prefix(max(1, days)) {
                // Reversed: within a file the last record for an id wins, and the newest is last.
                for record in files.readIndex(day: day).reversed() {
                    guard seen.insert(record.id).inserted else { continue }
                    guard model == nil || record.model == model else { continue }
                    result.append(record)
                    if result.count >= limit { return result }
                }
            }
            return result
        }
    }

    /// Parses exactly one index file. Never opens `bodies/` — that is what keeps it cheap.
    public func totals(for day: Date = .now) async -> DayTotals {
        await read { files in
            let key = files.dayKey(for: day)
            let start = files.startOfDay(for: day)
            var latest: [UUID: ExchangeRecord] = [:]
            for record in files.readIndex(day: key) { latest[record.id] = record }
            return DayTotals.summing(Array(latest.values), day: start)
        }
    }

    public func body(for record: ExchangeRecord) async -> ExchangeBody? {
        guard record.hasBody else { return nil }
        return await body(id: record.id, startedAt: record.startedAt)
    }

    /// The body path is derived from the id and the day, so a caller holding a `ProxiedExchange`
    /// does not have to find its index record first.
    public func body(id: UUID, startedAt: Date) async -> ExchangeBody? {
        await read { files in files.readBody(day: files.dayKey(for: startedAt), id: id) }
    }

    public func hasRecords() async -> Bool {
        await read { $0.hasAnyRecords() }
    }

    private func read<T: Sendable>(_ body: @escaping @Sendable (HistoryFiles) -> T) async -> T {
        let files = files
        return await withCheckedContinuation { continuation in
            readQueue.async { continuation.resume(returning: body(files)) }
        }
    }
}
