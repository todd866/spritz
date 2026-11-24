#!/usr/bin/env python3
"""One-shot migration of existing Spritz plist preferences into TOML config + JSON state."""

from __future__ import annotations

import argparse
import os
import plistlib
import sys
import tempfile
import json
from pathlib import Path

PLIST_PATH = Path.home() / "Library" / "Preferences" / "io.github.todd866.Spritz.plist"
CONFIG_PATH = Path.home() / ".config" / "spritz" / "config.toml"
STATE_PATH = Path.home() / ".local" / "state" / "spritz" / "state.json"


def find_by_suffix(data: dict, suffix: str):
    if suffix in data:
        return data[suffix]
    for k, v in data.items():
        if isinstance(k, str) and k.endswith(f".{suffix}"):
            return v
    return None


def toml_escape(s: str) -> str:
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def write_atomic(path: Path, content: str, mode: int = 0o600) -> None:
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    fd, tmp_name = tempfile.mkstemp(prefix=path.name + ".", dir=str(path.parent))
    try:
        os.fchmod(fd, mode)
        with os.fdopen(fd, "w", encoding="utf-8") as f:
            f.write(content)
        os.replace(tmp_name, path)
    except Exception:
        try:
            os.unlink(tmp_name)
        except OSError:
            pass
        raise


def normalize_skin_tone(raw) -> str:
    allowed = {"default", "light", "mediumLight", "medium", "mediumDark", "dark"}
    if isinstance(raw, str) and raw in allowed:
        return raw
    return "default"


def normalize_refinement_provider(raw) -> str:
    if isinstance(raw, str) and raw.lower() == "off":
        return "Off"
    return "Antigravity"


