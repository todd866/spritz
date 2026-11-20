import AppKit
import SwiftUI

// When xcodebuild launches Mojito Dev as the test host, skip the
// menubar/event-tap startup — single-instance enforcement would kill the
// test runner if a real Mojito Dev is already running, and the test
// bundle doesn't need the app's behavior. Test bundle loads after the
// runloop is up; just bring NSApp online and idle.
let isUnderXCTest = ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] != nil
if isUnderXCTest {
    _ = NSApplication.shared
    NSApp.run()
    exit(0)
}

if CommandLine.arguments.contains("--telemetry") {
    MainActor.assumeIsolated { print(LocalTelemetry.shared.report()) }
    exit(0)
}
// Explicit synthetic check: no user content, microphone, event tap or windows.
if CommandLine.arguments.contains("--check-refinement") || CommandLine.arguments.contains("--check-medical-refinement") {
    var finished = false
    var success = false
    let started = Date()
    let runner = MainActor.assumeIsolated { RefinementRunner() }
    MainActor.assumeIsolated {
        let medical = CommandLine.arguments.contains("--check-medical-refinement")
        let sample = medical ? "The patient needed a sal pingo oophorectomy and had previously suffered from post streptococcal glow merulo nephritis." : "um can you move the meeting to Thursday at three I think that works better but please check with Sam first"
        runner.run(sample, provider: .codex) { result in
            success = result != nil
            if medical, let result {
                let normalized = result.cleaned.lowercased().filter { $0.isLetter }
                success = normalized.contains("salpingooophorectomy") && normalized.contains("poststreptococcalglomerulonephritis")
                print("Synthetic medical correction: \(result.cleaned)")
            }
            finished = true
        }
    }
    while !finished { RunLoop.current.run(until: Date().addingTimeInterval(0.05)) }
    print("Codex refinement: \(success ? "passed" : "failed") · \(Int(Date().timeIntervalSince(started) * 1000)) ms")
    exit(success ? 0 : 1)
}

if MainActor.assumeIsolated({ handleTouchBarCLI() }) { exit(0) }

