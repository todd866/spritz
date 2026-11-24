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
    "couldn't", "shouldn't", "ain't", "I'm", "I've", "I'll", "I'd",
    "you're", "you've", "you'll", "you'd", "we're", "we've", "we'll",
    "we'd", "they're", "they've", "they'll", "they'd", "he's", "she's",
    "it's", "that's", "there's", "here's", "what's", "who's", "let's",
]

TOP_CONTRACTIONS = [
    "don't", "I'm", "it's", "that's", "didn't", "can't", "won't",
    "you're", "we're", "they're", "I've", "I'll", "I'd", "what's",
    "there's", "isn't", "doesn't", "wasn't", "haven't", "wouldn't",
    "couldn't", "shouldn't", "he's", "she's", "let's", "here's", "who's",
]

CASUAL_WORDS = [
    "fuck", "fucking", "fucked", "fucker", "unfuck", "shit", "shitty",
    "bullshit", "damn", "crap", "pissed", "bloody", "arse", "bugger",
    "wanker", "stoked", "keen", "legit", "vibe", "vibes", "bottleo",
    "bogan", "ta", "nah", "yep", "nope", "gonna", "wanna", "gotta",
    "kinda", "sorta", "dunno", "perth", "sydney", "melbourne",
    "brisbane", "adelaide", "fremantle", "australia", "aussie", "wifi",
    "emoji", "emojis",
]

NOISE_WORDS = {
    # Apostrophe split fragments from subtitle tokenizers
    "don", "didn", "doesn", "isn", "aren", "wasn", "weren", "haven",
    "hasn", "hadn", "wouldn", "couldn", "shouldn", "ain", "ll", "ve", "re",
    # Subtitle hesitation / non-word interjections
    "uh", "um", "uhh", "umm", "hmm", "hmmm", "ooh", "mmm", "aah",
    "shh", "heh", "yeh", "ya", "pff", "bah", "bleh", "ooo", "aaa", "eee",
}

BAD_SINGLETONS = set("bcdefghjklmnopqrstuvwxyz")
PROMOTE_RANK = 25
OVERLAY_INSERT_RANK = 2500


def curate_words(raw_words: list[str]) -> list[str]:
    """Normalize, strip fragments/noise, promote common contractions, and inject overlays."""
    contraction_exact = {c.lower(): c for c in CONTRACTIONS}
    top_contract_lowers = {c.lower() for c in TOP_CONTRACTIONS}

    cleaned: list[str] = []
    seen_lower: set[str] = set()
    for w in raw_words:
        lw = w.strip().lower()
        if not lw or not WORD_RE.match(lw) or len(lw) > 20:
            continue
        if len(lw) == 1 and lw in BAD_SINGLETONS:
            continue
        if "'" in lw and lw.endswith("'s") and len(lw) <= 3:
            continue
        if lw in NOISE_WORDS:
            continue
        if lw in top_contract_lowers:
            continue
        if lw in seen_lower:
            continue
        seen_lower.add(lw)
        if lw == "i":
            cleaned.append("I")
        elif lw in contraction_exact:
            cleaned.append(contraction_exact[lw])
        else:
            cleaned.append(lw)

    promoted: list[str] = []
    for c in TOP_CONTRACTIONS:
        lc = c.lower()
        if lc not in seen_lower:
            seen_lower.add(lc)
            promoted.append(c)

    promo_at = min(PROMOTE_RANK, len(cleaned))
    with_promoted = cleaned[:promo_at] + promoted + cleaned[promo_at:]

    missing_overlays: list[str] = []
    for group in (CONTRACTIONS, AU_UK_WORDS, TECH_WORDS, MEDICAL_WORDS, CASUAL_WORDS):
        for w in group:
            lw = w.lower()
            if lw in NOISE_WORDS:
                continue
            if lw not in seen_lower:
                seen_lower.add(lw)
                missing_overlays.append(w)

    insert_at = min(OVERLAY_INSERT_RANK, len(with_promoted))
    return with_promoted[:insert_at] + missing_overlays + with_promoted[insert_at:]


def main() -> int:
    print(f"Downloading {SOURCE_URL}...")
    req = urllib.request.Request(SOURCE_URL, headers={"User-Agent": "SpritzLexiconFetcher/1.0"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        raw = resp.read().decode("utf-8", errors="replace")

    raw_words: list[str] = []
    for line in raw.splitlines():
        parts = line.strip().split()
        if parts:
            raw_words.append(parts[0].lower())
        if len(raw_words) >= 24000:
            break

    final_words = curate_words(raw_words)

    OUT_PATH.parent.mkdir(parents=True, exist_ok=True)
    OUT_PATH.write_text("\n".join(final_words) + "\n", encoding="utf-8")
    size_kb = OUT_PATH.stat().st_size / 1024.0
    print(f"Wrote {len(final_words)} words -> {OUT_PATH} ({size_kb:.1f} KB)")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
