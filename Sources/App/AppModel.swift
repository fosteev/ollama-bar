import Foundation
import OllamaBarCore
import OllamaBarInfrastructure
import SwiftUI

/// Owns the monitor, the driver that feeds it and the optional proxy, and rebuilds them when the
/// settings they depend on change. Views read `monitor` directly — there is no ViewModel layer.
@MainActor
@Observable
final class AppModel {
    let monitor = OllamaMonitor()
    let settings: AppSettings
    let loginItem = LoginItem()
    let notifier: Notifier

    /// Disclosure state for the last-request row. Remembered across openings, per the design.
    var lastRequestExpanded = false

    /// Live exchanges merged with what was written down. This, not `monitor.exchanges`, is what
    /// the history window shows — the monitor's array stays "what this process saw".
    private(set) var historyRows: [ProxiedExchange] = []
    private(set) var today: DayTotals?
    /// Bumped whenever an exchange reaches the store, so the history window can refresh on an
    /// event instead of polling.
    private(set) var historyGeneration = 0
    /// Set by "Show requests for this model…". Applies to both the table and the totals line.
    var historyFilter: String?
    private(set) var hasStoredHistory = false

    /// Built here rather than in `start()`: settings changes rebuild the driver and the proxy, and
    /// the store has to outlive that.
    private let historyStore: HistoryStore
    private var driver: MonitorDriver?
    private var proxy: ProxyServer?
    private var controller: ModelController?
    private var acknowledgedAlert: String?

