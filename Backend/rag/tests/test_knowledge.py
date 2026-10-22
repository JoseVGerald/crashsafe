"""Corpus integrity and offline synchronization regression checks."""
import datetime as dt
import json
import unittest
from pathlib import Path
import rag
import sync_knowledge

class KnowledgeTests(unittest.TestCase):
    def setUp(self):
        self.corpus = rag.read_json(rag.ROOT / "knowledge/corpus.json")

    def test_generated_offline_and_catalog_are_current(self):
        for target, expected in sync_knowledge.outputs(self.corpus).items():
            with self.subTest(target=target.name):
                self.assertEqual(target.read_text(encoding="utf-8"), expected)

    def test_source_registry_has_unique_https_links(self):
        sources = self.corpus["sources"]
        self.assertEqual(len({s["id"] for s in sources}), len(sources))
        self.assertEqual(len({s["url"] for s in sources}), len(sources))
        self.assertTrue(all(s["url"].startswith("https://") for s in sources))

    def test_expansion_has_review_sections_and_bounded_lifetime(self):
        for card in self.corpus["cards"]:
            if card.get("verified") != "2026-10-22":
                continue
            with self.subTest(card=card["id"]):
                self.assertEqual(card["professional_review"], "pending")
                lifetime = dt.date.fromisoformat(card["expires"]) - dt.date.fromisoformat(card["verified"])
                self.assertLessEqual(lifetime.days, 90)
                sources = {s["id"]: s for s in self.corpus["sources"]}
                for sid in card["source_ids"]:
                    self.assertEqual(sources[sid]["access_status"], "Full page")
                    self.assertTrue(sources[sid]["sections"])

    def test_effective_version_and_state_deadlines_remain_distinct(self):
        cards = {c["id"]: c for c in self.corpus["cards"]}
        self.assertIn("October 18, 2026", cards["WA_INSPECTION"]["body"])
        self.assertIn("72 hours", cards["OR_REPORT"]["body"])
        self.assertIn("10 days", cards["CA_REPORT"]["body"])
        self.assertIn("$1,000", cards["CA_REPORT"]["body"])
        self.assertNotIn("$750", cards["CA_REPORT"]["body"])

    def test_child_support_does_not_force_recounting_or_promise_recovery(self):
        body = next(c["body"] for c in self.corpus["cards"] if c["id"] == "CHILD_SUPPORT")
        self.assertIn("Do not force", body)
        self.assertIn("promise", body)

if __name__ == "__main__":
    unittest.main()
