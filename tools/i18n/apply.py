"""Writes the German translations from de.py into the app's string catalog and reports gaps.

    python3 -I tools/i18n/apply.py apps/mac/App/Localizable.xcstrings

Exit code 1 when a key in the catalog has no German, or a translation drops or adds a format
specifier, so CI can stop a release with an untranslated sentence.
"""
import json, os, re, sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from de import DE  # noqa: E402

SPEC = re.compile(r"%(?:\d+\$)?(?:lld|ld|d|@|f|\.\d+f)")


def specifiers(text):
    return sorted(re.sub(r"\d+\$", "", s) for s in SPEC.findall(text))


path = sys.argv[1]
catalog = json.load(open(path, encoding="utf-8"))
missing, mismatched = [], []
for key, entry in catalog["strings"].items():
    if entry.get("shouldTranslate") is False:
        continue
    german = DE.get(key)
    if german is None:
        missing.append(key)
        continue
    if specifiers(key) != specifiers(german):
        mismatched.append(key)
    entry.setdefault("localizations", {})["de"] = {"stringUnit": {"state": "translated", "value": german}}
    entry.pop("extractionState", None) if entry.get("extractionState") == "stale" else None

json.dump(catalog, open(path, "w", encoding="utf-8"), ensure_ascii=False, indent=2, sort_keys=True)
open(path, "a").write("\n")
for key in missing:
    print(f"missing German: {key!r}")
for key in mismatched:
    print(f"format specifiers differ: {key!r}")
print(f"{len(catalog['strings'])} strings, {len(missing)} missing, {len(mismatched)} mismatched")
sys.exit(1 if missing or mismatched else 0)
