import Foundation

/// Shared by the CLI and the menu bar so both describe the same state the same way.
public enum Format {
    public static func bytes(_ value: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var size = Double(value)
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        return unit == 0 ? "\(value) B" : String(format: "%.1f %@", size, units[unit])
    }

    public static func tokens(_ value: Int) -> String {
        value >= 1024 ? "\(value / 1024)K" : "\(value)"
    }

    /// Token counts that sit next to each other and must line up: `9.9K`, `312`, `1.4K`.
    public static func tokensCompact(_ value: Int) -> String {
        if value < 1000 { return "\(value)" }
        let thousands = Double(value) / 1000
        return thousands < 100
            ? String(format: "%.1fK", thousands)
            : String(format: "%.0fK", thousands)
    }

    /// Running time in the shape a stopwatch uses: `0:31`, `12:04`, `1:02:11`.
    public static func elapsed(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total >= 3600 {
            return String(format: "%d:%02d:%02d", total / 3600, (total % 3600) / 60, total % 60)
        }
        return String(format: "%d:%02d", total / 60, total % 60)
    }

    /// Coarse age for lines like `idle · 2m` and `last seen 3m ago`, where precision is noise.
    public static func age(_ seconds: TimeInterval) -> String {
        let total = max(0, Int(seconds))
        if total < 60 { return "\(total)s" }
        if total < 3600 { return "\(total / 60)m" }
        return "\(total / 3600)h"
    }

    /// Phase durations shown side by side: `8.4 · 1.2 · 1.2`.
    public static func phase(_ seconds: TimeInterval) -> String {
        seconds <= 0 ? "—" : String(format: "%.1f", seconds)
    }

    public static func rate(_ value: Double) -> String {
        String(format: "%.1f t/s", value)
    }

    /// Ollama lists a model in `/api/ps` past its `expires_at` — eviction is lazy, so a
    /// non-positive countdown means "due", not "gone".
    public static func eviction(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "eviction due" }
        let total = Int(seconds.rounded())
        if total >= 3600 {
            return String(format: "evicts in %dh %02dm", total / 3600, (total % 3600) / 60)
        }
        return String(format: "evicts in %d:%02d", total / 60, total % 60)
    }

    public static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1e-3 { return String(format: "%.0f µs", seconds * 1e6) }
        if seconds < 1 { return String(format: "%.1f ms", seconds * 1e3) }
        return String(format: "%.2f s", seconds)
    }

    public static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
