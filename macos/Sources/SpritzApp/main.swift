import AppKit
import Combine
import CSpritzFFI
import Foundation
import SwiftUI

// MARK: - CLI & Single Instance

@MainActor
private func handleEarlyCLI(args: [String]) -> Int32? {
    if args.contains("--telemetry") {
        if let ptr = spritz_cli_telemetry_report() {
            defer { spritz_free_cstr(ptr) }
            print(String(cString: ptr), terminator: "")
        }
        return 0
    }

    if args.contains("--bridge-status") {
        if let data = try? Data(contentsOf: TouchBarConstants.stateURL),
           let text = String(data: data, encoding: .utf8) {
            print(text)
        } else {
            print(#"{"schema":1,"status":"not-running-or-no-state"}"#)
        }
        return 0
    }

    if let idx = args.firstIndex(of: "--render-preview"), args.indices.contains(idx + 1) {
        let outDir = URL(fileURLWithPath: args[idx + 1], isDirectory: true)
        renderHeadlessPreviews(to: outDir)
        return 0
    }

    let enableLogin = args.contains("--enable-login")
    let showPicker = args.contains("--show-picker")
    guard enableLogin || showPicker else { return nil }
    if enableLogin && showPicker {
        print("Choose one bridge command")
        return 1
    }

    func arg(_ name: String) -> String? {
        guard let i = args.firstIndex(of: name), args.indices.contains(i + 1) else { return nil }
        return args[i + 1]
    }

    var req: [String: Any] = [
        "command": enableLogin ? "enable-login" : "show-picker",
        "issuedAt": Date().timeIntervalSince1970,
        "requestID": arg("--request-id") ?? UUID().uuidString,
        "expectedPID": Int(arg("--expected-pid") ?? "") ?? Int(NSWorkspace.shared.frontmostApplication?.processIdentifier ?? 0),
    ]
    if let gen = arg("--focus-generation").flatMap(Int.init) { req["focusGeneration"] = gen }
    if let inst = arg("--instance-id") { req["instanceID"] = inst }

    let myPID = ProcessInfo.processInfo.processIdentifier
    let peers = NSWorkspace.shared.runningApplications.filter {
        $0.bundleIdentifier == TouchBarConstants.bundleID && $0.processIdentifier != myPID
    }
    if !peers.isEmpty {
        DistributedNotificationCenter.default().postNotificationName(
            TouchBarConstants.requestName,
            object: TouchBarConstants.userObject,
            userInfo: req,
            deliverImmediately: true
        )
        print("Bridge request sent; inspect bridge state for actual result")
    } else if let data = try? JSONSerialization.data(withJSONObject: req) {
        let config = NSWorkspace.OpenConfiguration()
        config.activates = false
        config.arguments = ["--bridge-background", "--bridge-initial-request", data.base64EncodedString()]
        let sem = DispatchSemaphore(value: 0)
        NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: config) { _, error in
            if let error { fputs("Background launch failed: \(error.localizedDescription)\n", stderr) }
            sem.signal()
        }
        let result = sem.wait(timeout: .now() + 3)
        print(result == .success ? "Background bridge request dispatched; inspect bridge state" : "Background launch outcome pending")
    }
    return 0
}

@MainActor
private func renderHeadlessPreviews(to outDir: URL) {
    _ = NSApplication.shared
    try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

    func renderView<V: View>(_ view: V, size: CGSize, dark: Bool, to url: URL) {
        let appearance = NSAppearance(named: dark ? .darkAqua : .aqua)!
        let hosting = NSHostingView(rootView: view.environment(\.colorScheme, dark ? .dark : .light))
        hosting.frame = NSRect(origin: .zero, size: size)
        hosting.appearance = appearance

        let container = NSView(frame: NSRect(origin: .zero, size: size))
        container.wantsLayer = true
        container.appearance = appearance
        container.layer?.backgroundColor = (dark ? NSColor(white: 0.14, alpha: 1) : NSColor(white: 0.96, alpha: 1)).cgColor
        container.layer?.cornerRadius = 18
        container.layer?.masksToBounds = true
        container.addSubview(hosting)
        container.layoutSubtreeIfNeeded()

        guard let rep = container.bitmapImageRepForCachingDisplay(in: container.bounds) else { return }
        container.cacheDisplay(in: container.bounds, to: rep)
        guard let png = rep.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url, options: .atomic)
    }

    let idleSnap = SpritzBridge.previewSnapshot(withAlternatives: false)
    let idleBridge = SpritzBridge(previewSnapshot: idleSnap)
    let idleSize = CGSize(width: PickerLayout.browserWidth, height: PickerLayout.browserHeight + CGFloat(idleSnap.dictation.stripHeight))
    renderView(PickerRootView(bridge: idleBridge, editableSearch: false), size: idleSize, dark: false, to: outDir.appendingPathComponent("picker-light.png"))
    renderView(PickerRootView(bridge: idleBridge, editableSearch: false), size: idleSize, dark: true, to: outDir.appendingPathComponent("picker-dark.png"))

    let altSnap = SpritzBridge.previewSnapshot(withAlternatives: true)
    let altBridge = SpritzBridge(previewSnapshot: altSnap)
    let altSize = CGSize(width: PickerLayout.browserWidth, height: PickerLayout.browserHeight + CGFloat(altSnap.dictation.stripHeight))
    renderView(PickerRootView(bridge: altBridge, editableSearch: false), size: altSize, dark: false, to: outDir.appendingPathComponent("picker-alternatives-light.png"))
    renderView(PickerRootView(bridge: altBridge, editableSearch: false), size: altSize, dark: true, to: outDir.appendingPathComponent("picker-alternatives-dark.png"))

    let settingsHostLight = NSHostingView(rootView: SettingsView(bridge: altBridge))
    let settingsSize = settingsHostLight.fittingSize
    renderView(SettingsView(bridge: altBridge), size: settingsSize, dark: false, to: outDir.appendingPathComponent("settings-light.png"))
    renderView(SettingsView(bridge: altBridge), size: settingsSize, dark: true, to: outDir.appendingPathComponent("settings-dark.png"))
}

