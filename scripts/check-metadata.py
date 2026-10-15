#!/usr/bin/env python3
"""Checks docs/AppStore/metadata.md against App Store Connect limits and the App Review rules the project follows
(Guideline 2.3.7, B4.11, B10.2): field lengths, no other apps' names in keywords or subtitle, no price amounts, and URLs that match AppConstants. Exits non-zero with a list of problems."""

import pathlib
import re
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
METADATA = ROOT / "docs/AppStore/metadata.md"
CONSTANTS = ROOT / "Sources/RPCore/AppConstants.swift"
REVIEW_NOTES = ROOT / "docs/AppStore/review_notes.md"
REVIEW_NOTES_LIMIT = 4000

LIMITS = {
    "Name": 30,
    "Subtitle": 30,
    "Promotional Text": 170,
    "Description": 4000,
    "Keywords": 100,
    "What's New in This Version": 4000,
}
# Other apps and platforms that must not appear in the name, subtitle or keywords.
FORBIDDEN_IN_SHORT_FIELDS = [
    "postman", "bruno", "insomnia", "paw", "httpie", "hoppscotch", "yaak", "rapidapi", "android", "windows",
]
FORBIDDEN_EVERYWHERE = ["android", "windows", "beta", "coming soon", "test flight", "testflight"]


def fields(text):
    """Maps each '## Heading' to the first ```text block that follows it."""
    result = {}
    for match in re.finditer(r"^## (.+?)\n(.*?)(?=^## |\Z)", text, flags=re.S | re.M):
        block = re.search(r"```text\n(.*?)\n```", match.group(2), flags=re.S)
        if block:
            result[match.group(1).strip()] = block.group(1)
    return result


def review_notes():
    """Returns the App Review notes: the text between the two '---' lines of review_notes.md."""
    match = re.search(r"\n---\n\n(.*?)\n\n---\n", REVIEW_NOTES.read_text(encoding="utf-8"), flags=re.S)
    return match.group(1) if match else None


def main():
    problems = []
    notes = review_notes()
    if notes is None:
        problems.append("review_notes.md: notes must sit between two '---' lines")
    elif len(notes) > REVIEW_NOTES_LIMIT:
        problems.append(f"App Review notes are {len(notes)} characters (limit {REVIEW_NOTES_LIMIT})")
    values = fields(METADATA.read_text(encoding="utf-8"))
    for name, limit in LIMITS.items():
        value = values.get(name)
        if value is None:
            problems.append(f"missing field: {name}")
            continue
        if len(value) > limit:
            problems.append(f"{name} is {len(value)} characters (limit {limit})")
        lowered = value.lower()
        for word in FORBIDDEN_EVERYWHERE:
            if word in lowered:
                problems.append(f"{name} contains '{word}'")
    for name in ("Name", "Subtitle", "Keywords"):
        lowered = values.get(name, "").lower()
        for word in FORBIDDEN_IN_SHORT_FIELDS:
            if re.search(rf"\b{re.escape(word)}\b", lowered):
                problems.append(f"{name} contains another app's or platform's name: '{word}'")
    keywords = values.get("Keywords", "")
    if ", " in keywords:
        problems.append("Keywords: remove spaces after commas (they count toward the limit)")
    words = [w for w in keywords.split(",") if w]
    if len(set(words)) != len(words):
        problems.append("Keywords: duplicates")
    name_words = set(re.findall(r"[a-z0-9]+", values.get("Name", "").lower()))
    for word in words:
        if word in name_words:
            problems.append(f"Keywords: '{word}' is already in the name (wasted characters)")
    # RequestPad is free: no field may mention a price amount.
    for name, value in values.items():
        if re.search(r"[$€£¥]\s?\d|\d+[.,]\d{2}\s?(usd|eur)", value, flags=re.I):
            problems.append(f"{name} mentions a price amount (prices come from the App Store)")
    constants = CONSTANTS.read_text(encoding="utf-8")
    for url in re.findall(r"https://requestpad\.eonix\.lk/[a-z]+", METADATA.read_text(encoding="utf-8")):
        if url not in constants:
            problems.append(f"URL not in AppConstants: {url}")
    if problems:
        print("Metadata problems:", *problems, sep="\n  ")
        return 1
    print(f"Metadata OK ({', '.join(f'{k}: {len(values[k])}' for k in LIMITS)}, Review Notes: {len(notes)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