def main() -> int:
    parser = argparse.ArgumentParser(description="Migrate Spritz plist prefs to config.toml and state.json")
    parser.add_argument("--dry-run", action="store_true", help="Print outputs without writing files")
    parser.add_argument("--force", action="store_true", help="Overwrite existing config/state files")
    args = parser.parse_args()

    if not PLIST_PATH.exists():
        print(f"No plist found at {PLIST_PATH}; nothing to migrate.", file=sys.stderr)
        return 0

    with PLIST_PATH.open("rb") as f:
        plist = plistlib.load(f)

    skin_tone = normalize_skin_tone(find_by_suffix(plist, "skinTone"))
    globe_raw = find_by_suffix(plist, "replaceSystemEmojiPicker.globeEnabled")
    globe_enabled = True if globe_raw is None else bool(globe_raw)
    replace_raw = find_by_suffix(plist, "replaceSystemEmojiPicker.enabled")
    replace_system_picker = True if replace_raw is None else bool(replace_raw)
    launch_raw = find_by_suffix(plist, "launchAtLogin")
    launch_at_login = True if launch_raw is None else bool(launch_raw)
    show_menu_raw = find_by_suffix(plist, "showMenuBarIcon")
    show_menu_bar_icon = True if show_menu_raw is None else bool(show_menu_raw)
    freq_raw = find_by_suffix(plist, "useFrequencyBoost")
    use_frequency_boost = True if freq_raw is None else bool(freq_raw)
    refinement_provider = normalize_refinement_provider(plist.get("speechRefinementProvider"))

    exclude_bundles = find_by_suffix(plist, "excludeBundleIDs") or []
    exclude_bundles = [str(x) for x in exclude_bundles if isinstance(x, str)]

    prior_fn = find_by_suffix(plist, "replaceSystemEmojiPicker.priorFnUsageType")
    prior_fn_int = int(prior_fn) if isinstance(prior_fn, int) else None

    numbered = find_by_suffix(plist, "numberedEmoji") or []
    numbered_clean = [str(x).upper() if x else "" for x in list(numbered)[:10]]
    while len(numbered_clean) < 10:
        numbered_clean.append("")

    letters_raw = find_by_suffix(plist, "letterBindings") or {}
    letter_bindings: dict[str, str] = {}
    if isinstance(letters_raw, dict):
        for k, v in letters_raw.items():
            if isinstance(k, str) and isinstance(v, str) and len(v) == 1 and "a" <= v.lower() <= "z":
                letter_bindings[k.upper()] = v.lower()

    released_shortcuts = find_by_suffix(plist, "releasedShortcuts") or []
    released_hexes = sorted({str(x).upper() for x in released_shortcuts if isinstance(x, str) and x})

    released_letters_raw = find_by_suffix(plist, "releasedLetters") or []
    released_letters = sorted({
        str(x).lower()
        for x in released_letters_raw
        if isinstance(x, str) and len(x) == 1 and "a" <= x.lower() <= "z"
    })

    recent_raw = find_by_suffix(plist, "recentEmoji") or []
    recent_emoji = []
    seen_recent = set()
    for x in recent_raw:
        if isinstance(x, str) and x:
            hx = x.upper()
            if hx not in seen_recent:
                seen_recent.add(hx)
                recent_emoji.append(hx)

    usage_raw = find_by_suffix(plist, "usageCounts") or {}
    usage_counts: dict[str, int] = {}
    if isinstance(usage_raw, dict):
        for k, v in usage_raw.items():
            if isinstance(k, str) and isinstance(v, int) and v > 0:
                usage_counts[k.upper()] = v

    total_inserted = find_by_suffix(plist, "totals.emojiInserted")
    total_inserted = int(total_inserted) if isinstance(total_inserted, int) else sum(usage_counts.values())

    first_launch = find_by_suffix(plist, "firstLaunchDate")
    first_launch_ts = float(first_launch) if isinstance(first_launch, (int, float)) else None

    toml_lines = [
        "# Spritz configuration",
        f"skin_tone = {toml_escape(skin_tone)}",
        f"globe_enabled = {'true' if globe_enabled else 'false'}",
        f"replace_system_picker = {'true' if replace_system_picker else 'false'}",
        f"launch_at_login = {'true' if launch_at_login else 'false'}",
        f"show_menu_bar_icon = {'true' if show_menu_bar_icon else 'false'}",
        f"use_frequency_boost = {'true' if use_frequency_boost else 'false'}",
        f"voice_mode = {toml_escape('ChatGptPassthrough')}",
        f"refinement_provider = {toml_escape(refinement_provider)}",
        "exclude_bundle_ids = [",
    ]
    for bid in exclude_bundles:
        toml_lines.append(f"  {toml_escape(bid)},")
    toml_lines.append("]")
    if prior_fn_int is not None:
        toml_lines.append(f"prior_fn_usage_type = {prior_fn_int}")
    toml_content = "\n".join(toml_lines) + "\n"

    state_obj = {
        "schema": 1,
        "numbered_emoji": numbered_clean,
        "letter_bindings": letter_bindings,
        "released_hexes": released_hexes,
        "released_letters": released_letters,
        "recent_emoji": recent_emoji,
        "usage_counts": usage_counts,
        "total_emoji_inserted": total_inserted,
        "first_launch_date": first_launch_ts,
    }
    state_content = json.dumps(state_obj, indent=2, ensure_ascii=False, sort_keys=True) + "\n"

    if args.dry_run:
        print("=== config.toml ===")
        print(toml_content)
        print("=== state.json ===")
        print(state_content[:1200] + ("..." if len(state_content) > 1200 else ""))
        return 0

    if not CONFIG_PATH.exists() or args.force:
        write_atomic(CONFIG_PATH, toml_content)
        print(f"Wrote {CONFIG_PATH}")
    else:
        print(f"Skipped existing {CONFIG_PATH} (pass --force to overwrite)")

    if not STATE_PATH.exists() or args.force:
        write_atomic(STATE_PATH, state_content)
        print(f"Wrote {STATE_PATH}")
    else:
        print(f"Skipped existing {STATE_PATH} (pass --force to overwrite)")

    print(
        f"Summary: numbered={len([x for x in numbered_clean if x])}/10, "
        f"letters={len(letter_bindings)}, released_letters={len(released_letters)}, "
        f"recent={len(recent_emoji)}, usage_keys={len(usage_counts)}, total={total_inserted}"
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
