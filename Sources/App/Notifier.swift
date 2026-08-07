import Foundation
import OllamaBarCore
import UserNotifications

/// System notifications, kept deliberately quiet.
///
/// Every category is off until the user turns it on, and permission is asked for at that moment
/// rather than at launch — a monitor that opens with a permission dialog before showing anything
/// has not earned the interruption. Each category is also rate limited, because the events it
/// watches arrive in bursts: a thrashing server can swap models several times a minute, and one
/// notification per swap would be worse than none.
@MainActor
@Observable
final class Notifier: MonitorEventObserver {
    /// Nothing is worth two notifications inside this window.
    static let quietPeriod: TimeInterval = 60

    enum Permission: Equatable {
        case unknown
        case granted
        case denied
    }

    private(set) var permission: Permission = .unknown

    private let settings: AppSettings
    private let center: UNUserNotificationCenter?
    private var lastPosted: [String: Date] = [:]
    /// Models we unloaded ourselves. Their eviction is not news.
    private var selfUnloaded: [String: Date] = [:]

    init(settings: AppSettings) {
        self.settings = settings
        // Absent when the code runs outside an app bundle, which is where the CLI and the tests
        // live. `current()` traps there rather than returning nil.
        self.center = Bundle.main.bundleIdentifier == nil ? nil : .current()
        Task { await refreshPermission() }
    }

    // MARK: - Permission

    func refreshPermission() async {
        guard let center else { return }
        let status = await center.notificationSettings().authorizationStatus
        permission = switch status {
        case .authorized, .provisional, .ephemeral: .granted
        case .denied: .denied
        default: .unknown
        }
    }

    /// Called when a toggle is switched on, not at launch.
    func requestPermission() async {
        guard let center else { return }
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound])) ?? false
        permission = granted ? .granted : .denied
    }

    // MARK: - Suppression

    /// Unloading from our own menu should not come back as a notification.
    func willUnload(_ model: String) {
        selfUnloaded[model] = .now
    }

    // MARK: - MonitorEventObserver

    nonisolated func observe(_ events: [MonitorEvent]) {
        Task { @MainActor in
            for event in events { post(event) }
        }
    }

    private func post(_ event: MonitorEvent) {
        guard let center, permission == .granted else { return }
        guard let note = describe(event) else { return }

        let now = Date.now
        if let last = lastPosted[note.category], now.timeIntervalSince(last) < Self.quietPeriod {
            return
        }
        lastPosted[note.category] = now

        let content = UNMutableNotificationContent()
        content.title = note.title
        content.body = note.body
        // No trigger means "now"; a nil-triggered request is delivered immediately.
        center.add(UNNotificationRequest(
            identifier: UUID().uuidString,
            content: content,
            trigger: nil
        ))
    }

    private func describe(_ event: MonitorEvent) -> (category: String, title: String, body: String)? {
        switch event {
        case .modelSwapped(let from, let to):
            guard settings.notifyOnSwap else { return nil }
            return (
                "swap",
                "Model swapped",
                "\(to) displaced \(from). Loading \(from) again will cost seconds."
            )

        case .modelEvicted(let name):
            guard settings.notifyOnEviction else { return nil }
            // Ours, and recent enough that the user is still looking at the menu they clicked.
            if let at = selfUnloaded[name], Date.now.timeIntervalSince(at) < 15 { return nil }
            return ("eviction", "Model unloaded", "\(name) is no longer in memory.")

        case .requestFailed(let model, let path, let reason):
            guard settings.notifyOnFailure else { return nil }
            return ("failure", "Request failed", "\(model ?? path): \(reason)")

        case .modelLoaded:
            // Loading is what the app is for; it is not an interruption.
            return nil
        }
    }
}
