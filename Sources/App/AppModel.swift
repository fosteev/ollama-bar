import Foundation
import OllamaBarCore
import OllamaBarInfrastructure

/// Owns the monitor, the driver that feeds it and the optional proxy, and rebuilds them when the
/// settings they depend on change. Views read `monitor` directly — there is no ViewModel layer.
@MainActor
@Observable
final class AppModel {
    let monitor = OllamaMonitor()
    let settings: AppSettings

    private var driver: MonitorDriver?
    private var proxy: ProxyServer?

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    /// Read at render time — `ProxyServer` reports its state through a lock, not through
    /// observation, so the panel refreshes this on its own tick.
    var proxyState: ProxyServer.State {
        proxy?.state ?? .stopped
    }

    func start() {
        driver?.stop()
        proxy?.stop()

        let proxy = makeProxy()
        proxy?.start()
        self.proxy = proxy

        let driver = MonitorDriver(
            monitor: monitor,
            inventory: OllamaHTTPClient(baseURL: settings.baseURL),
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
}
