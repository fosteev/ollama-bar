import Foundation

public enum ConnectionState: Sendable, Equatable {
    case unknown
    case connected
    case unreachable(String)
}

/// Current generation speed, attributed to the slot that produced it.
public struct Throughput: Sendable, Equatable {
    public let tokensPerSecond: Double
    public let slotID: Int
    /// Tokens produced so far in this decode — the log counts them for us.
    public let tokensDecoded: Int
    public let updatedAt: Date

    public init(tokensPerSecond: Double, slotID: Int, tokensDecoded: Int = 0, updatedAt: Date) {
        self.tokensPerSecond = tokensPerSecond
        self.slotID = slotID
        self.tokensDecoded = tokensDecoded
        self.updatedAt = updatedAt
    }
}

/// What the menu bar itself shows. Deliberately small and separate from the full state so the
/// menu-bar label does not redraw whenever the inventory changes — see docs/PLAN.md.
public enum MenuBarState: Sendable, Equatable {
    case unreachable
    case idle(loadedCount: Int)
    case generating(tokensPerSecond: Double)
}

/// Single source of truth for everything the app knows about the local Ollama server.
///
/// Pure state machine: it never performs I/O on its own schedule. `MonitorDriver` feeds it.
@MainActor
@Observable
public final class OllamaMonitor {
    /// How long after the last `print_timing` line generation is considered finished.
    ///
    /// Measured against a live server: llama.cpp emits these lines every 3.0 s almost exactly.
    /// A timeout shorter than that makes the reading blink out between every pair of lines, which
    /// is what a 2 s timeout did. Five seconds clears the cadence with margin; the access log
    /// below usually ends the reading sooner anyway.
    public static let generationTimeout: TimeInterval = 5

    /// How many access-log entries to keep in memory.
    public static let requestHistoryLimit = 200

    /// How many proxied exchanges to keep, and how much text to retain per exchange. Completions
    /// can be enormous and several slots can run at once, so this is bounded from the start.
    public static let exchangeHistoryLimit = 50
    public static let outputLimit = 32 * 1024

    public private(set) var connection: ConnectionState = .unknown
    public private(set) var loaded: [LoadedModel] = []
    public private(set) var installed: [InstalledModel] = []
    public private(set) var throughput: Throughput?
    public private(set) var recentRequests: [RequestLogEntry] = []
    public private(set) var lastCheckpoint: ContextCheckpoint?
    public private(set) var lastCheckpointAt: Date?
    /// The last prompt-reuse decision the server logged, and when we saw it.
    public private(set) var lastReuse: SlotReuse?
    public private(set) var lastReuseAt: Date?
    /// Exchanges seen through the proxy, oldest first. Empty unless the proxy is running.
    public private(set) var exchanges: [ProxiedExchange] = []

    /// When the server last answered, for the "last seen 3m ago" line while it is down.
    public private(set) var lastSeenAt: Date?
    /// When generation last stopped, for the "idle · 2m" line.
    public private(set) var generationEndedAt: Date?
    /// Timestamps of model loads seen in the last hour — repeated loads mean VRAM thrashing.
    public private(set) var reloads: [Date] = []

    private var residentNames: Set<String> = []
    private var everResidentNames: Set<String> = []
    /// The first poll describes the world as we found it, not as something that just happened.
    private var hasPolledInventory = false

    public init() {}

    /// The exchange whose output is worth showing right now.
    public var activeExchange: ProxiedExchange? {
        exchanges.last { $0.isActive && $0.status != nil }
    }

    public var menuBarState: MenuBarState {
        if case .unreachable = connection { return .unreachable }
        if let throughput { return .generating(tokensPerSecond: throughput.tokensPerSecond) }
        return .idle(loadedCount: loaded.count)
    }

    /// Total resident bytes across all loaded models.
    public var residentBytes: Int64 {
        loaded.reduce(0) { $0 + $1.size }
    }

