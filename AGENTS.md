# Repository Guidelines

## Verification Gates

- **Rust & macOS:** Run `cargo test --workspace -j 2` after any Rust edit and ensure zero compiler warnings.
- **iOS (`SpritzMobile` & `SpritzKeyboard`):** Before claiming any iOS fix or UI change is complete, run:
  ```sh
  ./scripts/test-ios.sh
  ```
  (Pass `--skip-core` only if `crates/` did not change, and `--update-docs-screenshots` when refreshing README captures.)
  - Inspect rendered Light and Dark screenshots in `/tmp/spritz-ios-qa/` visually after UI/layout/theme changes.
  - When targeting a physical iPhone (`iphoneos` Release build using local signing overrides in `~/.config/spritz/ios-private.xcconfig`), verify App Group entitlements on both `SpritzMobile.app` and `PlugIns/SpritzKeyboard.appex` before deploying.

## Clean-Room & Privacy Boundaries

- Keep personal Apple Team IDs, signing identities, usernames, and private `.xcconfig` overrides strictly outside tracked files.
- Regenerate `ios/SpritzMobile.xcodeproj` via `xcodegen generate` after editing `ios/project.yml`.
