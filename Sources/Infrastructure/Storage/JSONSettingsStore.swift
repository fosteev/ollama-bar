import Foundation

/// Settings live in one JSON file with dot-notation keys (`app.pollInterval`, `ollama.host`)
/// rather than scattered across UserDefaults — easy to inspect, edit and delete by hand.
public final class JSONSettingsStore: @unchecked Sendable {
    public static let defaultURL = URL(filePath: NSHomeDirectory())
        .appending(path: ".ollamabar/settings.json")

    private let url: URL
    private let lock = NSLock()
    private var values: [String: Any]

    public init(url: URL = JSONSettingsStore.defaultURL) {
        self.url = url
        self.values = Self.read(from: url)
    }

    public func string(_ key: String) -> String? { value(key) as? String }

    public func int(_ key: String) -> Int? {
        switch value(key) {
        case let number as Int: number
        case let number as Double: Int(number)
        default: nil
        }
    }

    public func bool(_ key: String) -> Bool? { value(key) as? Bool }

    public func set(_ newValue: Any?, for key: String) {
        lock.lock()
        if let newValue {
            values = Self.setting(newValue, at: key.split(separator: ".").map(String.init), in: values)
        } else {
            values = Self.removing(at: key.split(separator: ".").map(String.init), in: values)
        }
        let snapshot = values
        lock.unlock()
        write(snapshot)
    }

    private func value(_ key: String) -> Any? {
        lock.lock()
        defer { lock.unlock() }
        var current: Any? = values
        for component in key.split(separator: ".") {
            guard let dictionary = current as? [String: Any] else { return nil }
            current = dictionary[String(component)]
        }
        return current
    }

    // MARK: - Nested dictionary plumbing

    private static func setting(
        _ newValue: Any,
        at path: [String],
        in dictionary: [String: Any]
    ) -> [String: Any] {
        guard let head = path.first else { return dictionary }
        var result = dictionary
        if path.count == 1 {
            result[head] = newValue
        } else {
            let child = dictionary[head] as? [String: Any] ?? [:]
            result[head] = setting(newValue, at: Array(path.dropFirst()), in: child)
        }
        return result
    }

    private static func removing(at path: [String], in dictionary: [String: Any]) -> [String: Any] {
        guard let head = path.first else { return dictionary }
        var result = dictionary
        if path.count == 1 {
            result.removeValue(forKey: head)
        } else if let child = dictionary[head] as? [String: Any] {
            result[head] = removing(at: Array(path.dropFirst()), in: child)
        }
        return result
    }

    private static func read(from url: URL) -> [String: Any] {
        guard let data = try? Data(contentsOf: url),
              let parsed = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return [:] }
        return parsed
    }

    /// Best effort: a monitor that cannot save its settings is still a working monitor.
    private func write(_ snapshot: [String: Any]) {
        let directory = url.deletingLastPathComponent()
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard let data = try? JSONSerialization.data(
            withJSONObject: snapshot,
            options: [.prettyPrinted, .sortedKeys]
        ) else { return }
        try? data.write(to: url, options: .atomic)
    }
}
