import AppKit
import QuartzCore
import SwiftUI

@MainActor
final class PickerWindow {
    /// Engine resets the state machine and hides the picker.
    var onClickAway: (() -> Void)?
    /// The eight context/frequency suggestions shown beside the full browser.
    /// Engine owns the ranking; replacing this array is intentionally cheap and
    /// takes effect on the next expanded open.
    var quickSuggestions: [Emoji] = []
    /// Called by a numbered suggestion cell. Engine handles insertion and
    /// focus-sensitive deletion, so the picker stays presentation-only.
    var onQuickPick: ((Emoji) -> Void)?

    private let panel: NSPanel
    private let hostingView: NSHostingView<PickerView>
    private let viewModel: PickerViewModel
    private let chrome: NSView
    private let stripPanel: NSPanel
    private let stripHostingView: NSHostingView<AnyView>
    private let stripChrome: NSView
    private var localClickMonitor: Any?
    private var globalClickMonitor: Any?
    /// Separate panel for the pill's number-hotkey tooltip — the pill panel
    /// is too short to host a label above its cells without clipping.
    private var tooltipPanel: NSPanel?
    private var pillTooltipWork: DispatchWorkItem?

    init(viewModel: PickerViewModel) {
        self.viewModel = viewModel
        self.hostingView = NSHostingView(rootView: PickerView(viewModel: viewModel))
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        self.panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PickerLayout.width, height: 100),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        // `.popUpMenu`, not `.floating`: app pop-ups (quick-entry sheets,
        // menu-bar panels) often sit at `.floating` themselves, and since
        // they belong to the active app they'd win the tie and cover our
        // background-app picker. Matches where NSMenu / the native emoji
        // candidate window sit — above any app's floating UI.
        panel.level = .popUpMenu
        panel.isOpaque = false
        panel.backgroundColor = .clear
        // System menu shadow matches NSMenu's drop shadow exactly.
        panel.hasShadow = true
        panel.hidesOnDeactivate = false
        panel.becomesKeyOnlyIfNeeded = true
        // Not `.canJoinAllSpaces`: a panel on every Space flashes onto the
        // destination Space during a swipe before the Space-change observer can
        // dismiss it. `.fullScreenAuxiliary` still lets it overlay a fullscreen
        // app's Space when shown there.
        panel.collectionBehavior = [.fullScreenAuxiliary, .transient]

        // NSPopover's Liquid Glass on Tahoe+ (see PopoverGlass); pre-26
        // falls back to NSVisualEffectView `.menu`.
        self.chrome = Self.makeChrome(hosting: hostingView)
        panel.contentView = chrome