    init(settings: AppSettings = AppSettings(), historyStore: HistoryStore? = nil) {
        self.settings = settings
        self.notifier = Notifier(settings: settings)
        self.historyStore = historyStore
            ?? HistoryStore(retentionDays: settings.historyRetentionDays)
        Task { [historyStore = self.historyStore] in
            let stored = await historyStore.hasRecords()
            self.hasStoredHistory = stored
        }
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.recordInFlight()
                self?.flushHistory()
            }
        }
    }

    /// Read at render time — `ProxyServer` reports its state through a lock, not through
    /// observation, so the panel refreshes this on its own tick.
    var proxyState: ProxyServer.State {
        proxy?.state ?? .stopped
    }

    func start() {
        applyAppearance()
        // Settings change through a restart, so this is where a new retention takes effect.
        historyStore.setRetention(days: settings.historyRetentionDays)
        historyStore.prune()
        // Before the driver goes down: tearing it down first means the `.failed` events the
        // sniffer emits on close land in an already-cancelled loop and vanish.
        recordInFlight()
        driver?.stop()
        proxy?.stop()

        let client = OllamaHTTPClient(baseURL: settings.baseURL)
        controller = client

        let proxy = makeProxy()
        proxy?.start()
        self.proxy = proxy

        let driver = MonitorDriver(
            monitor: monitor,
            inventory: client,
            events: ServerLogTailer(url: settings.logURL),
            proxy: proxy,
            recorder: settings.historyEnabled ? historyTap : nil,
            observer: settings.notifiesAnything ? notifier : nil,
            pollInterval: .seconds(settings.pollInterval)
        )
        driver.start()
        self.driver = driver
    }

    /// Writes down whatever is still streaming. Called on quit and before a restart — such an
    /// exchange has no ending and lands as `abandoned`. Re-recording one across two restarts is
    /// harmless: the index is a journal and the last record for an id wins.
    func recordInFlight() {
        guard settings.historyEnabled else { return }
        let active = monitor.exchanges.filter(\.isActive)
        guard !active.isEmpty else { return }
        historyStore.record(active)
    }

    /// Flushes the write queue. The app must not exit while a record is still in it.
    func flushHistory() {
        historyStore.flush()
    }

    private var historyTap: ExchangeRecorder {
        HistoryTap(store: historyStore) { [weak self] in
            Task { @MainActor in self?.noticeRecordedExchange() }
        }
    }

    private func noticeRecordedExchange() {
        hasStoredHistory = true
        historyGeneration += 1
    }

    /// Passes exchanges to the store and lets the window know something landed.
    private struct HistoryTap: ExchangeRecorder {
        let store: HistoryStore
        let noticed: @Sendable () -> Void

        func record(_ exchanges: [ProxiedExchange]) {
            store.record(exchanges)
            noticed()
        }
    }

    // MARK: - History

    /// Everything the history window shows: live exchanges first, then what is on disk, deduped.
    func refreshHistory() async {
        let stored = await historyStore.recent(
            limit: 500,
            days: settings.historyRetentionDays,
            model: historyFilter
        )
        let live = monitor.exchanges
            .filter { historyFilter == nil || $0.model == historyFilter }
            .reversed()

        var seen: Set<UUID> = []
        // Live wins over stored — it is the fresher copy of the same exchange.
        historyRows = (Array(live) + stored.map(\.exchange)).filter { seen.insert($0.id).inserted }
        today = await historyStore.totals()
    }

    /// Loaded only when a row is selected — the texts are the expensive half of the record.
    func historyBody(for exchange: ProxiedExchange) async -> ExchangeBody? {
        // Still in memory: no reason to go to disk.
        if let live = monitor.exchanges.first(where: { $0.id == exchange.id }) {
            return ExchangeBody(live)
        }
        return await historyStore.body(id: exchange.id, startedAt: exchange.startedAt)
    }

    var hasHistory: Bool {
        !monitor.exchanges.isEmpty || hasStoredHistory
    }

    func showHistory(for model: String) {
        historyFilter = model
    }

    /// Called after settings change — host, port, log path and the proxy are baked into the
    /// running driver, so the cheapest correct thing is to build a new one.
    func restart() {
        start()
    }

    private func makeProxy() -> ProxyServer? {
        guard settings.proxyEnabled,
              let port = UInt16(exactly: settings.proxyPort),
              port > 0
        else { return nil }

        return ProxyServer(
            listenPort: port,
            upstreamHost: settings.upstreamHost,
            upstreamPort: settings.upstreamPort
        )
    }

    /// `nil` hands the app back to the system setting.
    func applyAppearance() {
        NSApplication.shared.appearance = settings.appearance.nsAppearance
    }

    // MARK: - Actions

    func unload(_ model: String) {
        guard let controller else { return }
        // So the eviction we are about to cause does not come back as a notification.
        notifier.willUnload(model)
        Task { try? await controller.unload(model: model) }
    }

    func pin(_ model: String) {
        guard let controller else { return }
        Task { try? await controller.pin(model: model) }
    }

    // MARK: - Model listings

    /// One row per installed model, with whatever we know about it from memory and from history.
    struct ModelListing: Identifiable {
        let installed: InstalledModel
        let loaded: LoadedModel?
        let lastUsed: Date?

        var id: String { installed.name }
    }

    /// Resident models first — they are the ones costing something right now.
    var modelListings: [ModelListing] {
        monitor.installed
            .map { installed in
                ModelListing(
                    installed: installed,
                    loaded: monitor.loaded.first { $0.name == installed.name },
                    lastUsed: monitor.exchanges.last { $0.model == installed.name }?.startedAt
                )
            }
            .sorted { left, right in
                if (left.loaded != nil) != (right.loaded != nil) { return left.loaded != nil }
                return left.installed.name < right.installed.name
            }
    }

    // MARK: - Alerts

    /// Level the menu bar icon should be tinted with. Clears once the panel has been opened —
    /// at that point the warning has been delivered and colour would just be decoration.
    enum AlertLevel {
        case none
        case warning
        case error
    }

    func alertLevel(now: Date = .now) -> AlertLevel {
        guard let warning = monitor.warnings(now: now).first, warning.id != acknowledgedAlert else {
            return .none
        }
        return warning.isError ? .error : .warning
    }

    func acknowledgeAlerts(now: Date = .now) {
        acknowledgedAlert = monitor.warnings(now: now).first?.id
    }

    // MARK: - Activity

    /// What the activity block shows. Nil means idle, and idle collapses to a single line.
    struct Activity {
        let label: String
        let headline: String
        let tint: Color
        let meta: [String]
        let contextFill: OllamaMonitor.ContextFill?
        /// How much of the prompt the server reused. Nil when the log has not said recently.
        let reuse: SlotReuse?
    }

    func activity(now: Date = .now) -> Activity? {
        let fill = monitor.contextFill(now: now)
        let reuse = monitor.promptReuse(now: now)
        let active = monitor.activeExchange

        // A reasoning model produces nothing but thinking for tens of seconds. Showing speed there
        // answers the wrong question — what the user wants is "how long has it been at this?".
        if let active, active.output.isEmpty, !active.reasoning.isEmpty {
            return Activity(
                label: "Thinking",
                headline: Format.elapsed(now.timeIntervalSince(active.startedAt)),
                tint: Panel.Palette.reasoning,
                meta: meta(active: active, includeRate: true),
                contextFill: fill,
                reuse: reuse
            )
        }

        guard let throughput = monitor.throughput else { return nil }
        return Activity(
            label: "Generating",
            headline: Format.rate(throughput.tokensPerSecond),
            tint: Panel.Palette.generating,
            meta: meta(active: active, includeRate: false),
            contextFill: fill,
            reuse: reuse
        )
    }

    private func meta(active: ProxiedExchange?, includeRate: Bool) -> [String] {
        var items: [String] = []
        if let slot = monitor.throughput?.slotID { items.append("slot \(slot)") }
        if let client = active?.client.map(Self.shortClient) { items.append(client) }
        if includeRate, let rate = monitor.throughput?.tokensPerSecond {
            items.append(Format.rate(rate))
        } else if let started = active?.startedAt {
            items.append(Format.elapsed(Date.now.timeIntervalSince(started)))
        }
        if let tokens = monitor.throughput?.tokensDecoded, tokens > 0 {
            items.append("\(tokens) tok")
        }
        return items
    }

    /// User-Agents run long; the product and version are the identifying part.
    private static func shortClient(_ userAgent: String) -> String {
        userAgent.split(separator: " ").first.map(String.init) ?? userAgent
    }
}
