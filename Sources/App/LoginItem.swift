import Foundation
import ServiceManagement

/// Registration as a login item, through `SMAppService`. There is no separate helper bundle: the
/// app itself is what should come back after a reboot.
///
/// Registration is asynchronous from the app's point of view — macOS can put a request in
/// "waiting for approval" and only the user can finish it, from System Settings. That state is the
/// whole reason this is a type and not a one-line toggle.
@MainActor
@Observable
final class LoginItem {
    enum State: Equatable {
        case off
        case on
        /// macOS accepted the request but the user has to approve it in System Settings.
        case waitingForApproval
        case failed(String)

        var isEnabled: Bool { self == .on }
    }

    private(set) var state: State = .off

    init() {
        refresh()
    }

    func refresh() {
        state = Self.read(SMAppService.mainApp.status)
    }

    func set(_ enabled: Bool) {
        do {
            if enabled {
                // Registering twice throws rather than being a no-op.
                if SMAppService.mainApp.status != .enabled {
                    try SMAppService.mainApp.register()
                }
            } else {
                try SMAppService.mainApp.unregister()
            }
            refresh()
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    /// Opens the pane where a "waiting for approval" item can be switched on.
    func openSystemSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }

    private static func read(_ status: SMAppService.Status) -> State {
        switch status {
        case .enabled: .on
        case .requiresApproval: .waitingForApproval
        case .notRegistered: .off
        case .notFound: .failed("the app bundle is not where the system expects it")
        @unknown default: .off
        }
    }
}