        self.stripHostingView = NSHostingView(rootView: AnyView(EmptyView()))
        stripHostingView.translatesAutoresizingMaskIntoConstraints = false
        self.stripPanel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: PickerLayout.quickSuggestionWidth, height: PickerLayout.quickSuggestionHeight),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        stripPanel.isFloatingPanel = true
        stripPanel.level = .popUpMenu
        stripPanel.isOpaque = false
        stripPanel.backgroundColor = .clear
        stripPanel.hasShadow = true
        stripPanel.hidesOnDeactivate = false
        stripPanel.becomesKeyOnlyIfNeeded = true
        stripPanel.collectionBehavior = [.fullScreenAuxiliary, .transient]
        self.stripChrome = Self.makeChrome(hosting: stripHostingView, cornerRadius: PickerLayout.quickSuggestionRadius)
        stripPanel.contentView = stripChrome

        viewModel.onPillHover = { [weak self] index in
            self?.handlePillHover(index)
        }
    }

    // MARK: - Pill number-hotkey tooltip

    private func handlePillHover(_ index: Int?) {
        pillTooltipWork?.cancel()
        guard let index, index < 8, index < viewModel.results.count else {
            hidePillTooltip()
            return
        }
        let scored = viewModel.results[index]
        guard scored.emoji.hexcode != EmojiBrowser.sentinelHexcode else {
            hidePillTooltip()
            return
        }
        let name = ":\(scored.emoji.primaryShortcode):"
        let work = DispatchWorkItem { [weak self] in
            self?.showPillTooltip(index: index, name: name)
        }
        pillTooltipWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Transparent margin around the bubble so its (soft, SwiftUI) shadow has
    /// room to render inside the tooltip window instead of being clipped — the
    /// window's own AppKit `hasShadow` is off so the pill matches the browser's
    /// in-panel tooltip exactly.
    private static let tooltipShadowPad: CGFloat = 6

    private func showPillTooltip(index: Int, name: String) {
        guard viewModel.isVisible, viewModel.compact else { return }
        let pad = Self.tooltipShadowPad
        let hosting = NSHostingView(rootView: EmojiTooltip(name: name).padding(pad))
        let size = hosting.fittingSize

        let tip: NSPanel
        if let existing = tooltipPanel {
            tip = existing
        } else {
            tip = NSPanel(
                contentRect: NSRect(origin: .zero, size: size),
                styleMask: [.borderless, .nonactivatingPanel],
                backing: .buffered, defer: false
            )
            tip.isFloatingPanel = true
            tip.level = .popUpMenu  // same band as the picker so app pop-ups can't slip above it
            tip.isOpaque = false
            tip.backgroundColor = .clear
            tip.hasShadow = false  // bubble carries its own soft SwiftUI shadow
            tip.ignoresMouseEvents = true  // never interrupt the hover
            tip.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .transient]
            tooltipPanel = tip
        }
        tip.appearance = NSApp.effectiveAppearance
        tip.contentView = hosting

        // Centered above cell `index` of the pill. `pad` is the transparent
        // shadow margin baked into the window, so offset by it to keep the
        // bubble's visual gap above the pill constant.
        let gap: CGFloat = 4
        let cellCenterX = panel.frame.minX + PickerLayout.compactPadding
            + CGFloat(index) * (PickerLayout.compactCell + PickerLayout.compactSpacing)
            + PickerLayout.compactCell / 2
        var origin = CGPoint(x: cellCenterX - size.width / 2, y: panel.frame.maxY + gap - pad)
        let screen = NSScreen.screens.first { $0.frame.intersects(panel.frame) } ?? NSScreen.main
        if let visible = screen?.visibleFrame {
            origin.x = min(max(origin.x, visible.minX + 4), visible.maxX - size.width - 4)
            if origin.y + size.height - pad > visible.maxY {
                origin.y = panel.frame.minY - gap - size.height + pad  // flip below
            }
        }
        tip.setFrame(CGRect(origin: origin, size: size), display: true)
        tip.orderFront(nil)
    }

    private func hidePillTooltip() {
        pillTooltipWork?.cancel()
        tooltipPanel?.orderOut(nil)
    }

    /// Follow the live system appearance. A borderless panel created once
    /// and reused otherwise stays pinned to its launch-time appearance, so
    /// the picker looked stuck in light mode after a dark-mode switch.
    private func matchSystemAppearance() {
        let appearance = NSApp.effectiveAppearance
        panel.appearance = appearance
        stripPanel.appearance = appearance
        if #available(macOS 26.0, *), let glass = chrome as? NSGlassEffectView {
            PopoverGlass.match(glass, to: appearance)
        }
        if #available(macOS 26.0, *), let glass = stripChrome as? NSGlassEffectView {
            PopoverGlass.match(glass, to: appearance)
        }
    }

    /// Vertical list uses the panel corner radius; the compact pill is a
    /// capsule (radius = half its height).
    private func setCornerRadius(_ radius: CGFloat) {
        if #available(macOS 26.0, *), let glass = chrome as? NSGlassEffectView {
            glass.cornerRadius = radius
        } else {
            chrome.layer?.cornerRadius = radius
            (chrome as? NSVisualEffectView)?.applyRoundedMask(radius: radius)
            // The shadow is traced from the window's alpha, which the mask
            // just changed.
            panel.invalidateShadow()
        }
    }

    private static func makeChrome(hosting: NSHostingView<PickerView>) -> NSView {
        makeChrome(hosting: hosting, cornerRadius: PickerLayout.cornerRadius)
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
            effect.applyRoundedMask(radius: cornerRadius)
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

    /// Anchors near the caret rect, or the mouse if nil.
    func show(near caret: CGRect?) {
        hidePillTooltip()  // clear any stale tooltip; re-shows on hover
        stripPanel.orderOut(nil)
        // Pill / list mode tracks the caret; if the user dragged a previous
        // expanded session, snap back to caret-anchored on the next open.
        panel.isMovableByWindowBackground = false
        let anchor = caret ?? PanelPositioner.mouseAnchor()
        matchSystemAppearance()
        let size = preferredSize()
        setCornerRadius(viewModel.compact ? size.height / 2 : PickerLayout.cornerRadius)
        let frame = positionedFrame(anchor: anchor, size: size)

        panel.setFrame(frame, display: true)
        panel.orderFrontRegardless()
        viewModel.isVisible = true
        installClickMonitors()
    }

    func reposition(near caret: CGRect?) {
        guard viewModel.isVisible else { return }
        show(near: caret)
    }

    /// Grow (or open) the panel into the full browser grid. When already on
    /// screen (the pill), it unfolds from the pill's top-left with an eased
    /// animation; otherwise it just appears at full size near the caret.
    func showExpanded(near caret: CGRect?) {
        hidePillTooltip()
        matchSystemAppearance()
        let browser = viewModel.browser
        if let browser {
            stripHostingView.rootView = AnyView(QuickSuggestionStrip(
                browser: browser,
                suggestions: Array(browser.quickSuggestions.prefix(PickerLayout.quickSuggestionCount)),
                onPick: { [weak self] emoji in self?.onQuickPick?(emoji) }
            ))
        } else {
            stripHostingView.rootView = AnyView(EmptyView())
        }
        // Browser window can be dragged from any background area (search row,
        // tab bar, gaps between cells) — buttons and cells still receive their
        // own clicks via AppKit's hit-testing.
        panel.isMovableByWindowBackground = true
        setCornerRadius(BrowserLayout.cornerRadius)
        let size = CGSize(width: BrowserLayout.width, height: BrowserLayout.height)

        let anchor = caret ?? PanelPositioner.mouseAnchor()
        let stripFrame = PanelPositioner.frame(
            anchor: anchor,
            size: CGSize(width: PickerLayout.quickSuggestionWidth, height: PickerLayout.quickSuggestionHeight),
            probe: .anchorCenter,
            clampMinY: true
        )
        stripPanel.setFrame(stripFrame, display: true)

        if panel.isVisible {
            let current = panel.frame
            let target = clampToVisible(
                CGRect(x: current.minX, y: current.maxY - size.height, width: size.width, height: size.height),
                on: current
            )
            panel.setFrame(avoidOverlap(target, with: stripFrame), display: true)
        } else {
            panel.setFrame(avoidOverlap(positionedFrame(anchor: anchor, size: size), with: stripFrame), display: true)
            panel.orderFrontRegardless()
        }
        stripPanel.orderFrontRegardless()
        viewModel.isVisible = true
        installClickMonitors()
    }

    /// Keep a frame fully on the screen that hosts `reference`.
    private func clampToVisible(_ frame: CGRect, on reference: CGRect) -> CGRect {
        let screen = NSScreen.screens.first { $0.frame.intersects(reference) }
            ?? NSScreen.main ?? NSScreen.screens.first!
        let visible = screen.visibleFrame
        var f = frame
        if f.maxX > visible.maxX { f.origin.x = visible.maxX - f.width - 8 }
        if f.minX < visible.minX { f.origin.x = visible.minX + 8 }
        if f.maxY > visible.maxY { f.origin.y = visible.maxY - f.height - 8 }
        if f.minY < visible.minY { f.origin.y = visible.minY + 8 }
        return f
    }

    func hide() {
        panel.orderOut(nil)
        stripPanel.orderOut(nil)
        viewModel.isVisible = false
        removeClickMonitors()
        hidePillTooltip()
    }

    // MARK: - Click-away

    private func installClickMonitors() {
        guard localClickMonitor == nil else { return }
        let types: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown]
        localClickMonitor = NSEvent.addLocalMonitorForEvents(matching: types) { [weak self] event in
            guard let self else { return event }
            if event.window !== self.panel && event.window !== self.stripPanel {
                self.onClickAway?()
            }
            return event
        }
        globalClickMonitor = NSEvent.addGlobalMonitorForEvents(matching: types) { [weak self] event in
            guard let self else { return }
            let point = NSEvent.mouseLocation
            if self.viewModel.isVisible && !self.panel.frame.contains(point) &&
                (!self.stripPanel.isVisible || !self.stripPanel.frame.contains(point)) {
                self.onClickAway?()
            }
        }
    }

    private func removeClickMonitors() {
        if let monitor = localClickMonitor { NSEvent.removeMonitor(monitor) }
        if let monitor = globalClickMonitor { NSEvent.removeMonitor(monitor) }
        localClickMonitor = nil
        globalClickMonitor = nil
    }

    // MARK: - Layout

    private func preferredSize() -> CGSize {
        if viewModel.compact {
            let count = max(viewModel.results.count, 1)
            // Each cell + inter-cell spacing + side padding. The Browse cell
            // also carries a thin leading divider (~3pt) — pad for it.
            let cells = CGFloat(count) * PickerLayout.compactCell
            let gaps = CGFloat(max(count - 1, 0)) * PickerLayout.compactSpacing
            let width = cells + gaps + PickerLayout.compactPadding * 2 + 4
            return CGSize(width: width, height: PickerLayout.compactHeight)
        }
        let rowHeight: CGFloat = PickerLayout.rowHeight
        let footerHeight: CGFloat = PickerLayout.footerHeight
        let verticalPadding: CGFloat = PickerLayout.listTopGap - 2
        let count = max(min(viewModel.results.count, PickerLayout.maxVisibleRows), 1)
        let height = (CGFloat(count) * rowHeight) + footerHeight + verticalPadding
        return CGSize(width: PickerLayout.width, height: height)
    }

    private func positionedFrame(anchor: CGRect, size: CGSize) -> CGRect {
        PanelPositioner.frame(anchor: anchor, size: size, probe: .anchorCenter, clampMinY: true)
    }

    /// Keep the large browser readable while the caret strip remains visible.
    /// If the normal caret placement overlaps the strip, move the browser to
    /// the other side of it and then apply the screen clamp.
    private func avoidOverlap(_ frame: CGRect, with strip: CGRect) -> CGRect {
        guard frame.intersects(strip) else { return frame }
        let screen = NSScreen.screens.first { $0.frame.intersects(strip) } ?? NSScreen.main ?? NSScreen.screens.first!
        return Self.browserFrame(frame, avoiding: strip, visible: screen.visibleFrame)
    }

    static func browserFrame(_ frame: CGRect, avoiding strip: CGRect, visible: CGRect) -> CGRect {
        let safe = visible.insetBy(dx: 8, dy: 8)
        func clamp(_ candidate: CGRect) -> CGRect {
            CGRect(x: min(max(candidate.minX, safe.minX), safe.maxX - candidate.width),
                   y: min(max(candidate.minY, safe.minY), safe.maxY - candidate.height),
                   width: candidate.width, height: candidate.height)
        }
        let gap: CGFloat = 8
        let candidates = [
            CGRect(x: frame.minX, y: strip.maxY + gap, width: frame.width, height: frame.height),
            CGRect(x: frame.minX, y: strip.minY - gap - frame.height, width: frame.width, height: frame.height),
            CGRect(x: strip.maxX + gap, y: frame.minY, width: frame.width, height: frame.height),
            CGRect(x: strip.minX - gap - frame.width, y: frame.minY, width: frame.width, height: frame.height)
        ].map(clamp)
        if let fit = candidates.first(where: { safe.contains($0) && !$0.intersects(strip) }) { return fit }
        // Only physically tiny screens need overlap; minimize it while keeping controls visible.
        func overlap(_ rect: CGRect) -> CGFloat {
            let hit = rect.intersection(strip)
            return hit.isNull ? 0 : hit.width * hit.height
        }
        return candidates.min { overlap($0) < overlap($1) } ?? clamp(frame)
    }
}

