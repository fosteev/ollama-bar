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
