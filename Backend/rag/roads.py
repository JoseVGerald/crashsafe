"""Speed-limit road data for the app, cached in ~1 km tiles.

The app needs the roads around the car with their OpenStreetMap `maxspeed` tags. Public Overpass
servers are free but often slow (30-60 s) or down, so the backend fetches each tile once, keeps it on
disk, and serves it instantly afterwards. `python rag.py prefetch-roads --bbox S,W,N,E` warms a region
ahead of time (e.g. the team's town before a demo).

Output matches the app's `RoadWay` (CrashSafe/Services/Intelligence/RoadMatching.swift).
Only road data is stored: no request, position or time is logged or kept.
Data © OpenStreetMap contributors, ODbL.
"""
from __future__ import annotations

import json
import math
import time
import urllib.parse
import urllib.request
from pathlib import Path

CELL = 0.01  # degrees (~1.1 km north-south)
MARGIN = 0.002  # overlap so roads near a tile edge are in both tiles
HIGHWAYS = ("^(motorway|trunk|primary|secondary|tertiary|unclassified|residential|living_street|"
            "motorway_link|trunk_link|primary_link|secondary_link|tertiary_link)$")
SERVERS = ("https://overpass-api.de/api/interpreter",
           "https://overpass.private.coffee/api/interpreter",
           "https://overpass.kumi.systems/api/interpreter")
USER_AGENT = "CrashSafe/0.1 (Congressional App Challenge student project)"


def cell_of(lat, lon):
    return math.floor(lat / CELL), math.floor(lon / CELL)


def cell_bbox(cell):
    ix, iy = cell
    return (ix * CELL - MARGIN, iy * CELL - MARGIN, (ix + 1) * CELL + MARGIN, (iy + 1) * CELL + MARGIN)


def cells_near(lat, lon, radius_m):
    dlat = radius_m / 111_320
    dlon = radius_m / (111_320 * max(math.cos(math.radians(lat)), 0.01))
    (a, b), (c, d) = cell_of(lat - dlat, lon - dlon), cell_of(lat + dlat, lon + dlon)
    return [(i, j) for i in range(a, c + 1) for j in range(b, d + 1)]


def to_way(element):
    tags = element.get("tags") or {}
    geometry = element.get("geometry") or []
    if element.get("type") != "way" or "highway" not in tags or len(geometry) < 2:
        return None
    return {"id": element["id"], "highway": tags["highway"], "maxspeed": tags.get("maxspeed"),
            "maxspeedForward": tags.get("maxspeed:forward"), "maxspeedBackward": tags.get("maxspeed:backward"),
            "oneway": tags.get("oneway"), "name": tags.get("name"), "ref": tags.get("ref"),
            "points": [{"lat": p["lat"], "lon": p["lon"]} for p in geometry]}


def overpass_fetch(bbox, servers=SERVERS, timeouts=(60, 40, 40), opener=urllib.request.urlopen):
    s, w, n, e = bbox
    query = f'[out:json][timeout:90];way({s:.4f},{w:.4f},{n:.4f},{e:.4f})[highway~"{HIGHWAYS}"];out tags geom qt;'
    body = urllib.parse.urlencode({"data": query}).encode()
    error = None
    for server, timeout in zip(servers, timeouts):
        try:
            req = urllib.request.Request(server, body, {"User-Agent": USER_AGENT,
                                                        "Content-Type": "application/x-www-form-urlencoded"})
            with opener(req, timeout=timeout) as r:
                data = json.loads(r.read())
            return [w for w in (to_way(x) for x in data.get("elements", [])) if w]
        except Exception as exc:  # next server
            error = exc
    raise RuntimeError(f"All Overpass servers failed: {error}")


class RoadTiles:
    def __init__(self, directory, fetch=overpass_fetch, max_age_days=60):
        self.dir = Path(directory)
        self.fetch = fetch
        self.max_age = max_age_days * 86400

    def path(self, cell):
        return self.dir / f"{cell[0]}_{cell[1]}.json"

    def cached(self, cell):
        p = self.path(cell)
        if p.exists() and time.time() - p.stat().st_mtime < self.max_age:
            return json.loads(p.read_text(encoding="utf-8"))
        return None

    def tile(self, cell, allow_fetch=True):
        ways = self.cached(cell)
        if ways is not None or not allow_fetch:
            return ways, True
        ways = self.fetch(cell_bbox(cell))
        self.dir.mkdir(parents=True, exist_ok=True)
        tmp = self.path(cell).with_suffix(".tmp")
        tmp.write_text(json.dumps(ways, separators=(",", ":")), encoding="utf-8")
        tmp.replace(self.path(cell))
        return ways, False

    def near(self, lat, lon, radius_m, allow_fetch=True):
        if not all(type(x) in (int, float) and math.isfinite(x) for x in (lat, lon, radius_m)) \
                or not -90 <= lat <= 90 or not -180 <= lon <= 180 or not 50 <= radius_m <= 3000:
            raise ValueError("lat, lon and a 50-3000 m radius required")
        return self._collect(cells_near(lat, lon, radius_m), allow_fetch)

    def along(self, path, radius_m=150, allow_fetch=True):
        if not isinstance(path, list) or not 1 <= len(path) <= 2000:
            raise ValueError("Expected 1-2000 [lat, lon] points")
        cells = []
        for point in path:
            if not isinstance(point, list) or len(point) != 2 or not all(type(x) in (int, float) and math.isfinite(x) for x in point):
                raise ValueError("Invalid point")
            for c in cells_near(point[0], point[1], radius_m):
                if c not in cells:
                    cells.append(c)
        if len(cells) > 400:
            raise ValueError("Route too long for one request; split it")
        return self._collect(cells, allow_fetch)

    def _collect(self, cells, allow_fetch):
        ways, seen, cached, missing = [], set(), 0, 0
        for cell in cells:
            tile, from_cache = self.tile(cell, allow_fetch)
            if tile is None:
                missing += 1
                continue
            cached += from_cache
            for way in tile:
                if way["id"] not in seen:
                    seen.add(way["id"])
                    ways.append(way)
        return {"ways": ways, "tiles": len(cells), "cached_tiles": cached, "missing_tiles": missing,
                "attribution": "© OpenStreetMap contributors, ODbL"}

    def prefetch(self, bbox, pause=2.0, log=print):
        s, w, n, e = bbox
        (a, b), (c, d) = cell_of(s, w), cell_of(n, e)
        done = 0
        for i in range(a, c + 1):
            for j in range(b, d + 1):
                if self.cached((i, j)) is not None:
                    continue
                for attempt in range(3):
                    try:
                        ways, _ = self.tile((i, j))
                        done += 1
                        log(f"tile {i}_{j}: {len(ways)} roads")
                        break
                    except Exception as exc:
                        log(f"tile {i}_{j}: retry {attempt + 1} ({exc})")
                        time.sleep(10)
                time.sleep(pause)  # be polite to the public servers
        return done
