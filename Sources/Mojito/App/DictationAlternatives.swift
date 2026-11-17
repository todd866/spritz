import AppKit
import Combine
import SwiftUI

@MainActor
final class DictationAlternatives: ObservableObject {
    static let shared = DictationAlternatives()
    @Published var choices: [String] = []
    @Published var selected = 0
    @Published var status = ""
    @Published var busy = false
    @Published var copyOnly = false
    @Published var provider: RefinementProvider {
        didSet {
            UserDefaults.standard.set(provider.rawValue, forKey: "speechRefinementProvider")
            runner.cancel(); busy = false
            if provider != .off, !choices.isEmpty { refine() }
        }
    }
    var onEmoji: (() -> Void)?
    private let runner = RefinementRunner()
    private var panel: NSPanel?
    private var element: AXUIElement?
    private var pid: pid_t?
    private var focusGeneration = 0
    private var receipt: DictationReceipt?
    private var currentText = ""
    private var session = UUID()
    private var revision = 0
    private var applying = false
    private var expiry: Task<Void, Never>?
    private var observers: [NSObjectProtocol] = []
    private var clickMonitor: Any?
    private(set) var visible = false

    init(preview: Bool = false) {
        provider = preview ? .codex : RefinementProvider(rawValue: UserDefaults.standard.string(forKey: "speechRefinementProvider") ?? "Codex") ?? .codex
        guard !preview else { return }
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification, NSWorkspace.didActivateApplicationNotification] {
            observers.append(NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.clear() }
            })
        }
    }
    func clear() {
        if busy { LocalTelemetry.shared.record(.refinementCancel) }
        session = UUID(); revision &+= 1; runner.cancel(); expiry?.cancel(); expiry = nil
        applying = false
        hide(); choices = []; receipt = nil; element = nil; pid = nil; currentText = ""; busy = false; status = ""
    }
    func begin(text: String, element: AXUIElement, pid: pid_t) {
        clear()
        guard provider != .off else { return }
        focusGeneration = FocusedElementCache.shared.bridgeFocusGeneration
        self.element = element; self.pid = pid; choices = [text]; currentText = text
        selected = 0; copyOnly = false
        captureReceipt()
        refine()
        let id = session
        expiry = Task { @MainActor in
            try? await Task.sleep(for: .seconds(120))
            if !Task.isCancelled, self.session == id { self.clear() }
        }
    }
    func refine() {
        guard let original = choices.first, provider != .off else { return }
        choices = [original]; selected = 0; busy = true; status = ""
        let id = session, started = Date()
        LocalTelemetry.shared.record(.refinementStart)
        runner.run(original, provider: provider) { [weak self] result in
            guard let self, self.session == id else { return }
            self.busy = false
            if let result {
                // Keep the labels stable, including when a model considers the original already good.
                self.choices = [original, result.cleaned, result.clearer]
                LocalTelemetry.shared.record(.refinementReady, durationMilliseconds: Date().timeIntervalSince(started) * 1000)
            } else {
                self.status = "Unavailable"; LocalTelemetry.shared.record(.refinementFailure)
            }
        }
    }
    private func targetMatches() -> Bool {
        let cache = FocusedElementCache.shared
        guard element != nil, let pid, cache.haveFieldInfo, cache.focusedIsEditable, !cache.focusedIsSecure,
              NSWorkspace.shared.frontmostApplication?.processIdentifier == pid,
              cache.bridgeFocusGeneration == focusGeneration else { return false }
        return true
    }
    private func captureReceipt() {
        let id = session, version = revision
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
            guard let self, self.session == id, self.revision == version, self.targetMatches(), let element = self.element, let pid = self.pid else { return }
            DictationFieldReader.read(element: element, pid: pid) { [weak self] value, range in
                MainActor.assumeIsolated {
                    guard let self, self.session == id, self.revision == version, self.targetMatches() else { return }
                    self.receipt = value.flatMap { value in range.flatMap { DictationReceipt.capture(value: value, selection: $0, text: self.currentText) } }
                    self.copyOnly = self.receipt == nil
                }
            }
        }
    }
    func toggle(emoji: @escaping () -> Void) -> Bool {
        guard !choices.isEmpty, targetMatches() else { clear(); return false }
        onEmoji = { [weak self] in self?.hide(); emoji() }
        if visible { hide(); return true }
        if panel == nil {
            let panel = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 520, height: 420), styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: false)
            panel.isFloatingPanel = true; panel.level = .popUpMenu; panel.hidesOnDeactivate = false
            panel.becomesKeyOnlyIfNeeded = true; panel.hasShadow = true
            panel.isOpaque = false; panel.backgroundColor = .clear
            panel.collectionBehavior = [.fullScreenAuxiliary, .transient]
            panel.contentView = NSHostingView(rootView: DictationAlternativesView(model: self))
            self.panel = panel
        }
        guard let panel else { return false }
        panel.appearance = NSApp.effectiveAppearance
        let anchor = PanelPositioner.mouseAnchor()
        let screen = NSScreen.screens.first { $0.frame.contains(anchor.origin) } ?? NSScreen.main
        let size = NSSize(width: min(520, (screen?.visibleFrame.width ?? 528) - 8), height: min(420, (screen?.visibleFrame.height ?? 428) - 8))
        panel.setFrame(PanelPositioner.frame(anchor: anchor, size: size, probe: .anchorCenter, clampMinY: true), display: true)
        panel.orderFrontRegardless(); visible = true
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
            MainActor.assumeIsolated { self?.revision &+= 1; self?.hide() }
        }
        return true
    }
    func hide() {
        panel?.orderOut(nil); visible = false
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor) }; clickMonitor = nil
    }
    func handle(_ input: TriggerInput) -> Bool {
        if case .focusChange = input { clear(); return false }
        if visible {
            switch input {
            case .escape: hide(); return true
            case .arrowDown: selected = min(selected + 1, choices.count - 1); return true
            case .arrowUp: selected = max(selected - 1, 0); return true
            case .returnKey: choose(selected); return true
            case .nameChar(let c) where ["1", "2", "3"].contains(c):
                if let number = Int(String(c)), number <= choices.count { choose(number - 1) }; return true
            default: break
            }
        }
        revision &+= 1; receipt = nil; copyOnly = true; hide()
        return false
    }
    func copy(_ index: Int) {
        guard choices.indices.contains(index) else { return }
        NSPasteboard.general.clearContents(); NSPasteboard.general.setString(choices[index], forType: .string)
        LocalTelemetry.shared.record(.refinementCopy); hide()
    }
    func choose(_ index: Int) {
        guard choices.indices.contains(index), !applying else { return }
        if copyOnly { copy(index); return }
        guard let receipt, targetMatches(), let element, let pid else { copyOnly = true; status = "Copy to use"; return }
        applying = true
        let text = choices[index], id = session, version = revision
        DictationFieldReader.read(element: element, pid: pid) { [weak self] value, range in
            MainActor.assumeIsolated {
                guard let self, self.session == id else { return }
                self.applying = false
                guard self.revision == version else { return }
                guard self.visible, self.targetMatches(), let value, let range, receipt.matches(value: value, selection: range) else {
                    self.copyOnly = true; self.status = "Text changed · copy to use"; return
                }
                TextInserter.replace(charactersToDelete: receipt.text.count, with: text)
                self.revision &+= 1; self.receipt = nil; self.currentText = text; self.hide(); self.captureReceipt()
                LocalTelemetry.shared.record(.refinementChosen)
            }
        }
    }
}

