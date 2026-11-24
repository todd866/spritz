#!/usr/bin/env python3
"""Fetch MIT-licensed emojibase-data@16 and emit compact JSON for spritz-core."""

from __future__ import annotations

import json
import sys
import urllib.request
from pathlib import Path

BASE_URL = "https://cdn.jsdelivr.net/npm/emojibase-data@16/en"
URLS = {
    "data": f"{BASE_URL}/data.json",
    "emojibase": f"{BASE_URL}/shortcodes/emojibase.json",
    "github": f"{BASE_URL}/shortcodes/github.json",
}

OUT_PATH = (
    Path(__file__).resolve().parent.parent
    / "crates"
    / "spritz-core"
    / "data"
    / "emojibase-en.json"
)


def fetch_json(url: str):
    req = urllib.request.Request(
        url,
        headers={"User-Agent": "spritz-rs-fetch/1.0"},
    )
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)


def normalize_codes(raw) -> list[str]:
    if raw is None:
        return []
    if isinstance(raw, str):
        return [raw]
    if isinstance(raw, list):
        return [str(x) for x in raw if isinstance(x, str) and x]
    return []


def extract_skins(entry: dict) -> list[str] | None:
    skins = entry.get("skins")
    if not isinstance(skins, list) or not skins:
        return None
    by_tone: dict[int, str] = {}
    for item in skins:
        if not isinstance(item, dict):
            continue
        tone = item.get("tone")
        emoji = item.get("emoji")
        # Single-scalar tone modifiers are integers 1..=5; omit multi-tone arrays.
        if isinstance(tone, int) and 1 <= tone <= 5 and isinstance(emoji, str) and emoji:
            by_tone[tone] = emoji
    if len(by_tone) == 5:
        return [by_tone[1], by_tone[2], by_tone[3], by_tone[4], by_tone[5]]
    return None


def main() -> int:
    print("Fetching emojibase-data@16...", file=sys.stderr)
    data = fetch_json(URLS["data"])
    sc_eb = fetch_json(URLS["emojibase"])
    sc_gh = fetch_json(URLS["github"])

    records = []
    for entry in data:
        if not isinstance(entry, dict):
            continue
        group = entry.get("group")
        # Group 2 is Component (skin-tone modifiers, hair components).
        if not isinstance(group, int) or group < 0 or group == 2:
            continue
        hexcode = str(entry.get("hexcode", "")).upper().strip()
        emoji = entry.get("emoji")
        label = entry.get("label")
        if not hexcode or not isinstance(emoji, str) or not emoji or not isinstance(label, str):
            continue

        shortcodes: list[str] = []
        seen: set[str] = set()
        for src in (sc_eb.get(hexcode), sc_gh.get(hexcode)):
            for code in normalize_codes(src):
                clean = code.strip().lower()
                if clean and clean not in seen:
                    seen.add(clean)
                    shortcodes.append(clean)

        tags_raw = entry.get("tags") or []
        tags = [str(t).strip().lower() for t in tags_raw if isinstance(t, str) and t.strip()]

        order = entry.get("order")
        if not isinstance(order, int):
            order = 999999

        rec: dict = {
            "h": hexcode,
            "e": emoji,
            "n": label,
            "s": shortcodes,
            "t": tags,
            "g": group,
            "o": order,
        }
        sk = extract_skins(entry)
        if sk is not None:
            rec["sk"] = sk
        records.append(rec)

    records.sort(key=lambda r: (r["o"], r["h"]))
    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    tmp = OUT_PATH.with_suffix(".json.tmp")
    with tmp.open("w", encoding="utf-8") as f:
        json.dump(records, f, ensure_ascii=False, separators=(",", ":"))
    tmp.replace(OUT_PATH)
    print(f"Wrote {len(records)} emojis to {OUT_PATH} ({OUT_PATH.stat().st_size} bytes)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
