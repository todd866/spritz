import AppKit
import Combine
import CSpritzFFI
import Foundation
import ServiceManagement

struct RectDTO: Codable, Equatable {
    let x: Double
    let y: Double
    let width: Double
    let height: Double

    var cgRect: CGRect { CGRect(x: x, y: y, width: width, height: height) }
}

struct SlotDTO: Codable, Identifiable, Equatable {
    let id: String
    let hex: String?
    let glyph: String?
    let label: String?
    let shortcode: String?
    let shortcut: String?
}

struct EmojiCellDTO: Codable, Equatable {
    let hex: String
    let glyph: String
    let label: String
    let shortcode: String
}

struct SectionDTO: Codable, Identifiable, Equatable {
    let category: String
    let title: String
    let tabSymbol: String
    let startIndex: Int
    let count: Int
    var id: String { category }
}

struct PickerViewDTO: Codable, Equatable {
    let mode: String
    let availableModes: [String]
    let searchInputActive: Bool
    let isSearching: Bool
    let showsCategories: Bool
    let query: String
    let activeCategory: String
    let shortcutSelectedIndex: Int
    let selectedIndex: Int
    let scrollTargetSlot: String?
    let scrollTargetGrid: Int?
    let scrollSlotSeq: UInt64
    let scrollGridSeq: UInt64
    let slots: [SlotDTO]
    let gridItems: [EmojiCellDTO]
    let sections: [SectionDTO]
}

struct DictationDTO: Codable, Equatable {
    let hasStripContent: Bool
    let stripHeight: Double
    let choices: [String]
    let labels: [String]
    let selected: Int
    let textPreviewActive: Bool
    let busy: Bool
    let status: String
    let reviewNotes: String
    let copyOnly: Bool
}

struct SpritzSnapshot: Codable, Equatable {
    let visible: Bool
    let anchor: RectDTO?
    let anchoredByFallback: Bool
    let anchorUpdateSeq: UInt64
    let captureLocalKeys: Bool
    let active: Bool
    let pausedUntil: Double?
    let accessibility: Bool
    let inputMonitoring: Bool
    let allPermissionsGranted: Bool
    let secureInput: Bool
    let secureInputPid: Int32
    let skinTone: String
    let globeEnabled: Bool
    let replaceSystemPicker: Bool
    let launchAtLogin: Bool
    let showMenuBarIcon: Bool
    let useFrequencyBoost: Bool
    let needsLogoutForGlobe: Bool
    let refinementProvider: String
    let voiceMode: String
    let chatgptRunning: Bool
    let chatgptFnHookActive: Bool
    let totalEmojiInserted: UInt64
    let configPath: String
    let picker: PickerViewDTO?
    let dictation: DictationDTO

    var isPaused: Bool {
        guard let until = pausedUntil else { return false }
        return until > Date().timeIntervalSince1970
    }
}

enum TouchBarConstants {
    static let bundleID = "io.github.todd866.Spritz"
    static let requestName = Notification.Name("io.github.todd866.Spritz.touchbar.request")
    static let stateName = Notification.Name("io.github.todd866.Spritz.touchbar.state")
    static var userObject: String { "uid:\(getuid())" }
    static var stateURL: URL {
        FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/state/spritz/touchbar-state.json")
    }
    static let chatGPTBundleIDs: Set<String> = ["com.openai.codex", "com.openai.chat"]
}

enum LaunchAtLogin {
    static var statusCode: Int32 { Int32(SMAppService.mainApp.status.rawValue) }

    static func apply(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
        } catch {
            NSLog("Spritz: launch-at-login toggle failed: %@", error.localizedDescription)
        }
    }

    static func enableIfNeeded() -> (status: Int32, error: String) {
        var failure = ""
        let service = SMAppService.mainApp
        let st = service.status
        if st == .notRegistered || st == .notFound {
            do { try service.register() }
            catch { failure = error.localizedDescription }
        }
        return (Int32(service.status.rawValue), failure)
    }
}

@MainActor
final class SpritzBridge: ObservableObject {
    @Published var snapshot: SpritzSnapshot

    private var engine: OpaquePointer?
    private let instanceID = UUID().uuidString
    private var workspaceObservers: [NSObjectProtocol] = []
    private var dncObserver: NSObjectProtocol?
    private var heartbeatTimer: Timer?
    private var permissionTimer: Timer?
    private var loginStatusCached: Int32 = LaunchAtLogin.statusCode
    private var loginStatusRefreshedAt: TimeInterval = ProcessInfo.processInfo.systemUptime
    private static let loginStatusTTL: TimeInterval = 60.0

