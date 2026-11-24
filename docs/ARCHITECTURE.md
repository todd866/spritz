# Spritz Architecture

## 1. Crate & App Split

```text
+----------------------------------+   +-----------------------------------+
| macOS App (macos/Sources)        |   | iOS App & Extension (ios/)        |
|  - PickerPanel (NSGlassEffect)   |   |  - SpritzKeyboard (UIInputView)   |
|  - PickerView & DictationStrip   |   |  - KeyboardDeckView (UIKit touch) |
|  - MenuBarController & Settings  |   |  - InstrumentBar + EmojiDeckView  |
|  - TouchBar IPC + SMAppService   |   |  - SpritzMobile (3-tab host UI)   |
+----------------+-----------------+   +-----------------+-----------------+
                 | C-ABI (spritz_ffi.h)                  | C-ABI (spritz_ios_ffi.h)
+----------------v-----------------+   +-----------------v-----------------+
| spritz-macos (libspritz_macos.a) |   | spritz-ios (SpritzCore.xcframework)|
|  - CGEventTap & FnGesture        |   |  - KeyboardSession FFI bridge     |
|  - AXObserver & CaretLocator     |   |  - Glide & candidate state cache  |
|  - Chunked CGEvent Inserter      |   |  - Emoji snapshot/pick/pin FFI    |
|  - SecureInput & TouchBar I/O    |   |  - Mtime-synced App Group storage |
|  - NativeDictation & AgyRunner   |   +-----------------+-----------------+
+----------------+-----------------+                     |
                 |               Pure Rust API           |
                 +-------------------+-------------------+
                                     |
+------------------------------------v-------------------------------------+
| spritz-core (crates/spritz-core -> portable rlib/staticlib)              |
|  - EmojiDatabase (emojibase-en.json) & Fuzzy Search (fzy + stemmer)      |
|  - PickerModel (1-0, a-z mnemonics, drag ops) & ContextMatcher           |
|  - keyboard.rs: QwertyGeometry, 22k MIT Lexicon, Spatial Autocorrect,    |
|    AU/UK/US Variants, Glide Decoder, Bigrams, Snippets, 1-Tap Undo       |
|  - FnGesture, UnicodeChunker, VoiceBackend Trait, Telemetry, Config      |
+--------------------------------------------------------------------------+
```

## 2. iOS Implementation Notes

- **Zero-Allocation Shared Engine (`crates/spritz-core::keyboard`):** Embeds a frequency-ranked 22,229-word MIT English lexicon (`crates/spritz-core/data/lexicon-en.txt`, derived from `hermitdave/FrequencyWords` plus curated AU/UK, clinical, developer, and contraction overlays) alongside endpoint-bucketed glide candidate filtering and QWERTY touch-coordinate spatial weighting.
- **Thin UIKit Extension (`ios/Keyboard/KeyboardViewController.swift` + `ios/Shared/`):** Runs `KeyboardDeckView` with direct `UIView` touch events (`touchesBegan`/`Moved`/`Ended`) for zero-latency key popups, flick-down secondary symbols, long-press accents, smooth `CAShapeLayer` glide trails, spacebar caret trackpad, left-swipe word deletion, an inline `38 pt` editing bar, and full Emojibase v16 search/grids. Config and pinned emoji state share cleanly with `SpritzMobile` via App Group storage (`group.io.github.todd866.SpritzMobile`, falling back to Application Support when unavailable).

## 3. Shadow-First `VoiceBackend` Roadmap

- **Shadow-First `VoiceBackend` Trait:** Defined in `spritz_core::dictation::VoiceBackend`. On macOS, `VoiceMode::ChatGptPassthrough` leaves physical `Fn` holds untouched so ChatGPT/Codex remains the active dictation path while Spritz observes settled diffs into `DictationState` and surfaces optional reviewed alternatives in `DictationSwapStrip`. Future on-device voice backends on both macOS and iOS implement `VoiceBackend` without altering the core UI shell contract.
