import Foundation

/// Ollama emits Go-style RFC 3339 timestamps with up to nanosecond precision
/// (`2026-08-06T11:54:20.829085541+03:00`). `ISO8601DateFormatter` only accepts milliseconds,
/// so the fractional part is normalised to three digits before parsing.
public enum RFC3339 {
    public static func date(from string: String) -> Date? {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = formatter.date(from: normalizingFraction(in: string)) {
            return date
        }
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.date(from: removingFraction(in: string))
    }

    private static func normalizingFraction(in string: String) -> String {
        string.replacing(/\.(\d+)/) { match in
            let digits = match.output.1
            return "." + digits.prefix(3).padding(toLength: 3, withPad: "0", startingAt: 0)
        }
    }

    private static func removingFraction(in string: String) -> String {
        string.replacing(/\.\d+/, with: "")
    }
}
