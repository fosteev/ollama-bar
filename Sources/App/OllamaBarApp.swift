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
            MenuBarLabel(state: model.monitor.menuBarState)
        }
        .menuBarExtraStyle(.window)

        Settings {
            SettingsView(model: model)
        }
    }
}