@MainActor
private enum InstanceLock {
    private static var fd: Int32 = -1
    static func acquire() -> Bool {
        let dir = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/state/spritz", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent("instance.lock").path
        fd = open(path, O_CREAT | O_RDWR, 0o600)
        guard fd >= 0 else { return true }
        return flock(fd, LOCK_EX | LOCK_NB) == 0
    }
}

@MainActor
final class SpritzAppDelegate: NSObject, NSApplicationDelegate {
    private let bridge = SpritzBridge()
    private var pickerController: PickerPanelController?
    private var menuBar: MenuBarController?
    private let settingsController = SettingsWindowController()
    private var cancellables = Set<AnyCancellable>()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        installMainMenu()
        if let iconURL = Bundle.main.url(forResource: "AppIcon", withExtension: "icns"),
           let icon = NSImage(contentsOf: iconURL) {
            NSApp.applicationIconImage = icon
        }

        pickerController = PickerPanelController(bridge: bridge)
        let menu = MenuBarController(bridge: bridge) { [weak self] in
            guard let self else { return }
            self.settingsController.show(bridge: self.bridge)
        }
        menuBar = menu

        bridge.onOpenSettingsRequested = { [weak self] in
            guard let self else { return }
            self.settingsController.show(bridge: self.bridge)
        }

        bridge.$snapshot
            .receive(on: RunLoop.main)
            .sink { [weak menu, weak self] snap in
                _ = self
                menu?.applySnapshot(snap)
            }
            .store(in: &cancellables)

        bridge.startLiveEngine()
        if bridge.snapshot.showMenuBarIcon {
            menu.install()
        }

        let args = CommandLine.arguments
        if let idx = args.firstIndex(of: "--bridge-initial-request"), args.indices.contains(idx + 1),
           let data = Data(base64Encoded: args[idx + 1]),
           let req = try? JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any] {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
                self?.bridge.handleTouchBarDictionary(req)
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        bridge.shutdown()
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        false
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        guard !flag else { return true }
        settingsController.show(bridge: bridge)
        return false
    }

    private func installMainMenu() {
        let mainMenu = NSMenu()
        let appItem = NSMenuItem()
        let appMenu = NSMenu()
        appMenu.addItem(withTitle: "About Spritz", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
        appMenu.addItem(.separator())
        appMenu.addItem(withTitle: "Quit Spritz", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        appItem.submenu = appMenu
        mainMenu.addItem(appItem)

        let editItem = NSMenuItem()
        let editMenu = NSMenu(title: "Edit")
        editMenu.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        editMenu.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        editMenu.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        editMenu.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a")
        editItem.submenu = editMenu
        mainMenu.addItem(editItem)

        let winItem = NSMenuItem()
        let winMenu = NSMenu(title: "Window")
        winMenu.addItem(withTitle: "Close Window", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")
        winItem.submenu = winMenu
        mainMenu.addItem(winItem)
        NSApp.windowsMenu = winMenu
        NSApp.mainMenu = mainMenu
    }
}

// Entrypoint
let args = CommandLine.arguments
if let exitCode = MainActor.assumeIsolated({ handleEarlyCLI(args: args) }) {
    exit(exitCode)
}
if !MainActor.assumeIsolated({ InstanceLock.acquire() }) {
    exit(0)
}
let app = NSApplication.shared
let delegate = MainActor.assumeIsolated { SpritzAppDelegate() }
app.delegate = delegate
app.run()
