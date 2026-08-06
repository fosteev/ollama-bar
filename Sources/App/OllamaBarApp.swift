import OllamaBarCore
import SwiftUI

@main
struct OllamaBarApp: App {
    @State private var model: AppModel

    /// Monitoring starts with the app, not with the panel: the menu bar label has to show live
    /// throughput whether or not anyone ever opens the panel.
    init() {
        let model = AppModel()
        model.start()
        _model = State(initialValue: model)
    }

    var body: some Scene {
        MenuBarExtra {
            StatusPanel(model: model)
        } label: {
            MenuBarLabel(state: model.monitor.menuBarState, alert: model.alertLevel())
        }
        .menuBarExtraStyle(.window)

        // Reading happens in real windows. The panel closes on focus loss, which makes it useless
        // for anything longer than a glance.
        Window("Output", id: "output") {
            OutputWindow(model: model)
        }
        .defaultSize(width: 560, height: 420)

        Window("Requests", id: "history") {
            HistoryWindow(model: model)
        }
        .defaultSize(width: 620, height: 380)

        Settings {
            SettingsView(model: model)
        }
    }
}