    var onStateUpdated: ((SpritzSnapshot) -> Void)?
    var onCopyToast: ((String) -> Void)?
    var onInsertAfterYield: ((String, Bool) -> Void)?
    var onOpenSettingsRequested: (() -> Void)?

    init(previewSnapshot: SpritzSnapshot? = nil) {
        if let previewSnapshot {
            self.snapshot = previewSnapshot
            return
        }

        let placeholder = Self.decodeSnapshot(ptr: spritz_preview_snapshot_json(false))!
        self.snapshot = placeholder
    }

    func startLiveEngine() {
        let selfPtr = Unmanaged.passUnretained(self).toOpaque()
        let callbacks = SpritzCallbacks(
            ctx: selfPtr,
            on_state_changed: { ctx in
                guard let ctx else { return }
                let bridge = Unmanaged<SpritzBridge>.fromOpaque(ctx).takeUnretainedValue()
                MainActor.assumeIsolated {
                    bridge.reloadSnapshot()
                }
            },
            on_copy_toast: { ctx, textPtr in
                guard let ctx, let textPtr else { return }
                let bridge = Unmanaged<SpritzBridge>.fromOpaque(ctx).takeUnretainedValue()
                let text = String(cString: textPtr)
                MainActor.assumeIsolated {
                    bridge.copyToPasteboard(text)
                }
            },
            on_touchbar_notify: { ctx, jsonPtr in
                guard let jsonPtr else { return }
                _ = ctx
                let json = String(cString: jsonPtr)
                MainActor.assumeIsolated {
                    SpritzBridge.postTouchBarNotification(json: json)
                }
            },
            on_insert_after_yield: { ctx, textPtr, keepOpen in
                guard let ctx, let textPtr else { return }
                let bridge = Unmanaged<SpritzBridge>.fromOpaque(ctx).takeUnretainedValue()
                let text = String(cString: textPtr)
                MainActor.assumeIsolated {
                    bridge.onInsertAfterYield?(text, keepOpen)
                }
            },
            on_open_settings: { ctx in
                guard let ctx else { return }
                let bridge = Unmanaged<SpritzBridge>.fromOpaque(ctx).takeUnretainedValue()
                MainActor.assumeIsolated {
                    bridge.onOpenSettingsRequested?()
                }
            }
        )

        self.engine = instanceID.withCString { cInst in
            spritz_engine_create(callbacks, cInst, LaunchAtLogin.statusCode)
        }
        installObservers()
        seedInitialWorkspaceState()
        reloadSnapshot()
        schedulePermissionPoll()
        if let engine {
            spritz_publish_touchbar(engine, true)
        }
    }

    func shutdown() {
        heartbeatTimer?.invalidate(); heartbeatTimer = nil
        permissionTimer?.invalidate(); permissionTimer = nil
        if let dncObserver {
            DistributedNotificationCenter.default().removeObserver(dncObserver)
        }
        let wsCenter = NSWorkspace.shared.notificationCenter
        for obs in workspaceObservers { wsCenter.removeObserver(obs) }
        workspaceObservers.removeAll()
        if let engine {
            spritz_engine_destroy(engine)
            self.engine = nil
        }
    }

    static func previewSnapshot(withAlternatives: Bool) -> SpritzSnapshot {
        decodeSnapshot(ptr: spritz_preview_snapshot_json(withAlternatives))!
    }

    private static func decodeSnapshot(ptr: UnsafeMutablePointer<CChar>?) -> SpritzSnapshot? {
        guard let ptr else { return nil }
        defer { spritz_free_cstr(ptr) }
        let data = Data(String(cString: ptr).utf8)
        return try? JSONDecoder().decode(SpritzSnapshot.self, from: data)
    }

    func reloadSnapshot() {
        guard let engine else { return }
        if let next = Self.decodeSnapshot(ptr: spritz_snapshot_json(engine)) {
            let permsChanged = next.allPermissionsGranted != snapshot.allPermissionsGranted
            snapshot = next
            onStateUpdated?(next)
            if permsChanged {
                schedulePermissionPoll()
            }
        }
    }

    // MARK: - Actions forwarded to Rust engine

