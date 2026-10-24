#!/usr/bin/env python3
"""Guard the fork's promise that usage telemetry is disabled.

This intentionally checks the client source rather than the removed upstream
stats worker. The fork keeps compatibility call sites, but must not collect,
upload, or ask for consent to send usage data.
"""
from __future__ import annotations

import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
TELEMETRY = ROOT / "Sources" / "Mojito" / "Telemetry"


def fail(message: str) -> None:
    print(f"❌ {message}")


def body(text: str, signature: str) -> str:
    start = text.index(signature)
    brace = text.index("{", start)
    depth = 0
    for index in range(brace, len(text)):
        if text[index] == "{":
            depth += 1
        elif text[index] == "}":
            depth -= 1
            if depth == 0:
                return text[brace + 1:index]
    raise ValueError(f"unterminated body for {signature}")


def main() -> int:
    store_path = TELEMETRY / "TelemetryStore.swift"
    uploader_path = TELEMETRY / "TelemetryUploader.swift"
    consent_path = TELEMETRY / "TelemetryConsent.swift"
    for path in (store_path, uploader_path, consent_path):
        if not path.exists():
            sys.exit(f"missing file: {path}")

    store = store_path.read_text()
    uploader = uploader_path.read_text()
    consent = consent_path.read_text()
    failures: list[str] = []

    enabled = body(store, "static var isEnabled")
    if not re.fullmatch(r"\s*(?:return\s+)?false\s*", enabled):
        failures.append("TelemetryStore.isEnabled is not unconditionally false")

    upload = body(uploader, "func uploadIfDue()")
    if upload.strip():
        failures.append("TelemetryUploader.uploadIfDue() is not a no-op")

    if not re.search(r"hasBeenSeen: Bool\s*\{\s*true\s*\}", consent):
        failures.append("TelemetryConsent.hasBeenSeen is not permanently true")
    present = body(consent, "static func presentIfNeeded()")
    if present.strip():
        failures.append("TelemetryConsent.presentIfNeeded() is not a no-op")

    forbidden = re.compile(r"URLSession|URLRequest|dataTask|httpMethod|stats\.mojito|telemetry\.wells", re.IGNORECASE)
    for label, text in (("TelemetryStore", store), ("TelemetryUploader", uploader), ("TelemetryConsent", consent)):
        if forbidden.search(text):
            failures.append(f"{label} contains a telemetry networking path")

    if failures:
        for failure in failures:
            fail(failure)
        return 1

    print("✓ fork telemetry disabled — no recording, upload, consent prompt, or telemetry endpoint")
    return 0


if __name__ == "__main__":
    sys.exit(main())
