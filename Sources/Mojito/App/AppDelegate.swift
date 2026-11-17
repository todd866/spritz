import AppKit
import ApplicationServices
import Combine
import KeyboardShortcuts
import os.log
import SwiftUI

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, ObservableObject {
    let permissions = PermissionsCoordinator()
    let exclusions = ExclusionStore.shared
    let database = EmojiDatabase.shared
    let engine: Engine

    private static let migrateLaunchAtLoginKey = "spritz.migrateLaunchAtLogin"
    private let log = OSLog(subsystem: "ee.wells.Mojito", category: "AppDelegate")
    private let menuBar = MenuBarController()
    private let onboardingController = OnboardingWindowController()
    private let settingsController = SettingsWindowController()
    private var observers = Set<AnyCancellable>()
    private var touchBarBridge: TouchBarBridge?

    override init() {
        engine = Engine(database: database, exclusions: exclusions)
        super.init()
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        os_log("applicationDidFinishLaunching", log: log, type: .info)
        // SingleInstanceCoordinator queued a terminate() in main.swift if
        // we're yielding to a peer. Bail before doing anything expensive.
        if SingleInstanceCoordinator.shared.willQuitDueToPeer {
            os_log("Skipping launch setup; yielding to existing peer instance", log: log, type: .info)
            return
        }
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        applyAppIcon()

        // Bound every AX query globally. Without this, a revoked Accessibility
        // grant (or a hung target app) makes synchronous AX calls on the
        // keystroke path block forever — and since the event-tap callback runs
        // on the main thread, that freezes the keyboard system-wide. Set on the
        // system-wide element, it's the default timeout for all AX messages.
        AXUIElementSetMessagingTimeout(AXUIElementCreateSystemWide(), 0.5)

        permissions.startMonitoring()
        engine.attach(permissions: permissions)
        // Start observing focus changes before the user types their first `:`.
        _ = FocusedElementCache.shared
        UpdaterCoordinator.shared.start()

        // About → Stats reads this for "User since".
        if UserDefaults.standard.object(forKey: PrefsKey.firstLaunchDate) == nil {
            UserDefaults.standard.set(Date().timeIntervalSince1970, forKey: PrefsKey.firstLaunchDate)
        }

        // One-shot used when an existing install is copied onto this bundle id.
        // Cleared immediately so a later System Settings change is not undone.
        if UserDefaults.standard.bool(forKey: Self.migrateLaunchAtLoginKey) {
            UserDefaults.standard.removeObject(forKey: Self.migrateLaunchAtLoginKey)
            LaunchAtLogin.apply(UserDefaults.standard.bool(forKey: PrefsKey.launchAtLogin))
        }

        // Arrows were a sub-toggle of emoticons before v1.4: emoticons off
        // meant arrows implicitly off, and the hidden sub-toggle was never
        // written. Pin that state now that the toggles are independent, so
        // updating doesn't switch arrow conversion on behind anyone's back.
        // Self-limiting: a no-op once the arrow key holds any value.
        if UserDefaults.standard.object(forKey: PrefsKey.arrowConversionEnabled) == nil,
           (UserDefaults.standard.object(forKey: PrefsKey.emoticonsEnabled) as? Bool) == false {
            UserDefaults.standard.set(false, forKey: PrefsKey.arrowConversionEnabled)
        }

        // Anonymous, consent-gated daily stats. Self-gates — a no-op until the
        // user has seen the notice and left it enabled.
        TelemetryUploader.shared.uploadIfDue()
        scheduleTelemetryFlush()

        menuBar.install(
            engine: engine,
            permissions: permissions,
            openSettings: { [weak self] in self?.openSettings() }
        )

        if let until = UserDefaults.standard.object(forKey: PrefsKey.pausedUntil) as? TimeInterval {
            let date = Date(timeIntervalSince1970: until)
            if date > Date() { engine.pausedUntil = date }
        }

        // Carbon hotkeys via KeyboardShortcuts — independent of our
        // CGEventTap, so they still fire when Mojito is paused or Input
        // Monitoring is revoked.
        KeyboardShortcuts.onKeyDown(for: .pauseHour) { [weak self] in
            self?.toggleOrPause(until: Date().addingTimeInterval(3600))
        }
        KeyboardShortcuts.onKeyDown(for: .pauseUntilTomorrow) { [weak self] in
            self?.toggleOrPause(until: Self.tomorrowMorning())
        }
        KeyboardShortcuts.onKeyDown(for: .showEmojiBrowser) { [weak self] in
            self?.engine.toggleBrowser()
        }
        // Re-assert the runtime-only system-panel suppression (the ⌃⌘Space
        // binding and Fn pref persist on their own).
        SystemEmojiPickerReplacer.shared.applyAtLaunch()

        // Force onboarding any time permissions aren't granted — revoked
        // perms / fresh accounts get the guided fix, not a silent break.
        let needsOnboarding = !UserDefaults.standard.bool(forKey: PrefsKey.onboardingComplete)
            || !permissions.allGranted
        if needsOnboarding {
            if !TouchBarBridge.backgroundLaunch { openOnboarding() }
        } else {
            engine.start()
            TelemetryConsent.presentIfNeeded()
        }

        touchBarBridge = TouchBarBridge(engine: engine, permissions: permissions)

        NotificationCenter.default.publisher(for: .mojitoShouldShowOnboarding)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.openOnboarding() }
            .store(in: &observers)

        NotificationCenter.default.publisher(for: .mojitoOnboardingFinished)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in
                self?.onboardingController.close()
                self?.engine.start()
                // Drop the onboarding fast-poll back to the baseline cadence.
                self?.permissions.startMonitoring()
                // First run reaches "running" here — surface the stats consent.
                TelemetryConsent.presentIfNeeded()
            }
            .store(in: &observers)

        NotificationCenter.default.publisher(for: .mojitoShouldOpenSettings)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.openSettings() }
            .store(in: &observers)

        NotificationCenter.default.publisher(for: .mojitoShouldOpenBrowser)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.engine.showBrowser() }
            .store(in: &observers)

        // Onboarding's Done step asks the engine to go live early so its
        // "try it out" field expands shortcuts. Idempotent — start() reconciles.
        NotificationCenter.default.publisher(for: .mojitoShouldStartEngine)
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.engine.start() }
            .store(in: &observers)

        // Discovery banner click: open Settings, then ask the navigator to
        // reveal the egg. Order matters — open first so a fresh window's
        // views mount and pick up the (already-set) reveal request on appear.
        NotificationCenter.default.publisher(for: .mojitoRevealEasterEgg)
            .receive(on: RunLoop.main)
            .sink { [weak self] note in
                self?.openSettings()
                if let id = note.object as? String {
                    SettingsNavigator.shared.revealEgg(id)
                }
            }
            .store(in: &observers)
    }

    func applicationWillTerminate(_ notification: Notification) {
        SpeechController.shared.cancel()
        LocalTelemetry.shared.flush()
        os_log("applicationWillTerminate", log: log, type: .info)
        // Best-effort send of this session's tail. The async POST may not
        // finish before the process exits, but the timer/day-change/wake
        // paths below are what actually keeps long-lived installs current.
        TelemetryUploader.shared.uploadIfDue()
    }

    /// `uploadIfDue()` used to fire only at launch, so a menu-bar app the user
    /// never quits would sit on a full day of pending deltas until its next
    /// relaunch — starving the public stats. Re-attempt on an hourly timer, at
    /// day rollover, and on wake. The uploader's once-per-UTC-day gate makes
    /// every extra call a cheap no-op, so this only ever sends real work once.
    private func scheduleTelemetryFlush() {
        Timer.publish(every: 3600, on: .main, in: .common)
            .autoconnect()
            .sink { _ in TelemetryUploader.shared.uploadIfDue() }
            .store(in: &observers)

        NotificationCenter.default.publisher(for: .NSCalendarDayChanged)
            .receive(on: RunLoop.main)
            .sink { _ in TelemetryUploader.shared.uploadIfDue() }
            .store(in: &observers)

        NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.didWakeNotification)
            .receive(on: RunLoop.main)
            .sink { _ in TelemetryUploader.shared.uploadIfDue() }
            .store(in: &observers)
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    /// Without this an `LSUIElement` app silently no-ops on relaunch from
    /// Finder/Dock/Spotlight, which feels broken. Show Settings (or
    /// onboarding if incomplete) so the click does something visible.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        let onboardingComplete = UserDefaults.standard.bool(forKey: PrefsKey.onboardingComplete)
        if onboardingComplete && permissions.allGranted {
            openSettings()
        } else {
            openOnboarding()
        }
        return false
    }

    func openOnboarding() {
        onboardingController.show(permissions: permissions)
    }

    func openSettings() {
        settingsController.show(permissions: permissions, exclusions: exclusions, engine: engine)
    }

    /// Bypasses LaunchServices' icon cache (lags behind bundle changes,
    /// most visible in the dev build's `AppIconDev` swap).
    private func applyAppIcon() {
        if let icon = AppInfo.appIcon {
            NSApp.applicationIconImage = icon
        }
    }

    private func toggleOrPause(until date: Date) {
        if let until = engine.pausedUntil, until > Date() {
            engine.resume()
        } else {
            engine.pause(until: date)
        }
    }

    private static func tomorrowMorning() -> Date {
        var components = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        components.day = (components.day ?? 0) + 1
        components.hour = 7
        return Calendar.current.date(from: components) ?? Date().addingTimeInterval(8 * 3600)
    }

    /// `LSUIElement: true` apps don't get a default menu, so ⌘Q etc.
    /// won't fire from focused windows (onboarding, settings). Install a
    /// minimal one; the bar itself stays hidden via LSUIElement.
    private func installMainMenu() {
        let mainMenu = NSMenu()

        let appMenuItem = NSMenuItem()
        let appMenu = NSMenu()
        let appName = AppInfo.displayName
        appMenu.addItem(withTitle: "About \(appName)", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Hide \(appName)", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
        let hideOthers = appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        hideOthers.keyEquivalentModifierMask = [.command, .option]
        appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit \(appName)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appMenuItem.submenu = appMenu
        mainMenu.addItem(appMenuItem)

        // Without these wired through, text fields don't get
        // standard copy/paste/select-all.
        let editMenuItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut",     action: #selector(NSText.cut(_:)),       keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy",    action: #selector(NSText.copy(_:)),      keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste",   action: #selector(NSText.paste(_:)),     keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editMenuItem.submenu = editMenu
        mainMenu.addItem(editMenuItem)

        let windowMenuItem = NSMenuItem()
        let windowMenu = NSMenu(title: "Window")
        windowMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
        windowMenuItem.submenu = windowMenu
        mainMenu.addItem(windowMenuItem)
        NSApp.windowsMenu = windowMenu

        NSApp.mainMenu = mainMenu
    }
}

