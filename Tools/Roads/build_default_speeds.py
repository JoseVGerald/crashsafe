"""Builds CrashSafe/Resources/Roads/default_speeds.json from the osm-legal-default-speeds dataset
(BSD-3-Clause, https://github.com/westnordost/osm-legal-default-speeds): the legal default speed limit,
in mph, for each kind of road in 242 countries and US states / regions, so an untagged road gets the
limit that actually applies where the car is instead of one US-wide guess.

    curl -o Backend/datasets/default-speeds/legal_default_speeds.json \
      https://raw.githubusercontent.com/westnordost/osm-legal-default-speeds/master/demo/distribution/legal_default_speeds.json
    python3 -I Tools/Roads/build_default_speeds.py Backend/datasets/default-speeds/legal_default_speeds.json \
      CrashSafe/Resources/Roads/default_speeds.json
"""
import json, re, sys

CATEGORIES = [  # (our category, keywords in the dataset's road-type name), most specific first
    ("schoolZone", ["school"]),
    ("livingStreet", ["living street", "pedestrian zone", "woonerf", "shared"]),
    ("alley", ["alley", "service"]),
    ("residential", ["residential"]),
    ("business", ["business", "commercial"]),
    ("motorway", ["motorway", "freeway", "interstate", "autobahn", "autopista", "autoroute", "autostrada"]),
    ("expressway", ["expressway", "motorroad", "dual carriageway", "divided"]),
    ("urban", ["urban", "restricted road", "built-up", "in town"]),
    ("rural", ["rural"]),
]

def mph(value):
    if value is None:
        return None
    v = value.strip().lower()
    if v in ("walk", "walking"):
        return 5
    m = re.match(r"([\d.]+)\s*(mph)?", v)
    if not m:
        return None
    n = float(m.group(1))
    return round(n) if m.group(2) else round(n * 0.621371)

def category(name):
    if not name:
        return "default"
    n = name.lower().split(":")[-1].strip() if ":" in name else name.lower()
    for cat, words in CATEGORIES:
        if any(w in n for w in words):
            return cat
    return None

src, out = sys.argv[1], sys.argv[2]
data = json.load(open(src, encoding="utf-8"))
table = {}
for code, entries in data["speedLimitsByCountryCode"].items():
    row = {}
    for entry in entries:
        cat = category(entry.get("name"))
        limit = mph((entry.get("tags") or {}).get("maxspeed"))
        if cat and limit and cat not in row:
            row[cat] = limit
    if row:
        table[code] = row
json.dump({"source": "osm-legal-default-speeds (BSD-3-Clause), " + data.get("meta", {}).get("source", ""),
           "regions": table}, open(out, "w"), separators=(",", ":"), sort_keys=True)
print(len(table), "regions;", "US-WA", table.get("US-WA"), "US-OR", table.get("US-OR"), "DE", table.get("DE"), "GB", table.get("GB"))
