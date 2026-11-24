import AppKit
import SwiftUI

enum PickerLayout {
    private static let eightColumnWidth: CGFloat = 352
    static let gridInset: CGFloat = 8
    static let gridSpacing: CGFloat = 3
    static let cellWidth: CGFloat = {
        let inner = eightColumnWidth - gridInset * 2
        return (inner - gridSpacing * 7) / 8
    }()
    static let browserWidth: CGFloat = (gridInset * 2 + cellWidth * 10 + gridSpacing * 9).rounded()
    static let browserHeight: CGFloat = {
        if #available(macOS 26.0, *) { return 420 }
        return 425
    }()
    static let cornerRadius: CGFloat = 20
}

@MainActor
enum PanelPositioner {
    static func screen(for anchor: CGRect) -> NSScreen {
        let center = CGPoint(x: anchor.midX, y: anchor.midY)
        if let hit = NSScreen.screens.first(where: { $0.frame.contains(center) }) { return hit }
        if let hit = NSScreen.screens.first(where: { $0.frame.intersects(anchor) }) { return hit }
        return NSScreen.main ?? NSScreen.screens.first!
    }

    static func frame(anchor: CGRect, size: CGSize) -> CGRect {
        let visible = screen(for: anchor).visibleFrame
        let gap: CGFloat = 6
        let belowY = anchor.minY - size.height - gap
        let aboveY = anchor.maxY + gap
        var origin = CGPoint(x: anchor.minX, y: belowY >= visible.minY ? belowY : aboveY)

        if origin.y + size.height > visible.maxY { origin.y = visible.maxY - size.height - gap }
        if origin.y < visible.minY { origin.y = visible.minY + gap }
        if origin.x + size.width > visible.maxX { origin.x = visible.maxX - size.width - 8 }
        if origin.x < visible.minX { origin.x = visible.minX + 8 }
        return CGRect(origin: origin, size: size)
    }

    static func mouseAnchor() -> CGRect {
        let m = NSEvent.mouseLocation
        return CGRect(x: m.x, y: m.y, width: 1, height: 16)
    }
}

@MainActor
@available(macOS 26.0, *)
enum PopoverGlass {
    private static let lightVeil = NSColor.white.withAlphaComponent(0.25).cgColor

    static func make(contentView: NSView, cornerRadius: CGFloat) -> NSGlassEffectView {
        let veil = NSView()
        veil.wantsLayer = true
        veil.translatesAutoresizingMaskIntoConstraints = false
        contentView.translatesAutoresizingMaskIntoConstraints = false
        veil.addSubview(contentView)
        NSLayoutConstraint.activate([
            contentView.leadingAnchor.constraint(equalTo: veil.leadingAnchor),
            contentView.trailingAnchor.constraint(equalTo: veil.trailingAnchor),
            contentView.topAnchor.constraint(equalTo: veil.topAnchor),
            contentView.bottomAnchor.constraint(equalTo: veil.bottomAnchor),
        ])
        let glass = NSGlassEffectView()
        glass.cornerRadius = cornerRadius
        glass.contentView = veil
        glass.translatesAutoresizingMaskIntoConstraints = false
        return glass
    }

    static func match(_ glass: NSGlassEffectView, to appearance: NSAppearance) {
        let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
        glass.style = isDark ? .regular : .clear
        glass.contentView?.layer?.backgroundColor = isDark ? nil : lightVeil
    }
}

private final class NonActivatingPanel: NSPanel {
    var allowsKeyFocus = false
    override var canBecomeKey: Bool { allowsKeyFocus }
    override var canBecomeMain: Bool { false }
}

@MainActor
final class PickerPanelController {
    private let bridge: SpritzBridge
    private let panel: NonActivatingPanel
    private let chrome: NSView
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    private var localKeyMonitor: Any?
    private var isCapturingLocalKeys = false
    private var anchoredByFallback = false
    private var lastAnchorSeq: UInt64 = 0
    private var lastPlacedFrame: CGRect?