import AppKit
import ApplicationServices
import Combine

/// Local metadata only. Never serializes focused text, selection contents or clipboard.
@MainActor
final class TouchBarBridge {
    static let requestName = Notification.Name("io.github.todd866.Spritz.touchbar.request")
    static let stateName = Notification.Name("io.github.todd866.Spritz.touchbar.state")
    static let contextName = Notification.Name("io.github.todd866.Spritz.focus-metadata-changed")
    static var userObject: String { "uid:\(getuid())" }
    static var stateURL: URL { FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/spritz/touchbar-state.json") }
    static let backgroundLaunch = CommandLine.arguments.contains("--bridge-background")
    let instanceID = UUID().uuidString
    private let engine: Engine
    private let permissions: PermissionsCoordinator
    private var observers: [NSObjectProtocol] = []
    private var subscriptions = Set<AnyCancellable>()
    private var heartbeat: Timer?
    private var pendingID: String?
    private var handledIDs: [String] = []
    private var lastResult: [String: Any] = [:]
    private var loginReceipt: [String: Any] = [:]

    init(engine: Engine, permissions: PermissionsCoordinator) {
        self.engine = engine; self.permissions = permissions
        observers.append(DistributedNotificationCenter.default().addObserver(forName: Self.requestName, object: Self.userObject, queue: .main) { [weak self] note in
            MainActor.assumeIsolated { self?.receive(note.userInfo ?? [:]) }
        })
        observers.append(NotificationCenter.default.addObserver(forName: Self.contextName, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        })
        permissions.$accessibility.combineLatest(permissions.$inputMonitoring).sink { [weak self] _, _ in
            DispatchQueue.main.async { self?.publish() }
        }.store(in: &subscriptions)
        heartbeat = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.publish() }
        }
        publish()
        if let i = CommandLine.arguments.firstIndex(of: "--bridge-initial-request"), CommandLine.arguments.indices.contains(i + 1),
           let data = Data(base64Encoded: CommandLine.arguments[i + 1]),
           let request = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            // Cache seeds asynchronously. A bounded cold request never opens onboarding.
            attemptCold(request, deadline: ProcessInfo.processInfo.systemUptime + 2)
        }
    }

    private func attemptCold(_ request: [AnyHashable: Any], deadline: TimeInterval) {
        if request["command"] as? String == "enable-login" { receive(request); return }
        if !permissions.allGranted { finish(request["requestID"] as? String ?? "", status: "permissions-missing"); return }
        if !FocusedElementCache.shared.haveFieldInfo && ProcessInfo.processInfo.systemUptime < deadline {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in self?.attemptCold(request, deadline: deadline) }
            return
        }
        receive(request)
    }

    func publish() {
        let cache = FocusedElementCache.shared
        let front = NSWorkspace.shared.frontmostApplication
        let matches = front?.processIdentifier == cache.focusedPID
        let known = permissions.allGranted && matches && cache.haveFieldInfo
        let supportedTextRole = TouchBarRequestPolicy.isTextRole(cache.focusedRole)
        var value: [String: Any] = ["schema": 1, "t": Date().timeIntervalSince1970,
            "pid": ProcessInfo.processInfo.processIdentifier, "instanceID": instanceID,
            "frontPID": front?.processIdentifier ?? 0, "frontBundle": front?.bundleIdentifier ?? "",
            "focusGeneration": cache.bridgeFocusGeneration,
            "accessibility": permissions.accessibility, "inputMonitoring": permissions.inputMonitoring,
            "known": known, "editable": known && supportedTextRole && cache.focusedIsEditable,
            "secure": !known || cache.focusedIsSecure,
            "selectionKnown": false, "hasSelection": false,
            "pickerVisible": engine.bridgePickerVisible, "active": engine.isActive,
            "quickEmoji": engine.bridgeQuickChoices]
        value["loginStatus"] = LaunchAtLogin.statusCode
        if !loginReceipt.isEmpty { value["login"] = loginReceipt }
        if !lastResult.isEmpty { value["lastRequest"] = lastResult }
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return }
        try? FileManager.default.createDirectory(at: Self.stateURL.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try? data.write(to: Self.stateURL, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: Self.stateURL.path)
        DistributedNotificationCenter.default().postNotificationName(Self.stateName, object: Self.userObject, userInfo: value, deliverImmediately: true)
    }

    private func finish(_ id: String, status: String, latency: Double? = nil) {
        if pendingID == id { pendingID = nil }
        lastResult = ["requestID": id, "status": status, "t": Date().timeIntervalSince1970]
        if let latency { lastResult["requestToVisibleMs"] = latency }
        if !id.isEmpty { handledIDs.append(id); if handledIDs.count > 64 { handledIDs.removeFirst() } }
        publish()
    }

    private func receive(_ request: [AnyHashable: Any]) {
        guard let command = request["command"] as? String, ["show-picker", "pick-emoji", "enable-login"].contains(command), let id = request["requestID"] as? String, !id.isEmpty else { return }
        guard let issuedAt = request["issuedAt"] as? NSNumber,
              TouchBarRequestPolicy.validAge(issuedAt: issuedAt.doubleValue, now: Date().timeIntervalSince1970) else { finish(id, status: "request-expired"); return }
        guard !handledIDs.contains(id), pendingID != id else { return }
        if command == "enable-login" {
            let result = LaunchAtLogin.enableIfNeeded()
            loginReceipt = ["status": result.status, "error": result.error, "t": Date().timeIntervalSince1970,
                            "requestID": id, "process": "running GUI app"]
            finish(id, status: result.status == 1 ? "login-enabled" : (result.status == 2 ? "login-requires-approval" : "login-not-enabled"))
            return
        }
        guard pendingID == nil else { finish(id, status: "busy"); return }
        guard let expectedPID = request["expectedPID"] as? NSNumber,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == expectedPID.int32Value else { finish(id, status: "focus-changed"); return }
        let cache = FocusedElementCache.shared
        if let generation = request["focusGeneration"] as? NSNumber, generation.intValue != cache.bridgeFocusGeneration { finish(id, status: "stale-focus"); return }
        if let instance = request["instanceID"] as? String, instance != instanceID { finish(id, status: "stale-instance"); return }
        guard permissions.allGranted else { finish(id, status: "permissions-missing"); return }
        guard engine.isActive, cache.haveFieldInfo, TouchBarRequestPolicy.isTextRole(cache.focusedRole), cache.focusedIsEditable, !cache.focusedIsSecure,
              cache.focusedPID == expectedPID.int32Value, let cached = cache.element else { finish(id, status: "not-editable"); return }
        // One bounded tap-time AX read validates the actual focused target; no text is read.
        let app = AXUIElementCreateApplication(expectedPID.int32Value)
        AXUIElementSetMessagingTimeout(app, 0.005)
        var actual: CFTypeRef?
        guard AXUIElementCopyAttributeValue(app, kAXFocusedUIElementAttribute as CFString, &actual) == .success,
              let actual, CFGetTypeID(actual) == AXUIElementGetTypeID(), CFEqual(actual, cached) else { finish(id, status: "focus-unverified"); return }
        if command == "pick-emoji" {
            guard let hex = request["hex"] as? String, engine.bridgeQuickChoices.contains(where: { $0["hex"] == hex }) else { finish(id, status: "unknown-emoji"); return }
            let inserted = engine.pickEmojiForBridge(hex: hex, expectedPID: expectedPID.int32Value, element: cached)
            finish(id, status: inserted ? "insertion-requested" : "focus-changed"); return
        }
        guard !engine.bridgePickerVisible else { finish(id, status: "already-visible"); return }
        pendingID = id
        let started = ProcessInfo.processInfo.systemUptime
        DispatchQueue.main.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.pendingID == id else { return }
            self.engine.cancelBridgeOpen()
            self.finish(id, status: "request-expired")
        }
        engine.showBrowserForBridge(expectedPID: expectedPID.int32Value, element: cached) { [weak self] shown in
            guard let self, self.pendingID == id else { return }
            self.finish(id, status: shown ? "visible" : "focus-changed", latency: shown ? (ProcessInfo.processInfo.systemUptime - started) * 1000 : nil)
        }
    }
}