    func toggleBrowser() { guard let engine else { return }; spritz_toggle_browser(engine) }
    func showBrowser() { guard let engine else { return }; spritz_show_browser(engine) }
    func collapseBrowser() { guard let engine else { return }; spritz_collapse_browser(engine) }
    func beginSearch() { guard let engine else { return }; spritz_begin_search(engine) }
    func setQuery(_ q: String) {
        guard let engine else { return }
        q.withCString { spritz_set_query(engine, $0) }
    }
    func selectMode(_ mode: String) {
        guard let engine else { return }
        mode.withCString { spritz_select_mode(engine, $0) }
    }
    func selectCategory(_ category: String) {
        guard let engine else { return }
        category.withCString { spritz_select_category(engine, $0) }
    }
    func pickHex(_ hex: String, keepOpen: Bool) {
        guard let engine else { return }
        hex.withCString { spritz_pick_hex(engine, $0, keepOpen) }
    }
    func resolveDrag(sourceHex: String, point: CGPoint, frames: [String: CGRect]) {
        guard let engine else { return }
        var dict: [String: [Double]] = [:]
        for (k, r) in frames {
            dict[k] = [r.origin.x, r.origin.y, r.size.width, r.size.height]
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let framesJSON = String(data: data, encoding: .utf8) else { return }
        sourceHex.withCString { cHex in
            framesJSON.withCString { cFrames in
                spritz_resolve_drag_and_drop(engine, cHex, point.x, point.y, cFrames)
            }
        }
    }
    func handleLocalCGEvent(_ cgEvent: CGEvent) -> Bool {
        guard let engine else { return false }
        return spritz_handle_local_cgevent(engine, Unmanaged.passUnretained(cgEvent).toOpaque())
    }
    func postSyntheticText(_ text: String, deleteChars: Int = 0) {
        guard let engine else { return }
        text.withCString { spritz_post_synthetic_text(engine, deleteChars, $0) }
    }
    func pauseForOneHour() { guard let engine else { return }; spritz_pause_for_secs(engine, 3600) }
    func pauseUntilTomorrow() {
        guard let engine else { return }
        var cal = Calendar.current.dateComponents([.year, .month, .day], from: Date())
        cal.day = (cal.day ?? 0) + 1
        cal.hour = 7
        let target = Calendar.current.date(from: cal) ?? Date().addingTimeInterval(8 * 3600)
        spritz_pause_for_secs(engine, max(60, target.timeIntervalSinceNow))
    }
    func resume() { guard let engine else { return }; spritz_resume(engine) }
    func setSkinTone(_ tone: String) {
        guard let engine else { return }
        tone.withCString { spritz_set_skin_tone(engine, $0) }
    }
    func setGlobeEnabled(_ enabled: Bool) {
        guard let engine else { return }
        spritz_set_globe_enabled(engine, enabled)
    }
    func setReplaceSystemPicker(_ enabled: Bool) {
        guard let engine else { return }
        spritz_set_replace_system_picker(engine, enabled)
    }
    func setLaunchAtLogin(_ enabled: Bool) {
        LaunchAtLogin.apply(enabled)
        refreshLoginStatus(force: true)
        guard let engine else { return }
        spritz_set_launch_at_login(engine, enabled)
    }
    func setRefinementProvider(_ raw: String) {
        guard let engine else { return }
        raw.withCString { spritz_set_refinement_provider(engine, $0) }
    }
    func setUISuspended(_ suspended: Bool) {
        guard let engine else { return }
        spritz_set_ui_suspended(engine, suspended)
    }
    func analyseFocusedText() {
        guard let engine else { return }
        spritz_analyse_focused_text(engine)
    }
    func selectDictationChoice(_ index: Int) {
        guard let engine else { return }
        spritz_select_dictation_choice(engine, index)
    }
    func chooseDictationChoice(_ index: Int, keepOpen: Bool) {
        guard let engine else { return }
        spritz_choose_dictation_choice(engine, index, keepOpen)
    }
    func pollPermissions() {
        guard let engine else { return }
        spritz_poll_permissions(engine)
    }
    func telemetryReport() -> String {
        guard let engine else { return "" }
        guard let ptr = spritz_telemetry_report(engine) else { return "" }
        defer { spritz_free_cstr(ptr) }
        return String(cString: ptr)
    }
    func flushTelemetry() {
        guard let engine else { return }
        spritz_flush_telemetry(engine)
    }

    func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        onCopyToast?(text)
    }

    // MARK: - Observers & Touch Bar Bridge

    private func seedInitialWorkspaceState() {
        guard let engine else { return }
        if let front = NSWorkspace.shared.frontmostApplication {
            (front.bundleIdentifier ?? "").withCString {
                spritz_on_app_activated(engine, front.processIdentifier, $0)
            }
        }
        let chatRunning = NSWorkspace.shared.runningApplications.contains {
            TouchBarConstants.chatGPTBundleIDs.contains($0.bundleIdentifier ?? "")
        }
        spritz_set_chatgpt_running(engine, chatRunning)
    }

