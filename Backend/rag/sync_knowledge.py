"""Generate offline Swift evidence and a readable source catalog from the corpus."""
import argparse
import json
from pathlib import Path

ROOT = Path(__file__).resolve().parent
SWIFT = ROOT.parents[1] / "CrashSafe/Services/Assistant/AssistantService.swift"
BEGIN = "    // BEGIN GENERATED KNOWLEDGE"
END = "    // END GENERATED KNOWLEDGE"

def swift_string(value):
    # Swift interpolation must not interpret editorial text as code.
    return json.dumps(value, ensure_ascii=False)

def render_swift(corpus):
    rows = [BEGIN, "    private static let cards: [LocalKnowledgeCard] = ["]
    active = [c for c in corpus["cards"] if c["status"] in ("source_verified", "clinician_approved")]
    for c in active:
        fields = [k + ": " + swift_string(c[k]) for k in ("id", "title", "terms", "body", "scope", "stage", "expires")]
        fields.append("sources: [" + ", ".join(swift_string(s) for s in c["source_ids"]) + "]")
        rows.append("        LocalKnowledgeCard(" + ", ".join(fields) + "),")
    rows += ["    ]", "    private static let sourceLinks: [String: String] = ["]
    for s in corpus["sources"]:
        rows.append("        " + swift_string(s["id"]) + ": " + swift_string(s["title"] + ": " + s["url"]) + ",")
    return "\n".join(rows + ["    ]", END])

def render_catalog(corpus):
    rows = ["# Evidence source catalog", "", "Generated from corpus.json. Editorial source verification is not professional approval.",
            "Search-only and discovery records are research leads; they do not independently authorize advice.",
            "Original REFERENCE_GUIDE.md is historical background. This catalog describes the current corpus.", ""]
    for s in corpus["sources"]:
        cards = [c for c in corpus["cards"] if s["id"] in c["source_ids"]]
        rows += ["## " + s["id"] + " — " + s["title"], "",
                 "- Publisher: " + s["publisher"],
                 "- URL: " + s["url"],
                 "- Scope: " + s["jurisdiction"],
                 "- Access: " + s["access_status"] + "; checked " + s["checked"],
                 "- Sections reviewed: " + s.get("sections", "See original reference guide and card bodies; detailed audit pending."),
                 "- Professional review: " + s["professional_review"],
                 "- Cards: " + (", ".join(c["id"] + " (" + c["status"] + ")" for c in cards) or "Research reference only"), ""]
    rows += ["## Active answer cards", ""]
    for c in corpus["cards"]:
        if c["status"] not in ("source_verified", "clinician_approved"):
            continue
        rows += ["### " + c["id"] + " — " + c["title"], "",
                 c["body"], "", "Scope: " + c["scope"] + "; stage: " + c["stage"] +
                 "; sources: " + ", ".join(c["source_ids"]) + "; expires: " + c["expires"] + ".", ""]
    return "\n".join(rows)

def outputs(corpus):
    text = SWIFT.read_text(encoding="utf-8")
    start = text.index(BEGIN)
    stop = text.index(END, start) + len(END)
    return {SWIFT: text[:start] + render_swift(corpus) + text[stop:],
            ROOT / "knowledge/SOURCE_CATALOG.md": render_catalog(corpus)}

def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()
    corpus = json.loads((ROOT / "knowledge/corpus.json").read_text(encoding="utf-8"))
    stale = []
    for target, expected in outputs(corpus).items():
        actual = target.read_text(encoding="utf-8") if target.exists() else None
        if actual != expected:
            if args.check:
                stale.append(str(target))
            else:
                target.write_text(expected, encoding="utf-8")
    if stale:
        raise SystemExit("Generated knowledge is stale: " + ", ".join(stale))
    print("Generated knowledge is current." if args.check else "Offline cards and catalog synchronized.")

if __name__ == "__main__":
    main()
