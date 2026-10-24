import AppKit
import Combine

/// Update entry point for the public fork.
///
/// The fork is distributed through GitHub releases. It deliberately does not
/// run Sparkle or poll in the background: checking for an update is an explicit
/// user action and opens the release page in the user's browser.
@MainActor
final class UpdaterCoordinator: NSObject, ObservableObject {
    static let shared = UpdaterCoordinator()

    /// Kept for the menu-bar status plumbing. GitHub release checks do not
    /// expose a background "available" state, so both values remain false.
    @Published private(set) var hasUpdateError = false
    @Published private(set) var hasUpdateAvailable = false

    private let releasesURL = URL(string: "https://github.com/todd866/spritz/releases")!

    /// The fork has no automatic updater to start.
    func start() {
        hasUpdateError = false
        hasUpdateAvailable = false
    }

    /// Opens the public release page for an explicit, manual check.
    func checkForUpdates() {
        hasUpdateError = false
        hasUpdateAvailable = false
        NSWorkspace.shared.open(releasesURL)
    }

    /// Retained as a compatibility surface for onboarding and older settings
    /// state. Automatic updates are permanently disabled in this fork.
    var automaticUpdates: Bool {
        get { false }
        set { /* intentionally disabled */ }
    }
}
