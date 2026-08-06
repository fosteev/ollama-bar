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

    /// Disclosure state for the last-request row. Remembered across openings, per the design.
    var lastRequestExpanded = false

    private var driver: MonitorDriver?
    private var proxy: ProxyServer?
    private var controller: ModelController?
    private var acknowledgedAlert: String?

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    /// Read at render time — `ProxyServer` reports its state through a lock, not through
    /// observation, so the panel refreshes this on its own tick.
    var proxyState: ProxyServer.State {
        proxy?.state ?? .stopped
    }

    func start() {
        applyAppearance()
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
            pollInterval: .seconds(settings.pollInterval)
        )
        driver.start()
        self.driver = driver
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
    }

    func activity(now: Date = .now) -> Activity? {
        let fill = monitor.contextFill(now: now)
        let active = monitor.activeExchange

        // A reasoning model produces nothing but thinking for tens of seconds. Showing speed there
        // answers the wrong question — what the user wants is "how long has it been at this?".
        if let active, active.output.isEmpty, !active.reasoning.isEmpty {
            return Activity(
                label: "Thinking",
                headline: Format.elapsed(now.timeIntervalSince(active.startedAt)),
                tint: Panel.Palette.reasoning,
                meta: meta(active: active, includeRate: true),
                contextFill: fill
            )
        }

        guard let throughput = monitor.throughput else { return nil }
        return Activity(
            label: "Generating",
            headline: Format.rate(throughput.tokensPerSecond),
            tint: Panel.Palette.generating,
            meta: meta(active: active, includeRate: false),
            contextFill: fill
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
