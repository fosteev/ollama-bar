import Foundation
import OllamaBarCore
import OllamaBarInfrastructure

@main
struct OllamaBarCLI {
    @MainActor
    static func main() async throws {
        let options = Options(arguments: CommandLine.arguments)
        if options.showHelp {
            print(Options.usage)
            return
        }

        let monitor = OllamaMonitor()
        let client = OllamaHTTPClient(baseURL: options.baseURL)

        if options.once {
            await monitor.refreshInventory(using: client)
            render(monitor, options: options)
            return
        }

        let driver = MonitorDriver(
            monitor: monitor,
            inventory: client,
            events: ServerLogTailer(url: options.logURL),
            pollInterval: .seconds(options.interval)
        )
        driver.start()

        while true {
            render(monitor, options: options)
            try await Task.sleep(for: .seconds(options.interval))
        }
    }

    @MainActor
    private static func render(_ monitor: OllamaMonitor, options: Options) {
        var out = ""
        if options.isTTY { out += "\u{1B}[2J\u{1B}[H" }

        out += "ollama-bar  \(options.baseURL.absoluteString)\n"

        switch monitor.connection {
        case .unknown:
            out += "connecting…\n"
        case .unreachable(let reason):
            out += "unreachable — \(reason)\n"
        case .connected:
            out += "\n"
            if monitor.loaded.isEmpty {
                out += "no models loaded (\(monitor.installed.count) installed)\n"
            } else {
                for model in monitor.loaded {
                    out += describe(model) + "\n"
                }
                out += "\ntotal resident: \(Format.bytes(monitor.residentBytes))\n"
            }
        }

        if let throughput = monitor.throughput {
            out += "generating: \(Format.rate(throughput.tokensPerSecond)) (slot \(throughput.slotID))\n"
        } else {
            out += "generating: —\n"
        }

        if let checkpoint = monitor.lastCheckpoint {
            out += "context: \(Format.tokens(checkpoint.tokens)) tokens, "
            out += "checkpoint \(checkpoint.index)/\(checkpoint.total)\n"
        }

        out += "menu bar: \(describe(monitor.menuBarState))\n"

        let requests = monitor.recentRequests.filter { !$0.isInventoryPoll }.suffix(5)
        if !requests.isEmpty {
            out += "\nrecent requests:\n"
            for request in requests {
                out += "  \(Format.clock(request.timestamp))  \(request.status)  "
                out += "\(request.method) \(request.path)  \(Format.duration(request.duration))\n"
            }
        }

        print(out, terminator: "")
    }

    private static func describe(_ model: LoadedModel) -> String {
        let placement = model.isFullyOnGPU
            ? "GPU"
            : "GPU \(Int((model.vramFraction * 100).rounded()))%"
        return """
        \(model.name)
          \(model.details.parameterSize) \(model.details.quantizationLevel)  \
        \(Format.bytes(model.size))  \(placement)  \
        ctx \(Format.tokens(model.contextLength))  \
        \(Format.eviction(model.timeUntilEviction()))
        """
    }

    private static func describe(_ state: MenuBarState) -> String {
        switch state {
        case .unreachable: "(dimmed icon)"
        case .idle(let count): count == 0 ? "(icon)" : "(icon + dot, \(count) loaded)"
        case .generating(let rate): "\(Format.rate(rate))"
        }
    }
}

private struct Options {
    var baseURL = OllamaHTTPClient.defaultBaseURL
    var logURL = ServerLogTailer.defaultURL
    var interval = 2
    var once = false
    var showHelp = false
    let isTTY = isatty(FileHandle.standardOutput.fileDescriptor) == 1

    static let usage = """
    usage: ollama-bar-cli [--host URL] [--log PATH] [--interval SECONDS] [--once]

      --host      Ollama base URL (default \(OllamaHTTPClient.defaultBaseURL))
      --log       server.log path (default \(ServerLogTailer.defaultURL.path))
      --interval  refresh interval in seconds (default 2)
      --once      print one inventory snapshot and exit (no log tailing)
    """

    init(arguments: [String]) {
        var iterator = arguments.dropFirst().makeIterator()
        while let argument = iterator.next() {
            switch argument {
            case "--host":
                if let value = iterator.next(), let url = URL(string: value) { baseURL = url }
            case "--log":
                if let value = iterator.next() { logURL = URL(filePath: value) }
            case "--interval":
                if let value = iterator.next(), let seconds = Int(value), seconds > 0 {
                    interval = seconds
                }
            case "--once":
                once = true
            case "--help", "-h":
                showHelp = true
            default:
                break
            }
        }
    }
}

private enum Format {
    static func bytes(_ value: Int64) -> String {
        let units = ["B", "KiB", "MiB", "GiB", "TiB"]
        var size = Double(value)
        var unit = 0
        while size >= 1024, unit < units.count - 1 {
            size /= 1024
            unit += 1
        }
        return unit == 0 ? "\(value) B" : String(format: "%.1f %@", size, units[unit])
    }

    static func tokens(_ value: Int) -> String {
        value >= 1024 ? "\(value / 1024)K" : "\(value)"
    }

    static func rate(_ value: Double) -> String {
        String(format: "%.1f t/s", value)
    }

    /// Ollama lists a model in `/api/ps` past its `expires_at` — eviction is lazy, so a
    /// non-positive countdown means "due", not "gone".
    static func eviction(_ seconds: TimeInterval) -> String {
        guard seconds > 0 else { return "eviction due" }
        let total = Int(seconds.rounded())
        return String(format: "evicts in %d:%02d", total / 60, total % 60)
    }

    static func duration(_ seconds: TimeInterval) -> String {
        if seconds < 1e-3 { return String(format: "%.0f µs", seconds * 1e6) }
        if seconds < 1 { return String(format: "%.1f ms", seconds * 1e3) }
        return String(format: "%.2f s", seconds)
    }

    static func clock(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter.string(from: date)
    }
}