/// Shared tooltip chrome for the pill and the browser grid so the two read
/// identically. A custom view, not a system tooltip: the picker panel is
/// non-key, so AppKit suppresses native `.help` tooltips on it.
struct EmojiTooltip: View {
    let name: String

    var body: some View {
        Text(name)
            .foregroundStyle(.primary)
            .font(.system(size: 11))
            .lineLimit(1)
            .fixedSize()
            .padding(.horizontal, 7)
            .padding(.vertical, 3)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color(nsColor: .windowBackgroundColor))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .strokeBorder(Color.primary.opacity(0.15))
            )
            .shadow(color: .black.opacity(0.18), radius: 3, y: 1)
    }
}

/// A single dense row that complements (rather than replaces) the full
/// browser. The number is always visible, so the gesture is Fn → 3 without
/// requiring the pointer to land precisely on a glyph.
struct QuickSuggestionStrip: View {
    @ObservedObject var browser: EmojiBrowserViewModel
    let suggestions: [Emoji]
    let onPick: ((Emoji) -> Void)?

    var body: some View {
        HStack(spacing: PickerLayout.quickSuggestionSpacing) {
            ForEach(Array(suggestions.enumerated()), id: \.element.id) { index, emoji in
                Button {
                    onPick?(emoji)
                } label: {
                    ZStack(alignment: .topLeading) {
                        Text(emoji.tonedGlyph)
                            .font(.system(size: 24))
                            .frame(width: PickerLayout.quickSuggestionCell, height: PickerLayout.quickSuggestionCell)
                        Text(verbatim: "\(index + 1)")
                            .font(.system(size: 9, weight: .semibold, design: .rounded))
                            .foregroundStyle(.secondary)
                            .opacity(browser.searchInputActive ? 0.35 : 1)
                            .padding(.leading, 3)
                            .padding(.top, 2)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel(Text("\(index + 1), \(emoji.label)"))
                .help("\(index + 1) · \(emoji.label)")
                .disabled(browser.searchInputActive)
            }
        }
        .padding(.horizontal, PickerLayout.quickSuggestionPadding)
        .frame(width: PickerLayout.quickSuggestionWidth, height: PickerLayout.quickSuggestionHeight)
    }
}

enum PickerLayout {
    static let width: CGFloat = 280
    static let rowHeight: CGFloat = 30
    static let footerHeight: CGFloat = 26
    static let maxVisibleRows: Int = 6
    /// The list reads as a menu, so it takes NSMenu's Tahoe radius.
    static let cornerRadius: CGFloat = 13

    /// Gap above the first row, and the selection's side inset. Equal, with
    /// the selection radius stepped down by the inset, so the top highlight
    /// runs concentric with the panel corner, as NSMenu's does.
    static let listTopGap: CGFloat = 5
    static let selectionInset: CGFloat = 5
    static var selectionRadius: CGFloat { cornerRadius - selectionInset }

    // Compact horizontal bar (bare-`:` favorites), styled like the macOS
    // predictive emoji strip: a capsule of cells, selected one filled.
    // Sized so the "top 8" reads as a row of 8 generous glyphs + the chevron.
    static let compactCell: CGFloat = 40
    static let compactSpacing: CGFloat = 2
    static let compactPadding: CGFloat = 6
    static var compactHeight: CGFloat { compactCell + compactPadding * 2 }

    static let quickSuggestionCount = 8
    static let quickSuggestionCell: CGFloat = 42
    static let quickSuggestionSpacing: CGFloat = 1
    static let quickSuggestionPadding: CGFloat = 7
    static let quickSuggestionHeight: CGFloat = 54
    static let quickSuggestionRadius: CGFloat = 14
    static var quickSuggestionWidth: CGFloat {
        CGFloat(quickSuggestionCount) * quickSuggestionCell
            + CGFloat(quickSuggestionCount - 1) * quickSuggestionSpacing
            + quickSuggestionPadding * 2
    }
}
