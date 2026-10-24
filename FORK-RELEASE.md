# Spritz preview 1

An independent fork of Mojito v1.10.1, focused on fast emoji insertion.

- Select a visible emoji with one number or letter after opening the picker.
- Keep mnemonic letters attached to their emoji as usage rankings change.
- Browse full Most used and Recent lists, with collision-free pages.
- Show a compact numbered row near the typing area, with a window-based fallback.
- Offer local keyword suggestions from supported text fields.
- Open the full catalogue on a fresh install.

This release contains source code only. No notarized installer is available yet; see the README for build and Fn/Globe setup instructions. The fork has its own bundle identity and permissions, and disables upstream telemetry and automatic updates.

A letter can be reused on a different page; always use the visible label. Context suggestions are keyword matches, and caret placement depends on the host application's accessibility support.

Based on Mojito by Wells Riley, distributed under AGPL-3.0.