/// Returns true after handling a bridge-only CLI request. Does not start event taps.
@MainActor
func handleTouchBarCLI() -> Bool {
    let args = CommandLine.arguments
    if args.contains("--bridge-status") {
        if let data = try? Data(contentsOf: TouchBarBridge.stateURL), let text = String(data: data, encoding: .utf8) { print(text) }
        else { print("{\"schema\":1,\"status\":\"not-running-or-no-state\"}") }
        return true
    }
    let enableLogin = args.contains("--enable-login")
    guard args.contains("--show-picker") || enableLogin else { return false }
    guard !(args.contains("--show-picker") && enableLogin) else { print("Choose one bridge command"); return true }
    func argument(_ name: String) -> String? { guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }; return args[i + 1] }
    var request: [String: Any] = ["command": enableLogin ? "enable-login" : "show-picker", "issuedAt": Date().timeIntervalSince1970, "requestID": argument("--request-id") ?? UUID().uuidString,
        "expectedPID": Int(argument("--expected-pid") ?? "") ?? Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0)]
    if let generation = argument("--focus-generation").flatMap(Int.init) { request["focusGeneration"] = generation }
    if let instance = argument("--instance-id") { request["instanceID"] = instance }
    let peers = NSWorkspace.shared.runningApplications.filter { $0.bundleIdentifier == Bundle.main.bundleIdentifier && $0.processIdentifier != ProcessInfo.processInfo.processIdentifier }
    if !peers.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(TouchBarBridge.requestName, object: TouchBarBridge.userObject, userInfo: request, deliverImmediately: true)
        print("Bridge request sent; inspect bridge state for actual result")
    } else if let data = try? JSONSerialization.data(withJSONObject: request) {
        let configuration = NSWorkspace.OpenConfiguration()
        configuration.activates = false
        configuration.arguments = ["--bridge-background", "--bridge-initial-request", data.base64EncodedString()]
        var complete = false
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: configuration) { _, error in
            if let error { fputs("Background launch failed: \(error.localizedDescription)\n", stderr) }
            complete = true
        }
        let deadline = Date().addingTimeInterval(3)
        while !complete && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        print(complete ? "Background bridge request dispatched; inspect bridge state" : "Background launch outcome pending")
    }
    return true
}

// Kept pure so delayed, replayed and future-dated requests have deterministic tests.
enum TouchBarRequestPolicy {
    static func isTextRole(_ role: String?) -> Bool {
        guard let role else { return false }
        return ["AXTextField", "AXTextArea", "AXComboBox", "AXSearchField"].contains(role)
    }
    static func validAge(issuedAt: Double, now: Double) -> Bool {
        let age = now - issuedAt
        return issuedAt.isFinite && now.isFinite && age >= -0.25 && age <= 2
    }
}