struct DictationAlternativesView: View {
    @ObservedObject var model: DictationAlternatives
    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 8) {
                Picker("AI", selection: $model.provider) {
                    ForEach(RefinementProvider.allCases) { Text($0.rawValue).tag($0) }
                }.frame(width: 130)
                if model.busy { ProgressView().controlSize(.small).accessibilityLabel("Preparing alternatives") }
                if !model.status.isEmpty { Text(model.status).font(.caption).fixedSize(horizontal: false, vertical: true) }
                Spacer(minLength: 0)
                if !model.busy && model.choices.count == 1 && model.provider != .off { Button("Retry") { model.refine() } }
                Button("Emoji") { model.onEmoji?() }
                Button { model.hide() } label: { Image(systemName: "xmark") }.accessibilityLabel("Close")
            }.padding(12)
            Divider()
            ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    ForEach(Array(model.choices.enumerated()), id: \.offset) { index, text in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text(["1 · Original", "2 · Cleaned", "3 · Clearer"][index]).font(.system(size: 12, weight: .semibold))
                                Spacer()
                                if !model.copyOnly { Button("Copy") { model.copy(index) } }
                                Button(model.copyOnly ? "Copy" : "Use") { model.choose(index) }
                            }
                            Text(text).font(.system(size: 14)).frame(maxWidth: .infinity, alignment: .leading).fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(12)
                        .id(index)
                        .background(model.selected == index ? Color.accentColor.opacity(0.10) : Color.clear)
                        .contentShape(Rectangle()).onTapGesture { model.selected = index }
                        Divider()
                    }
                }
            }
            .onChange(of: model.selected) { _, value in proxy.scrollTo(value, anchor: .top) }
            }
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 13))
    }
}
