# Spritz Architecture

## 1. Crate & App Split

```text
+---------------------------------------------------------------+
| SwiftUI + AppKit Shell (macos/Sources/SpritzApp)              |
|  - PickerPanel (non-activating NSPanel, NSGlassEffectView)    |
|  - PickerView & DictationSwapStrip (10-col slots, 7-col grid) |
|  - MenuBarController & compact SettingsView                   |
|  - TouchBar DistributedNotificationCenter + SMAppService       |
+------------------------------+--------------------------------+
                               | C-ABI (spritz_ffi.h)
+------------------------------v--------------------------------+
| spritz-macos (crates/spritz-macos -> libspritz_macos.a)       |
|  - EventTap (CGEventTap KeyDown | FlagsChanged, FnGesture)    |
|  - AXObserver + FocusedElementCache + live async AX refresh   |
|  - CaretLocator (kAXBoundsForRange -> element -> window)      |
|  - TextInserter (chunked <= 20 UTF-16 units, SYNTH_MARKER)    |
|  - NativeDictationCapture + AgyRefinementRunner               |
|  - SecureInput (IOKit kCGSSessionSecureInputPID)              |
+------------------------------+--------------------------------+
                               | Pure Rust API
+------------------------------v--------------------------------+
| spritz-core (crates/spritz-core -> portable rlib/staticlib)   |
|  - EmojiDatabase (embedded emojibase-en.json, FE0F-agnostic)  |
|  - Fuzzy search (fzy scorer + stemmer + usage boost)          |
|  - PickerModel (1-0, a-z mnemonics, drag ops, categories)     |
|  - ContextMatcher, FnGesture, UnicodeChunker, RecentTyping    |
|  - VoiceBackend trait + DictationState + DictationReceipt     |
|  - TouchBarState schema v1, LocalTelemetry, Config & State    |
+---------------------------------------------------------------+
```

## 2. iOS Keyboard & Shadow-First Voice Roadmap

Because `crates/spritz-core` has zero `AppKit`, `Carbon`, `CGEvent`, or filesystem daemon dependencies, the same C-ABI pattern (`spritz-core` -> small platform wrapper crate) extends directly to an iOS `UIInputViewController` custom keyboard extension:

- **iOS Keyboard Target (`crates/spritz-ios`):** Expose `EmojiDatabase`, fuzzy search, `PickerModel`, skin tone selection, and `LocalTelemetry` to Swift via an `ios-staticlib` XCFramework. `UIInputViewController.textDocumentProxy` implements text insertion (`insertText`) and surrounding context (`documentContextBeforeInput`), feeding `context::match_context` for Suggested emojis just like AX does on macOS.
- **Shadow-First `VoiceBackend` Trait:** Defined in `spritz_core::dictation::VoiceBackend`. Today macOS runs `VoiceMode::ChatGptPassthrough`, leaving physical `Fn` holds untouched so ChatGPT/Codex remains the active dictation path while Spritz observes field diffs into `DictationState`. Future backends (e.g., on-device Whisper/CoreML or cloud streaming in shadow comparison mode, and iOS Full-Access mic capture inside the keyboard's container/extension) implement `VoiceBackend` and surface shadow candidates alongside the primary transcript inside `DictationSwapStrip` without interrupting the active dictation workflow.