// Explicit offscreen preview path: no event tap, permissions, updater, or
// visible windows. The production SwiftUI view is rendered at its real size.
if let index = CommandLine.arguments.firstIndex(of: "--render-picker"),
   CommandLine.arguments.indices.contains(index + 1) {
    let destination = URL(fileURLWithPath: CommandLine.arguments[index + 1], isDirectory: true)
    MainActor.assumeIsolated {
        _ = NSApplication.shared
        try! FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        let previewSuite = "mojito.preview.\(UUID().uuidString)"
        let previewDefaults = UserDefaults(suiteName: previewSuite)!
        defer {
            previewDefaults.removePersistentDomain(forName: previewSuite)
            let plist = FileManager.default.homeDirectoryForCurrentUser
                .appendingPathComponent("Library/Preferences/\(previewSuite).plist")
            try? FileManager.default.removeItem(at: plist)
        }
        let demo = ["1F602", "1F605", "1F618", "1F60E", "1F913", "1F389", "1F44D", "2764", "1F680", "1F525", "1F914", "1F916"]
        previewDefaults.set(Dictionary(uniqueKeysWithValues: demo.enumerated().map { ($0.element, 100 - $0.offset) }), forKey: PrefsKey.usageCounts)
        previewDefaults.set(demo.reversed().map { $0 }, forKey: PrefsKey.recentEmoji)
        for dark in [false, true] {
            for scenario in ["mostUsed", "recent", "all", "search", "emptySearch", "largeText", "suggested", "category", "modeReset", "general", "privacy", "fn", "alternatives", "alternativesLong", "combined", "combinedLong"] {
                let browser = EmojiBrowserViewModel(database: .shared, quickAccess: QuickAccessStore(defaults: previewDefaults), defaults: previewDefaults, contextText: scenario == "suggested" ? "happy birthday cake party" : nil)
                if scenario == "recent" { browser.selectMode(.recent) }
                if scenario == "all" { browser.selectMode(.all) }
                if scenario == "search" { browser.setQuery("heart") }
                if scenario == "emptySearch" { browser.setQuery("zzqxzzqxzzqx") }
                let alternatives = DictationAlternatives(preview: true)
                alternatives.choices = ["Can you move the meeting to Thursday at three? I think that works better, but please check with Sam first.", "Can you move the meeting to Thursday at three? I think that works better, but please check with Sam first.", "Can you move the meeting to Thursday at three? I think that works better, but please check with Sam before moving it."]
                if scenario == "combined" || scenario == "combinedLong" { alternatives.labels = ["Apple", "GPT", "Reviewed"]; alternatives.selected = 1 }
                if scenario == "alternativesLong" || scenario == "combinedLong" { alternatives.choices = alternatives.choices.map { String(repeating: $0 + " ", count: 15) } }
                let content = InlineBrowserView(browser: browser, onPick: { _ in }, onCategory: { browser.selectCategory($0) })
                let view = VStack(spacing: 0) {
                    if scenario.hasPrefix("combined") {
                        VStack(spacing: 0) { content; DictationSwapStrip(model: alternatives) }.frame(width: BrowserLayout.width)
                    } else if scenario.hasPrefix("alternatives") {
                        DictationAlternativesView(model: alternatives)
                    } else if scenario == "fn" {
                        Form { EmojiBrowserHotkeyRow() }.formStyle(.grouped)
                    } else if scenario == "general" {
                        GeneralSettingsView()
                    } else if scenario == "privacy" {
                        Form { PrivacyDetailsRows() }.formStyle(.grouped)
                    } else {
                        content.frame(width: BrowserLayout.width, height: BrowserLayout.height)
                    }
                }
                    .environment(\.colorScheme, dark ? .dark : .light)
                    .environment(\.sizeCategory, scenario == "largeText" ? .accessibilityExtraExtraExtraLarge : .large)
                    .background(dark ? Color(red: 0.13, green: 0.13, blue: 0.14) : Color(red: 0.96, green: 0.96, blue: 0.97))
                let hosting = NSHostingView(rootView: view)
                let size = scenario.hasPrefix("combined") ? NSSize(width: BrowserLayout.width, height: BrowserLayout.height + 180) : scenario.hasPrefix("alternatives") ? NSSize(width: 520, height: 420) : scenario == "fn" ? NSSize(width: 650, height: 240) : ["general", "privacy"].contains(scenario) ? NSSize(width: 650, height: 700) : NSSize(width: BrowserLayout.width, height: BrowserLayout.height)
                let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
                window.appearance = NSAppearance(named: dark ? .darkAqua : .aqua)
                window.contentView = hosting
                hosting.setFrameSize(size)
                hosting.layoutSubtreeIfNeeded()
                RunLoop.current.run(until: Date().addingTimeInterval(0.15))
                if scenario == "category" || scenario == "modeReset" {
                    browser.selectCategory(.flags)
                    RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                    if scenario == "modeReset" {
                        browser.selectMode(.recent)
                        RunLoop.current.run(until: Date().addingTimeInterval(0.25))
                    }
                    hosting.layoutSubtreeIfNeeded()
                }
                guard let rep = hosting.bitmapImageRepForCachingDisplay(in: hosting.bounds) else { fatalError("No bitmap") }
                hosting.cacheDisplay(in: hosting.bounds, to: rep)
                guard let png = rep.representation(using: .png, properties: [:]) else { fatalError("No PNG") }
                try! png.write(to: destination.appendingPathComponent("\(scenario)-\(dark ? "dark" : "light").png"))
                window.orderOut(nil)
            }
        }
    }
    exit(0)
}

let app = NSApplication.shared

// Enforce before AppDelegate. NSApp.terminate posts asynchronously, so
// `applicationDidFinishLaunching` still runs — the delegate checks
// `willQuitDueToPeer` and short-circuits.
MainActor.assumeIsolated {
    SingleInstanceCoordinator.shared.enforce()
}

let delegate = MainActor.assumeIsolated { AppDelegate() }
app.delegate = delegate
app.run()
