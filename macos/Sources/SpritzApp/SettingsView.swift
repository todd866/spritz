import AppKit
import SwiftUI

struct SettingsView: View {
    @ObservedObject var bridge: SpritzBridge
    @Environment(\.openURL) private var openURL

    private static let toneOptions: [(id: String, name: String, glyph: String)] = [
        ("default", "Default", "🖖"),
        ("light", "Light", "🖖🏻"),
        ("mediumLight", "Medium-light", "🖖🏼"),
        ("medium", "Medium", "🖖🏽"),
        ("mediumDark", "Medium-dark", "🖖🏾"),
        ("dark", "Dark", "🖖🏿"),
    ]

    var body: some View {
        let s = bridge.snapshot
        VStack(alignment: .leading, spacing: 10) {
            // Permissions
            instrumentPermissionRow(
                symbol: "accessibility",
                label: "Accessibility",
                granted: s.accessibility,
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility"
            )
            instrumentPermissionRow(
                symbol: "keyboard",
                label: "Input Monitoring",
                granted: s.inputMonitoring,
                url: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent"
            )

            Divider()

            // Triggers & Startup
            HStack(spacing: 8) {
                iconBox("globe")
                Text("Globe / Fn tap")
                Spacer()
                if s.needsLogoutForGlobe {
                    Text("Log out to apply")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Toggle("", isOn: Binding(
                    get: { s.globeEnabled },
                    set: { bridge.setGlobeEnabled($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                iconBox("command")
                Text("Replace ⌃⌘Space")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { s.replaceSystemPicker },
                    set: { bridge.setReplaceSystemPicker($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            HStack(spacing: 8) {
                iconBox("power")
                Text("Launch at login")
                Spacer()
                Toggle("", isOn: Binding(
                    get: { s.launchAtLogin },
                    set: { bridge.setLaunchAtLogin($0) }
                ))
                .labelsHidden()
                .toggleStyle(.switch)
                .controlSize(.small)
            }

            Divider()

            // Skin tone
            HStack(spacing: 8) {
                iconBox("hand.raised")
                Text("Skin tone")
                Spacer()
                HStack(spacing: 4) {
                    ForEach(Self.toneOptions, id: \.id) { opt in
                        let active = s.skinTone == opt.id
                        Button {
                            bridge.setSkinTone(opt.id)
                        } label: {
                            Text(opt.glyph)
                                .font(.system(size: 16))
                                .frame(width: 26, height: 26)
                                .background(
                                    Circle()
                                        .fill(active ? Color.accentColor.opacity(0.22) : Color.primary.opacity(0.05))
                                )
                                .overlay(
                                    Circle()
                                        .strokeBorder(active ? Color.accentColor : Color.clear, lineWidth: 1.5)
                                )
                        }
                        .buttonStyle(.plain)
                        .help(opt.name)
                        .accessibilityLabel("\(opt.name) skin tone")
                    }
                }
            }

            Divider()

            // Dictation pass-through & review
            HStack(spacing: 8) {
                iconBox("mic")
                Text("Hold Fn")
                Spacer()
                HStack(spacing: 5) {
                    Image(systemName: s.chatgptFnHookActive ? "checkmark.circle.fill" : "circle.dotted")
                        .font(.system(size: 11))
                        .foregroundStyle(s.chatgptFnHookActive ? .green : .secondary)
                    Text(s.chatgptFnHookActive ? "ChatGPT Dictate" : "ChatGPT idle")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
            }

            HStack(spacing: 8) {
                iconBox("text.badge.checkmark")
                Text("Text review")
                Spacer()
                Picker("", selection: Binding(
                    get: { s.refinementProvider },
                    set: { bridge.setRefinementProvider($0) }
                )) {
                    Text("Antigravity").tag("Antigravity")
                    Text("Off").tag("Off")
                }
                .labelsHidden()
                .pickerStyle(.segmented)
                .frame(width: 170)
            }

            Divider()

            // Footer instrument datum + config link
            HStack(spacing: 8) {
                Text("\(s.totalEmojiInserted) inserted")
                    .font(.system(size: 12).monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Open config") {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: s.configPath)])
                }
                .controlSize(.small)
            }
        }
        .font(.system(size: 13))
        .padding(16)
        .frame(width: 420)
    }

    private func iconBox(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13))
            .foregroundStyle(.secondary)
            .frame(width: 18, alignment: .center)
    }

    private func instrumentPermissionRow(symbol: String, label: String, granted: Bool, url: String) -> some View {
        HStack(spacing: 8) {
            iconBox(symbol)
            Text(label)
            Spacer()
            HStack(spacing: 5) {
                Image(systemName: granted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                    .font(.system(size: 12))
                    .foregroundStyle(granted ? .green : .orange)
                Text(granted ? "Granted" : "Missing")
                    .font(.system(size: 12))
                    .foregroundStyle(granted ? Color.secondary : Color.orange)
            }
            if !granted {
                Button("Grant") {
                    if let u = URL(string: url) { openURL(u) }
                }
                .controlSize(.small)
            }
        }
    }
}

@MainActor
final class SettingsWindowController: NSObject, NSWindowDelegate {
    private var window: NSWindow?
    private weak var bridge: SpritzBridge?

    func show(bridge: SpritzBridge) {
        self.bridge = bridge
        let w = window ?? {
            let hosting = NSHostingView(rootView: SettingsView(bridge: bridge))
            let win = NSWindow(contentViewController: NSHostingController(rootView: SettingsView(bridge: bridge)))
            win.title = "Spritz Settings"
            win.styleMask = [.titled, .closable]
            win.isReleasedWhenClosed = false
            win.delegate = self
            win.center()
            _ = hosting
            window = win
            return win
        }()
        w.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        bridge.setUISuspended(true)
    }

    func windowWillClose(_ notification: Notification) {
        bridge?.setUISuspended(false)
    }
}