    init(bridge: SpritzBridge) {
        self.bridge = bridge
        let hosting = NSHostingView(rootView: PickerRootView(bridge: bridge))
        hosting.translatesAutoresizingMaskIntoConstraints = false

        self.panel = NonActivatingPanel(
            contentRect: NSRect(x: 0, y: 0, width: PickerLayout.browserWidth, height: PickerLayout.browserHeight + 38),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        panel.isMovableByWindowBackground = true
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]

        self.chrome = Self.makeChrome(hosting: hosting, cornerRadius: PickerLayout.cornerRadius)
        panel.contentView = chrome

        bridge.onStateUpdated = { [weak self] snap in
            self?.sync(with: snap)
        }
        bridge.onCopyToast = { glyph in
            CopyToast.show(glyph)
        }
        bridge.onInsertAfterYield = { [weak self] text, keepOpen in
            self?.insertAfterYield(text: text, keepOpen: keepOpen)
        }
    }

    private static func makeChrome<Content: View>(hosting: NSHostingView<Content>, cornerRadius: CGFloat) -> NSView {
        if #available(macOS 26.0, *) {
            return PopoverGlass.make(contentView: hosting, cornerRadius: cornerRadius)
        } else {
            let effect = NSVisualEffectView()
            effect.material = .menu
            effect.blendingMode = .behindWindow
            effect.state = .active
            effect.wantsLayer = true
            effect.layer?.cornerRadius = cornerRadius
            effect.layer?.masksToBounds = true
            effect.translatesAutoresizingMaskIntoConstraints = false
            effect.addSubview(hosting)
            NSLayoutConstraint.activate([
                hosting.leadingAnchor.constraint(equalTo: effect.leadingAnchor),
                hosting.trailingAnchor.constraint(equalTo: effect.trailingAnchor),
                hosting.topAnchor.constraint(equalTo: effect.topAnchor),
                hosting.bottomAnchor.constraint(equalTo: effect.bottomAnchor),
            ])
            return effect
        }
    }

    private func matchSystemAppearance() {
        let appearance = NSApp.effectiveAppearance
        panel.appearance = appearance
        if #available(macOS 26.0, *), let glass = chrome as? NSGlassEffectView {
            PopoverGlass.match(glass, to: appearance)
        }
    }

    private func sync(with snap: SpritzSnapshot) {
        guard snap.visible else {
            hide()
            return
        }
        let targetSize = CGSize(
            width: PickerLayout.browserWidth,
            height: PickerLayout.browserHeight + CGFloat(snap.dictation.stripHeight)
        )
        matchSystemAppearance()

        if !panel.isVisible {
            let anchor = snap.anchor?.cgRect ?? PanelPositioner.mouseAnchor()
            let frame = PanelPositioner.frame(anchor: anchor, size: targetSize)
            panel.setFrame(frame, display: true)
            panel.orderFrontRegardless()
            anchoredByFallback = snap.anchoredByFallback
            lastAnchorSeq = snap.anchorUpdateSeq
            lastPlacedFrame = frame
            installClickMonitors()
        } else if snap.anchorUpdateSeq != lastAnchorSeq, anchoredByFallback, let caret = snap.anchor?.cgRect {
            lastAnchorSeq = snap.anchorUpdateSeq
            if !userMovedPanel() {
                let frame = PanelPositioner.frame(anchor: caret, size: targetSize)
                panel.setFrame(frame, display: true)
                anchoredByFallback = snap.anchoredByFallback
                lastPlacedFrame = frame
            } else {
                anchoredByFallback = false
            }
        } else {
            let current = panel.frame
            if abs(current.height - targetSize.height) > 0.5 || abs(current.width - targetSize.width) > 0.5 {
                let next = clampToVisible(
                    CGRect(x: current.minX, y: current.maxY - targetSize.height, width: targetSize.width, height: targetSize.height),
                    reference: current
                )
                panel.setFrame(next, display: true)
                lastPlacedFrame = next
            }
        }

        if snap.captureLocalKeys {
            startLocalKeyCapture()
        } else {
            stopLocalKeyCapture()
        }
    }

    private func userMovedPanel() -> Bool {
        guard let lastPlacedFrame else { return false }
        let cur = panel.frame
        return abs(cur.origin.x - lastPlacedFrame.origin.x) > 2 || abs(cur.origin.y - lastPlacedFrame.origin.y) > 2
    }

    private func clampToVisible(_ frame: CGRect, reference: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(reference) } ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width - 8 }
        if f.minX < visible.minX { f.origin.x = visible.minX + 8 }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height - 8 }
        if f.minY < visible.minY { f.origin.y = visible.minY + 8 }
        return f
    }

    private func hide() {
        stopLocalKeyCapture()
        anchoredByFallback = false
        lastPlacedFrame = nil
        if panel.isVisible { panel.orderOut(nil) }
        removeClickMonitors()
    }

    private func insertAfterYield(text: String, keepOpen: Bool) {
        panel.orderOut(nil)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
            self?.bridge.postSyntheticText(text, deleteChars: 0)
            if keepOpen {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.04) { [weak self] in
                    guard let self, self.bridge.snapshot.visible else { return }
                    self.panel.orderFrontRegardless()
                    if self.bridge.snapshot.captureLocalKeys {
                        self.panel.makeKey()
                    }
                }
            }
        }
    }

    private func startLocalKeyCapture() {
        isCapturingLocalKeys = true
        panel.allowsKeyFocus = true
        panel.becomesKeyOnlyIfNeeded = false
        panel.makeKey()
        guard localKeyMonitor == nil else { return }
        localKeyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self, self.isCapturingLocalKeys, event.window === self.panel,
                  let cgEvent = event.cgEvent else { return event }
            return self.bridge.handleLocalCGEvent(cgEvent) ? nil : event
        }
    }

    private func stopLocalKeyCapture() {
        isCapturingLocalKeys = false
        panel.allowsKeyFocus = false
        panel.becomesKeyOnlyIfNeeded = true
        if let localKeyMonitor { NSEvent.removeMonitor(localKeyMonitor) }
        localKeyMonitor = nil
    }

    private func installClickMonitors() {
        guard localClickMonitor == nil else { return }
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel {
                self.bridge.collapseBrowser()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: mask) { [weak self] _ in
            guard let self else { return }
            if self.panel.isVisible && !self.panel.frame.contains(NSEvent.mouseLocation) {
                self.bridge.collapseBrowser()
            }
        }
    }

    private func removeClickMonitors() {
        if let localClickMonitor { NSEvent.removeMonitor(localClickMonitor) }
        if let globalClickMonitor { NSEvent.removeMonitor(globalClickMonitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }
}

@MainActor
enum CopyToast {
    private static var panel: NSPanel?
    private static var work: DispatchWorkItem?

    static func show(_ glyph: String) {
        work?.cancel()
        let label = NSTextField(labelWithString: "Copied \(glyph)")
        label.font = .systemFont(ofSize: 12, weight: .medium)
        label.textColor = .labelColor
        label.sizeToFit()

        let padX: CGFloat = 12
        let padY: CGFloat = 6
        let size = NSSize(width: label.frame.width + padX * 2, height: label.frame.height + padY * 2)

        let p = panel ?? {
            let w = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered,
                defer: false
            )
            w.isFloatingPanel = true
            w.level = .popUpMenu
            w.isOpaque = false
            w.backgroundColor = .clear
            w.ignoresMouseEvents = true
            w.hasShadow = true
            w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            panel = w
            return w
        }()

        let effect = NSVisualEffectView(frame: NSRect(origin: .zero, size: size))
        effect.material = .hudWindow
        effect.state = .active
        effect.wantsLayer = true
        effect.layer?.cornerRadius = size.height / 2
        effect.layer?.masksToBounds = true
        label.frame.origin = CGPoint(x: padX, y: padY)
        effect.addSubview(label)
        p.contentView = effect
        p.appearance = NSApp.effectiveAppearance

        let mouse = NSEvent.mouseLocation
        let origin = CGPoint(x: mouse.x - size.width / 2, y: mouse.y + 16)
        p.setFrame(CGRect(origin: origin, size: size), display: true)
        p.alphaValue = 1
        p.orderFrontRegardless()

        let hideWork = DispatchWorkItem {
            NSAnimationContext.runAnimationGroup({ ctx in
                ctx.duration = 0.25
                p.animator().alphaValue = 0
            }, completionHandler: {
                MainActor.assumeIsolated { p.orderOut(nil) }
            })
        }
        work = hideWork
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.9, execute: hideWork)
    }
}