    /// How full the context is right now, from the checkpoint lines the server writes while it
    /// works. Stale checkpoints are ignored — an hour-old figure is worse than none.
    public struct ContextFill: Sendable, Equatable {
        public let used: Int
        public let limit: Int
        public var fraction: Double { limit > 0 ? min(1, Double(used) / Double(limit)) : 0 }
    }

    public func contextFill(now: Date = .now) -> ContextFill? {
        guard let checkpoint = lastCheckpoint,
              let at = lastCheckpointAt,
              now.timeIntervalSince(at) < 300,
              let limit = loaded.first?.contextLength,
              limit > 0
        else { return nil }
        return ContextFill(used: checkpoint.tokens, limit: limit)
    }

    /// The last prompt-reuse decision, if it is recent enough to be about what is running now.
    /// The log line has no request id, so recency is the only link there is — and a stale figure
    /// attributed to the wrong request would be worse than showing nothing.
    public func promptReuse(now: Date = .now) -> SlotReuse? {
        guard let lastReuse, let at = lastReuseAt, now.timeIntervalSince(at) < 60 else { return nil }
        return lastReuse
    }

    /// Ordered by severity, worst first. At most one is ever shown; the rest are counted.
    public func warnings(now: Date = .now) -> [MonitorWarning] {
        var result: [MonitorWarning] = []

        if let failed = exchanges.last(where: { $0.isFailure }),
           let at = failed.finishedAt,
           now.timeIntervalSince(at) < 60 {
            result.append(
                .requestFailed(
                    status: failed.status,
                    path: failed.path,
                    message: failed.failure ?? "request failed",
                    client: failed.client,
                    at: at
                )
            )
        }

        if let fill = contextFill(now: now), fill.fraction >= 0.9 {
            result.append(.contextNearlyFull(used: fill.used, limit: fill.limit))
        }

        if reloads.count >= 3 {
            let lost = exchanges
                .compactMap { $0.timings?.load }
                .filter { $0 > 0 }
                .reduce(0, +)
            result.append(.modelReloads(count: reloads.count, secondsLost: lost > 0 ? lost : nil))
        }

        return result.sorted { $0.severity > $1.severity }
    }

    /// Loaded models change constantly — this is the hot path, polled on every tick. Returns what
    /// changed since the previous poll, for whoever cares to say it out loud.
    @discardableResult
    public func refreshLoaded(
        using source: ModelInventorySource,
        now: Date = .now
    ) async -> [MonitorEvent] {
        do {
            let models = try await source.loadedModels()
            let events = noteResidency(of: models, now: now)
            loaded = models
            connection = .connected
            lastSeenAt = now
            return events
        } catch {
            connection = .unreachable(error.localizedDescription)
            return []
        }
    }

    /// A model that goes away and comes back was reloaded — Ollama gives no event for this, but
    /// each reload costs seconds of weight loading, and four in an hour is worth saying out loud.
    private func noteResidency(of models: [LoadedModel], now: Date) -> [MonitorEvent] {
        let names = Set(models.map(\.name))
        let returned = names.subtracting(residentNames).intersection(everResidentNames)
        reloads.append(contentsOf: returned.map { _ in now })
        reloads.removeAll { now.timeIntervalSince($0) > 3600 }

        let arrived = names.subtracting(residentNames).sorted()
        let gone = residentNames.subtracting(names).sorted()
        everResidentNames.formUnion(names)
        residentNames = names

        guard hasPolledInventory else {
            hasPolledInventory = true
            return []
        }
        // One in, one out, in the same poll: that is a swap, and it is the one people care about,
        // because the model that left will cost seconds to load again.
        if arrived.count == 1, gone.count == 1 {
            return [.modelSwapped(from: gone[0], to: arrived[0])]
        }
        return gone.map { .modelEvicted($0) } + arrived.map { .modelLoaded($0) }
    }

    /// The disk inventory changes only when someone pulls or deletes a model. A failure here keeps
    /// the previous list rather than blanking the UI.
    public func refreshInstalled(using source: ModelInventorySource) async {
        if let models = try? await source.installedModels() {
            installed = models
        }
    }

    public func refreshInventory(using source: ModelInventorySource) async {
        await refreshLoaded(using: source)
        await refreshInstalled(using: source)
    }