    private func installObservers() {
        let ws = NSWorkspace.shared.notificationCenter
        workspaceObservers.append(
            ws.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
                let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                let pid = app?.processIdentifier ?? 0
                let bid = app?.bundleIdentifier ?? ""
                MainActor.assumeIsolated {
                    guard let self, let engine = self.engine else { return }
                    bid.withCString { spritz_on_app_activated(engine, pid, $0) }
                }
            }
        )
        workspaceObservers.append(
            ws.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self, let engine = self.engine else { return }
                    spritz_on_space_changed(engine)
                }
            }
        )
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            workspaceObservers.append(
                ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        guard let self, let engine = self.engine else { return }
                        spritz_on_sleep_or_resign(engine)
                    }
                }
            )
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            workspaceObservers.append(
                ws.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                    let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
                    guard let bid = app?.bundleIdentifier, TouchBarConstants.chatGPTBundleIDs.contains(bid) else { return }
                    MainActor.assumeIsolated {
                        guard let self, let engine = self.engine else { return }
                        let running = NSWorkspace.shared.runningApplications.contains {
                            TouchBarConstants.chatGPTBundleIDs.contains($0.bundleIdentifier ?? "")
                        }
                        spritz_set_chatgpt_running(engine, running)
                    }
                }
            )
        }
        workspaceObservers.append(
            NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated {
                    self?.refreshLoginStatus(force: true)
                    self?.pollPermissions()
                    self?.schedulePermissionPoll()
                }
            }
        )

        dncObserver = DistributedNotificationCenter.default().addObserver(
            forName: TouchBarConstants.requestName,
            object: TouchBarConstants.userObject,
            queue: .main
        ) { [weak self] note in
            guard let info = note.userInfo,
                  let data = try? JSONSerialization.data(withJSONObject: info),
                  let jsonStr = String(data: data, encoding: .utf8) else { return }
            MainActor.assumeIsolated { self?.handleTouchBarRequestJSON(jsonStr) }
        }

        let hb = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine else { return }
                self.refreshLoginStatus(force: false)
                spritz_publish_touchbar(engine, false)
            }
        }
        hb.tolerance = 1.0
        heartbeatTimer = hb

        schedulePermissionPoll()
    }

    private func schedulePermissionPoll() {
        permissionTimer?.invalidate()
        permissionTimer = nil
        guard engine != nil else { return }
        let healthy = snapshot.allPermissionsGranted
        let interval: TimeInterval = healthy ? 30.0 : 3.0
        let pt = Timer.scheduledTimer(withTimeInterval: interval, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, let engine = self.engine else { return }
                spritz_poll_permissions(engine)
                self.schedulePermissionPoll()
            }
        }
        pt.tolerance = healthy ? 5.0 : 0.5
        permissionTimer = pt
    }

    private func refreshLoginStatus(force: Bool) {
        let now = ProcessInfo.processInfo.systemUptime
        guard force || now - loginStatusRefreshedAt >= Self.loginStatusTTL else { return }
        loginStatusCached = LaunchAtLogin.statusCode
        loginStatusRefreshedAt = now
        if let engine {
            spritz_set_login_status(engine, loginStatusCached)
        }
    }

    func handleTouchBarRequestJSON(_ jsonStr: String) {
        guard let engine,
              let data = jsonStr.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        let isEnableLogin = (dict["command"] as? String) == "enable-login"
        var loginStatus: Int32 = 0
        var loginErr = ""
        if isEnableLogin {
            let res = LaunchAtLogin.enableIfNeeded()
            loginStatus = res.status
            loginErr = res.error
            loginStatusCached = res.status
            loginStatusRefreshedAt = ProcessInfo.processInfo.systemUptime
        }
        jsonStr.withCString { cJson in
            loginErr.withCString { cErr in
                spritz_handle_touchbar_request(engine, cJson, isEnableLogin, loginStatus, cErr)
            }
        }
    }

    func handleTouchBarDictionary(_ userInfo: [AnyHashable: Any]) {
        var dict: [String: Any] = [:]
        for (k, v) in userInfo {
            if let ks = k as? String { dict[ks] = v }
        }
        guard let data = try? JSONSerialization.data(withJSONObject: dict),
              let jsonStr = String(data: data, encoding: .utf8) else { return }
        handleTouchBarRequestJSON(jsonStr)
    }

    private static func postTouchBarNotification(json: String) {
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [AnyHashable: Any] else { return }
        DistributedNotificationCenter.default().postNotificationName(
            TouchBarConstants.stateName,
            object: TouchBarConstants.userObject,
            userInfo: obj,
            deliverImmediately: true
        )
    }
}
