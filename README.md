# Spritz

Clean-room native Rust + thin SwiftUI/AppKit macOS emoji picker with one-key shortcuts (`1`–`0` and persistent `a`–`z` mnemonics), `Fn` / `⌃⌘Space` invocation, ChatGPT hold-`Fn` dictation pass-through with optional text-review strip, and Touch Bar bridge support.

## Architecture

- [`crates/spritz-core`](crates/spritz-core): 100% pure Rust portable library (emoji catalog, fuzzy search, fixed 1–0 & a–z slot model with drag edits, local context matching, `FnGesture`, UTF-16 safe chunked text insertion, `VoiceBackend` abstraction, dictation diff/receipt/review state, Touch Bar policy/state, local 90-day operational telemetry, TOML config + JSON state). Zero OS dependencies; designed for macOS and a future iOS custom keyboard extension.
- [`crates/spritz-macos`](crates/spritz-macos): macOS platform I/O staticlib (`CGEventTap`, `AXUIElement`/`AXObserver`, `CGEventKeyboardSetUnicodeString`, `IsSecureEventInputEnabled`/IOKit holder, Carbon `⌃⌘Space` + symbolic hotkey suppression, `NativeDictationCapture` + `agy` review runner, Touch Bar state I/O, C-ABI FFI).
- [`macos`](macos): Thin native SwiftUI + AppKit UI shell (`NSGlassEffectView` Liquid Glass picker panel, Secure Input local key monitor fallback, status menu bar, Touch Bar `DistributedNotificationCenter` listener, `SMAppService` launch at login, compact single-screen settings).

## Build & Test

```sh
cargo test --workspace
./scripts/build.sh --debug
```
