# Spritz preview 1

An independent fork of Mojito v1.10.1, focused on fast emoji insertion.

- Select a visible emoji with one number or letter after opening the picker.
- Keep numbers 1–9 and 0, then letters a–z, in fixed slots. Drag an emoji onto a slot to assign it, or onto empty space to clear it. A cleared slot stays empty.
- Browse full Most used and Recent lists. A letter shows its emoji on every tab.
- Open near the text caret, with a window-based fallback when a caret cannot be read.
- Offer local keyword suggestions from supported text fields.
- Open the full catalogue on a fresh install.

This release contains source code only. No notarized installer is available yet; see the README for build and Fn/Globe setup instructions. The fork has its own bundle identity and permissions, and disables upstream telemetry and automatic updates.

Context suggestions are keyword matches, and caret placement depends on the host application's accessibility support.

Based on Mojito by Wells Riley, distributed under AGPL-3.0.
