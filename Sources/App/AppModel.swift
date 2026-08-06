import Foundation
import OllamaBarCore
import OllamaBarInfrastructure

/// Owns the monitor and the driver that feeds it, and rebuilds the driver when the settings
/// it depends on change. Views read `monitor` directly — there is no ViewModel layer.
@MainActor
@Observable
final class AppModel {
    let monitor = OllamaMonitor()
    let settings: AppSettings

    private var driver: MonitorDriver?

    init(settings: AppSettings = AppSettings()) {
        self.settings = settings
    }

    func start() {
        driver?.stop()
        let driver = MonitorDriver(
            monitor: monitor,
            inventory: OllamaHTTPClient(baseURL: settings.baseURL),
            events: ServerLogTailer(url: settings.logURL),
            pollInterval: .seconds(settings.pollInterval)
        )
        driver.start()
        self.driver = driver
    }

    /// Called after settings change — host, port and log path are baked into the running driver.
    func restart() {
        start()
    }
}
