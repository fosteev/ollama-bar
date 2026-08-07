import Foundation

/// Path arithmetic and raw I/O for the history directory. Holds no state of its own beyond the
/// one cached descriptor — the queueing lives in `HistoryStore`.
///
/// Layout:
/// ```
/// <root>/2026-08-07.jsonl          index, one record per line, append-only
/// <root>/bodies/2026-08-07/<id>.json
/// ```
struct HistoryFiles {
    /// A line longer than this is dropped rather than split. Unreachable in practice — bodies live
    /// elsewhere and the failure string is truncated — but the append-atomicity below depends on
    /// every record fitting into a single `write(2)`, so the bound is enforced rather than assumed.
    static let maximumLineLength = 8 * 1024

    let root: URL
    let calendar: Calendar

    init(root: URL, calendar: Calendar) {
        self.root = root
        self.calendar = calendar
    }

    // MARK: - Day keys

    /// `2026-08-07`, built by hand: `DateFormatter` is not `Sendable`, allocates per call, and
    /// would silently follow the user's locale into non-Gregorian calendars.
    func dayKey(for date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    func startOfDay(for date: Date) -> Date { calendar.startOfDay(for: date) }

    /// Strict on purpose: anything that is not exactly `YYYY-MM-DD.jsonl` is somebody else's file
    /// and pruning must leave it alone.
    static func dayKey(fromIndexFile name: String) -> String? {
        guard name.hasSuffix(".jsonl") else { return nil }
        return isDayKey(String(name.dropLast(6))) ? String(name.dropLast(6)) : nil
    }

    static func isDayKey(_ key: String) -> Bool {
        let parts = key.split(separator: "-", omittingEmptySubsequences: false)
        guard parts.count == 3, parts[0].count == 4, parts[1].count == 2, parts[2].count == 2
        else { return false }
        return parts.allSatisfy { $0.allSatisfy(\.isNumber) }
    }

    // MARK: - Paths

    func indexURL(day: String) -> URL { root.appending(path: "\(day).jsonl") }

    func bodiesURL(day: String) -> URL { root.appending(path: "bodies/\(day)") }

    func bodyURL(day: String, id: UUID) -> URL {
        bodiesURL(day: day).appending(path: "\(id.uuidString).json")
    }

    /// Newest first. Skips anything whose name is not a day key.
    func indexDays() -> [String] {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: root.path())) ?? []
        return names.compactMap(Self.dayKey(fromIndexFile:)).sorted(by: >)
    }

    // MARK: - Writing

    /// Best effort throughout, like `JSONSettingsStore`: a monitor that cannot write its history
    /// is still a working monitor.
    func writeBody(_ body: ExchangeBody, day: String) -> Bool {
        guard !body.isEmpty, let data = try? HistoryCoding.encoder.encode(body) else { return false }
        let url = bodyURL(day: day, id: body.id)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        // Atomic so a reader never catches half a body.
        guard (try? data.write(to: url, options: .atomic)) != nil else { return false }
        return true
    }

    func readBody(day: String, id: UUID) -> ExchangeBody? {
        guard let data = try? Data(contentsOf: bodyURL(day: day, id: id)) else { return nil }
        return try? HistoryCoding.decoder.decode(ExchangeBody.self, from: data)
    }

    /// Opens the day's index for appending. `O_APPEND` makes seek-to-end and write one atomic
    /// operation, which is what lets the app and the CLI share a file without a lock.
    func openIndex(day: String) -> Int32? {
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let descriptor = open(indexURL(day: day).path(), O_WRONLY | O_APPEND | O_CREAT, 0o644)
        return descriptor < 0 ? nil : descriptor
    }

    /// One record, one `write(2)`. Never split: a partial write from a second process would
    /// interleave inside the line and corrupt both.
    static func appendLine(_ record: ExchangeRecord, to descriptor: Int32) {
        guard var data = try? HistoryCoding.encoder.encode(record) else { return }
        data.append(0x0A)
        guard data.count <= maximumLineLength else { return }
        data.withUnsafeBytes { buffer in
            _ = write(descriptor, buffer.baseAddress, buffer.count)
        }
    }

    // MARK: - Reading

    /// Oldest first, as written. Corrupt lines and future versions are skipped, never fatal —
    /// a hand-edited file or a half-written tail must not take the history window down.
    func readIndex(day: String) -> [ExchangeRecord] {
        guard let data = try? Data(contentsOf: indexURL(day: day)) else { return [] }
        return data.split(separator: 0x0A).compactMap { line in
            guard let record = try? HistoryCoding.decoder.decode(ExchangeRecord.self, from: Data(line)),
                  record.version == ExchangeRecord.currentVersion
            else { return nil }
            return record
        }
    }

    func hasAnyRecords() -> Bool {
        indexDays().contains { day in
            let attributes = try? FileManager.default.attributesOfItem(atPath: indexURL(day: day).path())
            return (attributes?[.size] as? Int ?? 0) > 0
        }
    }

    // MARK: - Retention

    /// Drops whole days. Files whose names are not day keys are left where they are.
    func prune(before cutoff: String) {
        for day in indexDays() where day < cutoff {
            try? FileManager.default.removeItem(at: indexURL(day: day))
        }
        let bodies = root.appending(path: "bodies")
        let names = (try? FileManager.default.contentsOfDirectory(atPath: bodies.path())) ?? []
        for name in names where Self.isDayKey(name) && name < cutoff {
            try? FileManager.default.removeItem(at: bodies.appending(path: name))
        }
    }
}
