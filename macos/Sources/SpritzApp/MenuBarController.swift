import AppKit
import Carbon.HIToolbox
import Foundation

@MainActor
final class MenuBarController: NSObject, NSMenuDelegate {
    private let bridge: SpritzBridge
    private let openSettings: () -> Void
    private var statusItem: NSStatusItem?

    private weak var statusLineItem: NSMenuItem?
    private weak var secureInputItem: NSMenuItem?
    private weak var pauseHourItem: NSMenuItem?
    private weak var pauseTomorrowItem: NSMenuItem?
    private weak var resumeItem: NSMenuItem?
    private weak var browseItem: NSMenuItem?
    private weak var loginItem: NSMenuItem?
    private var skinToneItems: [String: NSMenuItem] = [:]

    private static let skinToneChoices: [(id: String, title: String)] = [
        ("default", "Default 🖖"),
        ("light", "Light 🖖🏻"),
        ("mediumLight", "Medium-light 🖖🏼"),
        ("medium", "Medium 🖖🏽"),
        ("mediumDark", "Medium-dark 🖖🏾"),
        ("dark", "Dark 🖖🏿"),
    ]

    init(bridge: SpritzBridge, openSettings: @escaping () -> Void) {
        self.bridge = bridge
        self.openSettings = openSettings
        super.init()
    }

    func install() {
        guard statusItem == nil else { return }
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        item.menu = buildMenu()
        statusItem = item
        applySnapshot(bridge.snapshot)
    }

    func applySnapshot(_ s: SpritzSnapshot) {
        guard let button = statusItem?.button else { return }
        if !s.allPermissionsGranted {
            if let img = NSImage(systemSymbolName: "exclamationmark.triangle.fill", accessibilityDescription: "Spritz needs permission") {
                img.isTemplate = false
                button.image = img
                button.title = ""
            } else {
                button.image = nil
                button.title = "⚠️"
            }
        } else if let url = Bundle.main.url(forResource: "MenuBarIcon", withExtension: "pdf"),
                  let img = NSImage(contentsOf: url) {
            img.size = NSSize(width: 16, height: 16)
            img.isTemplate = true
            button.appearsDisabled = !s.active
            button.image = img
            button.title = ""
        } else if let img = NSImage(systemSymbolName: "face.smiling", accessibilityDescription: "Spritz") {
            img.size = NSSize(width: 16, height: 16)
            img.isTemplate = true
            button.appearsDisabled = !s.active
            button.image = img
            button.title = ""
        } else {
            button.image = nil
            button.title = "🍹"
        }
        button.toolTip = "Fn: tap emoji · hold dictation"
        refreshMenu(using: s)
    }