    public func apply(_ event: LogEvent, now: Date = .now) {
        switch event {
        case .timing(let timing):
            // `tg` is the average over the whole decode and barely moves (29.7–30.2 t/s across a
            // real run); `tg_3s` covers a three-second window and swings by a quarter between
            // samples. The steady one is the readable one.
            throughput = Throughput(
                tokensPerSecond: timing.tokensPerSecond,
                slotID: timing.slotID,
                tokensDecoded: timing.tokensDecoded,
                updatedAt: now
            )
        case .request(let entry):
            // The access-log line is written when the handler returns, so a finished generation
            // request is a definite end — better than waiting out the timeout.
            if entry.isGeneration, throughput != nil {
                generationEndedAt = now
                throughput = nil
            }
            recentRequests.append(entry)
            if recentRequests.count > Self.requestHistoryLimit {
                recentRequests.removeFirst(recentRequests.count - Self.requestHistoryLimit)
            }
        case .checkpoint(let checkpoint):
            lastCheckpoint = checkpoint
            lastCheckpointAt = now
        case .slotReuse(let reuse):
            lastReuse = reuse
            lastReuseAt = now
        }
    }

    /// Returns the exchanges that just left the live set and are worth writing down: the one that
    /// reached a terminal event, or the ones the history limit evicted mid-flight. Still no I/O
    /// here — the monitor only says what happened, `MonitorDriver` decides who hears it.
    @discardableResult
    public func apply(_ event: ProxyEvent) -> [ProxiedExchange] {
        switch event {
        case .started(let exchange):
            exchanges.append(exchange)
            guard exchanges.count > Self.exchangeHistoryLimit else { return [] }
            let dropped = exchanges.prefix(exchanges.count - Self.exchangeHistoryLimit)
            // Finished ones were already reported at their terminal event; only the still-running
            // ones would otherwise vanish without a trace.
            let unfinished = dropped.filter(\.isActive)
            exchanges.removeFirst(exchanges.count - Self.exchangeHistoryLimit)
            return unfinished

        case .responded(let id, let status):
            update(id) { $0.status = status }
            return []

        case .output(let id, let delta, let kind):
            update(id) { exchange in
                switch kind {
                case .content: Self.append(delta, to: &exchange.output, truncated: &exchange.outputTruncated)
                case .reasoning: Self.append(delta, to: &exchange.reasoning, truncated: &exchange.outputTruncated)
                }
            }
            return []

        case .toolCall(let id, let name):
            update(id) { $0.toolCalls.append(name) }
            return []

        case .completed(let id, let promptTokens, let completionTokens, let timings, let at):
            return finished(update(id) { exchange in
                exchange.promptTokens = promptTokens ?? exchange.promptTokens
                exchange.completionTokens = completionTokens ?? exchange.completionTokens
                exchange.timings = timings ?? exchange.timings
                exchange.finishedAt = at
            })

        case .failed(let id, let reason, let at):
            return finished(update(id) { exchange in
                exchange.failure = reason
                exchange.finishedAt = at
            })
        }
    }

    @discardableResult
    private func update(_ id: UUID, _ body: (inout ProxiedExchange) -> Void) -> ProxiedExchange? {
        guard let index = exchanges.lastIndex(where: { $0.id == id }) else { return nil }
        body(&exchanges[index])
        return exchanges[index]
    }

    private func finished(_ exchange: ProxiedExchange?) -> [ProxiedExchange] {
        exchange.map { [$0] } ?? []
    }

    private static func append(_ delta: String, to text: inout String, truncated: inout Bool) {
        guard text.utf8.count < outputLimit else {
            truncated = true
            return
        }
        text += delta
    }

    /// Drops the throughput reading once the log has been quiet for `generationTimeout`.
    public func expireStaleThroughput(now: Date = .now) {
        guard let throughput else { return }
        if now.timeIntervalSince(throughput.updatedAt) >= Self.generationTimeout {
            self.throughput = nil
            generationEndedAt = throughput.updatedAt
        }
    }
}
