import Foundation
import ServiceManagement

/// Single source of truth for the SMAppService toggle. Used by both the
/// General settings pane and the onboarding screen so they can't drift apart.
enum LaunchAtLogin {
    static func apply(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Mojito: launch-at-login toggle failed: \(error)")
        }
    }

    /// Never overrides a user's disabled/approval-required login-item choice.
    static func shouldRegister(status: SMAppService.Status) -> Bool {
        status == .notRegistered || status == .notFound
    }

    static var statusCode: Int { SMAppService.mainApp.status.rawValue }

    /// Called only by the installed running GUI app, never by a helper binary.
    static func enableIfNeeded() -> (status: Int, error: String) {
        var failure = ""
        let service = SMAppService.mainApp
        if shouldRegister(status: service.status) {
            do { try service.register() }
            catch { failure = error.localizedDescription }
        }
        syncFromSystem()
        return (service.status.rawValue, failure)
    }

    static var isEnabled: Bool {
        SMAppService.mainApp.status == .enabled
    }

    /// Mirrors system state into the `@AppStorage` key so toggles stay accurate
    /// when the user removes Mojito from System Settings → Login Items.
    static func syncFromSystem() {
        let current = isEnabled
        if UserDefaults.standard.bool(forKey: PrefsKey.launchAtLogin) != current {
            UserDefaults.standard.set(current, forKey: PrefsKey.launchAtLogin)
        }
    }
}
