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
