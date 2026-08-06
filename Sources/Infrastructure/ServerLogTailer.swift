import Foundation
import OllamaBarCore

/// Follows `server.log` and emits parsed events.
///
/// Polls rather than watching: a 250 ms tick is cheap, survives rotation without extra bookkeeping,
/// and avoids the edge cases of `DispatchSource` file watching when the file is replaced.
public struct ServerLogTailer: LogEventSource {
    public enum Start: Sendable {
        /// Replay the whole file first. Used by tests against fixtures.
        case beginning
        /// Only report what happens from now on. What the app wants.
        case end
    }

    public static let defaultURL = URL(filePath: NSHomeDirectory())
        .appending(path: ".ollama/logs/server.log")

    /// A single line longer than this is assumed to be garbage and dropped.
    private static let maxPendingBytes = 1 << 20

    public let url: URL
    public let start: Start
    public let pollInterval: Duration

    public init(
        url: URL = ServerLogTailer.defaultURL,
        start: Start = .end,
        pollInterval: Duration = .milliseconds(250)
    ) {
        self.url = url
        self.start = start
        self.pollInterval = pollInterval
    }

    public func events() -> AsyncStream<LogEvent> {
        AsyncStream { continuation in
            let task = Task { [url, start, pollInterval] in
                var handle: FileHandle?
                var openedInode: UInt64?
                var isFirstOpen = true
                var pending = Data()

                defer {
                    try? handle?.close()
                    continuation.finish()
                }

                while !Task.isCancelled {
                    let inode = Self.inode(of: url)

                    // First open, or the file was rotated out from under us.
                    if inode != nil, handle == nil || inode != openedInode {
                        try? handle?.close()
                        handle = try? FileHandle(forReadingFrom: url)
                        openedInode = inode
                        pending.removeAll()
                        if isFirstOpen, start == .end {
                            _ = try? handle?.seekToEnd()
                        }
                        isFirstOpen = false
                    }

                    if let openHandle = handle {
                        do {
                            let size = Self.size(of: url) ?? 0
                            var offset = try openHandle.offset()
                            // Truncated in place — start over from the top.
                            if size < offset {
                                try openHandle.seek(toOffset: 0)
                                offset = 0
                                pending.removeAll()
                            }
                            if size > offset,
                               let chunk = try openHandle.read(upToCount: Int(size - offset)),
                               !chunk.isEmpty {
                                pending.append(chunk)
                                Self.drainLines(from: &pending) { line in
                                    if let event = LogLineParser.parse(line) {
                                        continuation.yield(event)
                                    }
                                }
                                if pending.count > Self.maxPendingBytes { pending.removeAll() }
                            }
                        } catch {
                            // Reopen on the next tick rather than giving up on the stream.
                            try? openHandle.close()
                            handle = nil
                            openedInode = nil
                        }
                    }

                    try? await Task.sleep(for: pollInterval)
                }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }

    private static func drainLines(from pending: inout Data, emit: (String) -> Void) {
        while let newline = pending.firstIndex(of: 0x0A) {
            let lineData = pending[pending.startIndex..<newline]
            pending.removeSubrange(pending.startIndex...newline)
            guard let line = String(data: lineData, encoding: .utf8) else { continue }
            emit(line.trimmingCharacters(in: .whitespaces))
        }
    }

    private static func inode(of url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return attributes[.systemFileNumber] as? UInt64
    }

    private static func size(of url: URL) -> UInt64? {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path) else {
            return nil
        }
        return (attributes[.size] as? NSNumber)?.uint64Value
    }
}