    private func buildMenu() -> NSMenu {
        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false

        let status = NSMenuItem(title: "Spritz is running", action: nil, keyEquivalent: "")
        status.isEnabled = false
        menu.addItem(status)
        statusLineItem = status

        let sec = NSMenuItem(title: "", action: nil, keyEquivalent: "")
        sec.isEnabled = false
        sec.isHidden = true
        menu.addItem(sec)
        secureInputItem = sec

        menu.addItem(.separator())

        let pHour = NSMenuItem(title: "Pause for 1 hour", action: #selector(pauseHour), keyEquivalent: "")
        pHour.target = self
        menu.addItem(pHour)
        pauseHourItem = pHour

        let pTom = NSMenuItem(title: "Pause until tomorrow", action: #selector(pauseTomorrow), keyEquivalent: "")
        pTom.target = self
        menu.addItem(pTom)
        pauseTomorrowItem = pTom

        let res = NSMenuItem(title: "Resume", action: #selector(resumeEngine), keyEquivalent: "")
        res.target = self
        menu.addItem(res)
        resumeItem = res

        menu.addItem(.separator())

        let browse = NSMenuItem(title: "Browse Emoji…", action: #selector(browseEmoji), keyEquivalent: " ")
        browse.keyEquivalentModifierMask = [.command, .control]
        browse.target = self
        menu.addItem(browse)
        browseItem = browse

        let toneMenuItem = NSMenuItem(title: "Skin Tone", action: nil, keyEquivalent: "")
        let toneSubmenu = NSMenu()
        for opt in Self.skinToneChoices {
            let item = NSMenuItem(title: opt.title, action: #selector(selectSkinTone(_:)), keyEquivalent: "")
            item.representedObject = opt.id
            item.target = self
            toneSubmenu.addItem(item)
            skinToneItems[opt.id] = item
        }
        toneMenuItem.submenu = toneSubmenu
        menu.addItem(toneMenuItem)

        let login = NSMenuItem(title: "Launch at Login", action: #selector(toggleLaunchAtLogin), keyEquivalent: "")
        login.target = self
        menu.addItem(login)
        loginItem = login

        let tel = NSMenuItem(title: "Copy local telemetry", action: #selector(copyTelemetry), keyEquivalent: "")
        tel.target = self
        menu.addItem(tel)

        menu.addItem(.separator())

        let cfg = NSMenuItem(title: "Open Config…", action: #selector(openConfig), keyEquivalent: "")
        cfg.target = self
        menu.addItem(cfg)

        let prefs = NSMenuItem(title: "Settings…", action: #selector(openPrefs), keyEquivalent: ",")
        prefs.target = self
        menu.addItem(prefs)

        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Spritz", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        return menu
    }

    func menuWillOpen(_ menu: NSMenu) {
        refreshMenu(using: bridge.snapshot)
    }

    private func refreshMenu(using s: SpritzSnapshot) {
        let statusText: String
        if !s.allPermissionsGranted {
            statusText = "Spritz needs permission"
        } else if s.isPaused {
            statusText = "Spritz is paused"
        } else if s.active {
            statusText = "Spritz is running"
        } else {
            statusText = "Spritz is off"
        }
        statusLineItem?.attributedTitle = NSAttributedString(
            string: statusText,
            attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.secondaryLabelColor]
        )

        if let secItem = secureInputItem {
            if s.secureInput {
                let holder: String? = s.secureInputPid > 0
                    ? (NSRunningApplication(processIdentifier: s.secureInputPid)?.localizedName ?? "PID \(s.secureInputPid)")
                    : nil
                let label = holder.map { "Secure Input held by \($0) · Fn uses fallback" }
                    ?? "Secure Input active · Fn uses fallback"
                secItem.attributedTitle = NSAttributedString(
                    string: label,
                    attributes: [.font: NSFont.menuFont(ofSize: 0), .foregroundColor: NSColor.systemOrange]
                )
                secItem.image = NSImage(systemSymbolName: "lock.fill", accessibilityDescription: "Secure Input active")
                secItem.isHidden = false
            } else {
                secItem.isHidden = true
            }
        }

        let paused = s.isPaused
        pauseHourItem?.isHidden = paused
        pauseTomorrowItem?.isHidden = paused
        resumeItem?.isHidden = !paused
        browseItem?.isEnabled = s.active
        loginItem?.state = s.launchAtLogin ? .on : .off

        for (id, item) in skinToneItems {
            item.state = (s.skinTone == id) ? .on : .off
        }
    }

    @objc private func pauseHour() { bridge.pauseForOneHour() }
    @objc private func pauseTomorrow() { bridge.pauseUntilTomorrow() }
    @objc private func resumeEngine() { bridge.resume() }
    @objc private func browseEmoji() { bridge.showBrowser() }
    @objc private func selectSkinTone(_ sender: NSMenuItem) {
        if let id = sender.representedObject as? String { bridge.setSkinTone(id) }
    }
    @objc private func toggleLaunchAtLogin() { bridge.setLaunchAtLogin(!bridge.snapshot.launchAtLogin) }
    @objc private func copyTelemetry() { bridge.copyToPasteboard(bridge.telemetryReport()) }
    @objc private func openConfig() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: bridge.snapshot.configPath)])
    }
    @objc private func openPrefs() { openSettings() }
}
