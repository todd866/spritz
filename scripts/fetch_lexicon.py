#!/usr/bin/env python3
"""Fetch and curate an MIT-licensed English frequency lexicon for Spritz."""

from __future__ import annotations

import pathlib
import re
import urllib.request

SOURCE_URL = (
    "https://raw.githubusercontent.com/hermitdave/FrequencyWords/master/content/2018/en/en_50k.txt"
)
REPO_ROOT = pathlib.Path(__file__).resolve().parent.parent
OUT_PATH = REPO_ROOT / "crates" / "spritz-core" / "data" / "lexicon-en.txt"

WORD_RE = re.compile(r"^[a-z]+(?:'[a-z]+)?$")

AU_UK_WORDS = [
    "colour", "colours", "coloured", "colouring", "behaviour", "behaviours",
    "behavioural", "organise", "organised", "organising", "organisation",
    "centre", "centres", "centred", "programme", "programmes", "programmed",
    "favour", "favours", "favoured", "favourite", "favourites", "honour",
    "honours", "honoured", "honourable", "neighbour", "neighbours",
    "neighbouring", "neighbourhood", "travelling", "travelled", "traveller",
    "cancelled", "cancelling", "cancellation", "licence", "licenced",
    "practise", "practised", "practising", "defence", "offence", "grey",
    "tyre", "tyres", "kerb", "aluminium", "realise", "realised", "realising",
    "recognise", "recognised", "recognising", "analyse", "analysed",
    "analysing", "apologise", "apologised", "apologising", "customise",
    "customised", "customising", "optimise", "optimised", "optimising",
    "prioritise", "prioritised", "prioritising", "manoeuvre", "manoeuvres",
    "sceptical", "judgement", "fulfil", "fulfilled", "fulfilling", "enrol",
    "enrolled", "skilful", "kilometre", "kilometres", "litre", "litres",
    "metre", "metres", "catalogue", "dialogue", "cheque", "pyjamas", "queue",
    "queued", "queueing", "fortnight", "rubbish", "petrol", "footpath",
    "mate", "mates", "arvo", "brekkie", "servo", "reckon", "reckoned",
    "heaps", "chuffed", "cheers", "bloke", "tradie", "ambo", "rego",
]

MEDICAL_WORDS = [
    "dyspnoea", "oedema", "oedematous", "anaesthesia", "anaesthetic",
    "anaesthetist", "paediatric", "paediatrics", "haemoglobin", "haemorrhage",
    "haematology", "haematuria", "haemoptysis", "oesophagus", "oesophageal",
    "diarrhoea", "foetus", "foetal", "gynaecology", "orthopaedic", "leukaemia",
    "anaemia", "anaemic", "ischaemia", "ischaemic", "hyperglycaemia",
    "hypoglycaemia", "hyponatraemia", "hyperkalaemia", "hypokalaemia",
    "tachycardia", "bradycardia", "arrhythmia", "fibrillation",
    "hypertension", "hypotension", "pneumonia", "pneumothorax", "embolism",
    "thrombosis", "infarction", "auscultation", "palpation", "percussion",
    "erythema", "pruritus", "syncope", "vertigo", "nausea", "emesis",
    "dysphagia", "dysuria", "melaena", "jaundice", "cyanosis", "paracetamol",
    "ibuprofen", "amoxicillin", "augmentin", "ceftriaxone", "vancomycin",
    "meropenem", "metronidazole", "ondansetron", "metoclopramide",
    "salbutamol", "prednisolone", "dexamethasone", "frusemide", "furosemide",
    "enoxaparin", "apixaban", "warfarin", "aspirin", "clopidogrel",
    "atorvastatin", "metformin", "insulin", "morphine", "oxycodone",
    "fentanyl", "lignocaine", "adrenaline", "noradrenaline", "troponin",
    "lactate", "creatinine", "bilirubin", "electrolytes", "spirometry",
    "echocardiogram", "laparoscopy", "endoscopy", "colonoscopy",
    "bronchoscopy", "prophylaxis", "contraindicated", "aetiology",
    "comorbidity", "comorbidities", "exacerbation", "idiopathic",
    "iatrogenic", "subcutaneous", "intravenous", "intramuscular",
    "sublingual", "nebulised",
]

TECH_WORDS = [
    "rust", "swift", "swiftui", "uikit", "xcode", "xcodegen", "cargo",
    "github", "git", "commit", "commits", "rebase", "async", "await",
    "struct", "structs", "enum", "enums", "trait", "traits", "mutex",
    "tokio", "serde", "wasm", "ffi", "xcframework", "macos", "ios",
    "iphone", "ipad", "bluetooth", "tailscale", "docker", "kubernetes",
    "postgres", "sqlite", "redis", "graphql", "oauth", "jwt", "regex",
    "json", "toml", "yaml", "markdown", "tmux", "zsh", "neovim", "homebrew",
    "launchd", "localhost", "ssh", "api", "cli", "sdk", "llm", "chatgpt",
    "gemini", "spritz",
]

CONTRACTIONS = [
    "don't", "can't", "won't", "didn't", "doesn't", "isn't", "aren't",
    "wasn't", "weren't", "haven't", "hasn't", "hadn't", "wouldn't",
    "couldn't", "shouldn't", "I'm", "I've", "I'll", "I'd", "you're",
    "you've", "you'll", "you'd", "we're", "we've", "we'll", "we'd",
    "they're", "they've", "they'll", "they'd", "he's", "she's", "it's",
    "that's", "there's", "here's", "what's", "who's", "let's",
]

BAD_SINGLETONS = set("bcdefghjklmnopqrstuvwxyz")
OVERLAY_INSERT_RANK = 2500


def main() -> int:
    print(f"Downloading {SOURCE_URL}...")
    req = urllib.request.Request(SOURCE_URL, headers={"User-Agent": "SpritzLexiconFetcher/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode("utf-8", errors="replace")

    base_words: list[str] = []
    seen_lower: set[str] = set()

    for line in raw.splitlines():
        parts = line.strip().split()
        if not parts:
            continue
        word = parts[0].lower()
        if not WORD_RE.match(word):
            continue
        if len(word) > 20:
            continue
        if len(word) == 1 and word in BAD_SINGLETONS:
            continue
        if "'" in word and word.endswith("'s") and len(word) <= 3:
            continue
        if word in seen_lower:
            continue
        seen_lower.add(word)
        base_words.append(word)
        if len(base_words) >= 22000:
            break

    # Fix casing for first-person pronoun and contractions.
    contraction_exact = {c.lower(): c for c in CONTRACTIONS}
    normalized: list[str] = []
    for w in base_words:
        if w == "i":
            normalized.append("I")
        elif w in contraction_exact:
            normalized.append(contraction_exact[w])
        else:
            normalized.append(w)

    missing_overlays: list[str] = []
    for group in (CONTRACTIONS, AU_UK_WORDS, TECH_WORDS, MEDICAL_WORDS):
        for w in group:
            lw = w.lower()
            if lw not in seen_lower:
                seen_lower.add(lw)
                missing_overlays.append(w)

    insert_at = min(OVERLAY_INSERT_RANK, len(normalized))
    final_words = normalized[:insert_at] + missing_overlays + normalized[insert_at:]

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text("\n".join(final_words) + "\n", encoding="utf-8")
    size_kb = OUT_PATH.stat().st_size / 1024.0
    print(f"Wrote {len(final_words)} words ({len(missing_overlays)} overlay additions) -> {OUT_PATH} ({size_kb:.1f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
