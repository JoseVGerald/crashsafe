import json
import tempfile
import threading
import unittest
import urllib.request
from pathlib import Path

import rag
import roads

FIXTURE = Path(__file__).resolve().parents[3] / "CoreTests" / "Fixtures" / "overpass_portland_i5.json"


class RoadTileTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.calls = []
        elements = json.loads(FIXTURE.read_text())["elements"]
        self.ways = [w for w in (roads.to_way(e) for e in elements) if w]

        def fake_fetch(bbox):
            self.calls.append(bbox)
            return self.ways
        self.tiles = roads.RoadTiles(self.temp.name, fetch=fake_fetch)

    def tearDown(self):
        self.temp.cleanup()

    def test_fetches_each_tile_once_then_serves_from_disk(self):
        first = self.tiles.near(45.5384, -122.6705, 700)
        self.assertGreater(len(first["ways"]), 100)
        self.assertEqual(first["cached_tiles"], 0)
        fetched = len(self.calls)
        second = self.tiles.near(45.5384, -122.6705, 700)
        self.assertEqual(len(self.calls), fetched)          # no new network calls
        self.assertEqual(second["cached_tiles"], second["tiles"])
        i5 = next(w for w in second["ways"] if w["ref"] == "I 5" and w["highway"] == "motorway")
        self.assertEqual(i5["maxspeed"], "50 mph")
        self.assertEqual(set(i5), {"id", "highway", "maxspeed", "maxspeedForward", "maxspeedBackward",
                                   "oneway", "name", "ref", "points"})  # the app's RoadWay

    def test_offline_returns_only_what_is_cached(self):
        result = self.tiles.near(45.5384, -122.6705, 700, allow_fetch=False)
        self.assertEqual(result["ways"], [])
        self.assertEqual(result["missing_tiles"], result["tiles"])

    def test_validation(self):
        with self.assertRaises(ValueError):
            self.tiles.near(95, 0, 700)
        with self.assertRaises(ValueError):
            self.tiles.near(45, -122, 10_000)
        with self.assertRaises(ValueError):
            self.tiles.along([[45, -122]] * 3000)

    def test_http_endpoint(self):
        engine_dir = tempfile.TemporaryDirectory()
        corpus = Path(engine_dir.name) / "c.json"
        corpus.write_text(json.dumps(rag.read_json(rag.ROOT / "knowledge" / "corpus.json")))
        db = Path(engine_dir.name) / "m.sqlite3"
        rag.ingest(corpus, db)
        engine = rag.Engine(db)
        original = roads.RoadTiles.__init__
        tiles = self.tiles

        def patched(self_, directory, fetch=None, max_age_days=60):
            original(self_, tiles.dir, fetch=tiles.fetch)
        roads.RoadTiles.__init__ = patched
        server = rag.make_server(engine, 0)
        threading.Thread(target=server.serve_forever, daemon=True).start()
        try:
            url = f"http://127.0.0.1:{server.server_port}/v1/roads?lat=45.5384&lon=-122.6705&radius=500"
            with urllib.request.urlopen(url, timeout=10) as r:
                body = json.loads(r.read())
            self.assertIn("OpenStreetMap", body["attribution"])
            self.assertTrue(any(w["maxspeed"] == "50 mph" for w in body["ways"]))
            req = urllib.request.Request(f"http://127.0.0.1:{server.server_port}/v1/roads/route",
                                         json.dumps({"path": [[45.5384, -122.6705], [45.5420, -122.6730]]}).encode(),
                                         {"Content-Type": "application/json"})
            with urllib.request.urlopen(req, timeout=10) as r:
                self.assertGreater(len(json.loads(r.read())["ways"]), 0)
        finally:
            roads.RoadTiles.__init__ = original
            server.shutdown(); server.server_close(); engine.close(); engine_dir.cleanup()


if __name__ == "__main__":
    unittest.main()
