import Foundation
import OllamaBarCore

/// Turns lines of `~/.ollama/logs/server.log` into `LogEvent`s.
///
/// Everything here is best-effort: the log is llama.cpp/gin internals, not an API. Unrecognised
/// lines return `nil` and are dropped. Note that llama.cpp truncates the operation name to a fixed
/// width, so the log really does contain `slot get_availabl:` and `slot launch_slot_:` — matching
/// is by prefix.
public enum LogLineParser {
    public static func parse(_ line: String) -> LogEvent? {
        if line.hasPrefix("slot print_timing") { return parseTiming(line) }
        if line.hasPrefix("slot create_check") { return parseCheckpoint(line) }
        // The prefix is shared with the "- checking sim = …" line that precedes it, so here the
        // regex is the real gate rather than an extraction step.
        if line.hasPrefix("slot get_availabl") { return parseSlotReuse(line) }
        if line.hasPrefix("[GIN]") { return parseRequest(line) }
        return nil
    }

    // slot get_availabl: id  0 | task -1 | selected slot by LCP similarity, f_sim_best = 0.976 (> 0.100 thold), f_keep = 1.000
    private static func parseSlotReuse(_ line: String) -> LogEvent? {
        let pattern = /id\s+(\d+)\s*\|.*?selected slot by LCP similarity,\s*f_sim_best\s*=\s*([\d.]+)\s*\(\s*>\s*([\d.]+)\s*thold/
        guard let match = line.firstMatch(of: pattern),
              let slotID = Int(match.output.1),
              let similarity = Double(match.output.2),
              let threshold = Double(match.output.3)
        else { return nil }

        return .slotReuse(SlotReuse(slotID: slotID, similarity: similarity, threshold: threshold))
    }

    // slot print_timing: id  0 | task 8510 | n_decoded =  116, tg =  5.69 t/s, tg_3s =  5.27 t/s
    private static func parseTiming(_ line: String) -> LogEvent? {
        let pattern = /id\s+(\d+)\s*\|\s*task\s+(-?\d+)\s*\|\s*n_decoded\s*=\s*(\d+),\s*tg\s*=\s*([\d.]+)\s*t\/s,\s*tg_3s\s*=\s*([\d.]+)\s*t\/s/
        guard let match = line.firstMatch(of: pattern),
              let slotID = Int(match.output.1),
              let taskID = Int(match.output.2),
              let decoded = Int(match.output.3),
              let tg = Double(match.output.4),
              let tg3s = Double(match.output.5)
        else { return nil }

        return .timing(
            SlotTiming(
                slotID: slotID,
                taskID: taskID,
                tokensDecoded: decoded,
                tokensPerSecond: tg,
                tokensPerSecond3s: tg3s
            )
        )
    }

    // slot create_check: id  0 | task 8985 | created context checkpoint 4 of 32 (... n_tokens = 28485, ...)
    private static func parseCheckpoint(_ line: String) -> LogEvent? {
        let pattern = /id\s+(\d+)\s*\|\s*task\s+(-?\d+)\s*\|\s*created context checkpoint\s+(\d+)\s+of\s+(\d+).*?n_tokens\s*=\s*(\d+)/
        guard let match = line.firstMatch(of: pattern),
              let slotID = Int(match.output.1),
              let taskID = Int(match.output.2),
              let index = Int(match.output.3),
              let total = Int(match.output.4),
              let tokens = Int(match.output.5)
        else { return nil }

        return .checkpoint(
            ContextCheckpoint(
                slotID: slotID,
                taskID: taskID,
                index: index,
                total: total,
                tokens: tokens
            )
        )
    }

    // [GIN] 2026/08/06 - 12:32:40 | 200 |   651.25µs |  127.0.0.1 | GET      "/api/tags"
    private static func parseRequest(_ line: String) -> LogEvent? {
        let pattern = /^\[GIN\]\s+(\d{4}\/\d{2}\/\d{2} - \d{2}:\d{2}:\d{2})\s*\|\s*(\d+)\s*\|\s*(\S+)\s*\|\s*(\S+)\s*\|\s*(\w+)\s+"([^"]*)"/
        guard let match = line.firstMatch(of: pattern),
              let timestamp = ginTimestamp(String(match.output.1)),
              let status = Int(match.output.2),
              let duration = goDuration(String(match.output.3))
        else { return nil }

        return .request(
            RequestLogEntry(
                timestamp: timestamp,
                status: status,
                duration: duration,
                clientIP: String(match.output.4),
                method: String(match.output.5),
                path: String(match.output.6)
            )
        )
    }

    /// gin logs local time with no zone, so it is interpreted in the current one.
    static func ginTimestamp(_ value: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy/MM/dd - HH:mm:ss"
        return formatter.date(from: value)
    }

    /// Go duration syntax: `651.25µs`, `1.5ms`, `2m30s`.
    static func goDuration(_ value: String) -> TimeInterval? {
        let units: [(String, TimeInterval)] = [
            ("ns", 1e-9), ("µs", 1e-6), ("us", 1e-6), ("ms", 1e-3),
            ("s", 1), ("m", 60), ("h", 3600),
        ]
        var total: TimeInterval = 0
        var matched = false

        for match in value.matches(of: /([\d.]+)(ns|µs|us|ms|s|m|h)/) {
            guard let amount = Double(match.output.1),
                  let unit = units.first(where: { $0.0 == String(match.output.2) })
            else { return nil }
            total += amount * unit.1
            matched = true
        }
        return matched ? total : nil
    }
}
