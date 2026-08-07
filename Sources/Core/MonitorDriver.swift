import Foundation

/// Drives `OllamaMonitor`: polls the inventory, consumes log events, and expires stale
/// throughput readings. Kept thin — the logic worth testing lives in the monitor.
@MainActor
public final class MonitorDriver {
    private let monitor: OllamaMonitor
    private let inventory: ModelInventorySource
    private let events: LogEventSource
    private let proxy: ProxyEventSource?
    private let recorder: ExchangeRecorder?
    private let observer: MonitorEventObserver?
    private let pollInterval: Duration
    private let installedPollInterval: Duration
    private let expiryTick: Duration
    private var tasks: [Task<Void, Never>] = []

    public init(
        monitor: OllamaMonitor,
        inventory: ModelInventorySource,
        events: LogEventSource,
        proxy: ProxyEventSource? = nil,
        recorder: ExchangeRecorder? = nil,
        observer: MonitorEventObserver? = nil,
        pollInterval: Duration = .seconds(2),
        installedPollInterval: Duration = .seconds(30),
        expiryTick: Duration = .milliseconds(500)
    ) {
        self.monitor = monitor
        self.inventory = inventory
        self.events = events
        self.proxy = proxy
        self.recorder = recorder
        self.observer = observer
        self.pollInterval = pollInterval
        self.installedPollInterval = installedPollInterval
        self.expiryTick = expiryTick
    }

    deinit {
        for task in tasks { task.cancel() }
    }

    public func start() {
        guard tasks.isEmpty else { return }

        tasks.append(Task { [monitor, inventory, observer, pollInterval] in
            while !Task.isCancelled {
                let changes = await monitor.refreshLoaded(using: inventory)
                if !changes.isEmpty { observer?.observe(changes) }
                try? await Task.sleep(for: pollInterval)
            }
        })

        tasks.append(Task { [monitor, inventory, installedPollInterval] in
            while !Task.isCancelled {
                await monitor.refreshInstalled(using: inventory)
                try? await Task.sleep(for: installedPollInterval)
            }
        })

        tasks.append(Task { [monitor, events] in
            for await event in events.events() {
                if Task.isCancelled { return }
                monitor.apply(event)
            }
        })

        if let proxy {
            tasks.append(Task { [monitor, proxy, recorder, observer] in
                for await event in proxy.events() {
                    if Task.isCancelled { return }
                    let finished = monitor.apply(event)
                    guard !finished.isEmpty else { continue }
                    recorder?.record(finished)
                    let failures = finished.filter(\.isFailure).map {
                        MonitorEvent.requestFailed(
                            model: $0.model,
                            path: $0.path,
                            reason: $0.failure ?? "HTTP \($0.status.map(String.init) ?? "error")"
                        )
                    }
                    if !failures.isEmpty { observer?.observe(failures) }
                }
            })
        }

        tasks.append(Task { [monitor, expiryTick] in
            while !Task.isCancelled {
                try? await Task.sleep(for: expiryTick)
                monitor.expireStaleThroughput()
            }
        })
    }

    public func stop() {
        for task in tasks { task.cancel() }
        tasks.removeAll()
    }
}
