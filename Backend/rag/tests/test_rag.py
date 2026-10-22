import copy, datetime as dt, json, tempfile, threading, time, unittest, urllib.request, urllib.error
from pathlib import Path
from unittest.mock import patch
import rag

class RagTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        self.corpus=copy.deepcopy(rag.read_json(rag.ROOT/"knowledge"/"corpus.json"))
        # Use test-relative expiry so this suite is reproducible after content retirement.
        for c in self.corpus["cards"]:
            c["expires"]=(dt.date.today()+dt.timedelta(days=30)).isoformat()
        self.path=Path(self.temp.name)/"corpus.json"
        self.path.write_text(json.dumps(self.corpus),encoding="utf-8")
        self.db=Path(self.temp.name)/"test.sqlite3"
        rag.ingest(self.path,self.db); self.engine=rag.Engine(self.db)
    def tearDown(self):
        self.engine.close(); self.temp.cleanup()
    def test_golden_retrieval(self):
        for row in rag.read_json(rag.ROOT/"tests"/"golden.json"):
            with self.subTest(query=row["query"]):
                r=self.engine.retrieve(row["query"],row["jurisdiction"],"followup")
                self.assertIn(row["expected"],[c["id"] for c in r["cards"]])
    def test_unknown_jurisdiction_never_returns_wa(self):
        r=self.engine.retrieve("four day reporting deadline Washington", "UNKNOWN")
        self.assertTrue(all(c["scope"]=="US" for c in r["cards"]))
    def test_other_state_never_returns_wa(self):
        r=self.engine.retrieve("Washington collision report deadline","OR")
        self.assertNotIn("WA_REPORT",[c["id"] for c in r["cards"]])
    def test_expired_not_retrieved(self):
        self.engine.cards["WA_REPORT"]["expires"]="2000-01-01"
        r=self.engine.retrieve("Washington file report days", "WA")
        self.assertNotIn("WA_REPORT",[c["id"] for c in r["cards"]])
    def test_discovery_notes_quarantined(self):
        self.assertNotIn("DRAFT_PIP",self.engine.cards)
        self.assertEqual(len(self.engine.cards),20)
    def test_production_blocks_unreviewed_content(self):
        e=rag.Engine(self.db,production=True)
        try:
            self.assertEqual(e.retrieve("neck injury","WA")["status"],"insufficient_evidence")
            self.assertEqual(e.answer("my car is on fire",stage="active")["status"],"review_required")
        finally: e.close()
    def test_emergency_bypasses_retrieval_and_model(self):
        with patch.object(self.engine,"retrieve",side_effect=AssertionError("must bypass")):
            r=self.engine.answer("my friend is not breathing",stage="active",persona="supportive")
        self.assertEqual(r["status"],"emergency"); self.assertFalse(r["model_used"])
        self.assertEqual(r["dispatch_status"],"not_requested")
    def test_no_panic_diagnosis_for_chest_pain(self):
        r=self.engine.answer("I am panicking and my chest hurts",stage="active")
        self.assertEqual(r["status"],"emergency")
        self.assertNotIn("just anxiety",r["answer"])
    def test_fire_precedes_claims(self):
        self.assertEqual(self.engine.answer("car is on fire, is towing covered?",stage="active")["rule"],"fire")
    def test_historical_question_not_current_emergency(self):
        r=self.engine.answer("Last month my car was on fire",stage="active")
        self.assertNotEqual(r["status"],"emergency")
    def test_negated_unconsciousness(self):
        self.assertNotEqual(self.engine.answer("Nobody is unconscious",stage="active")["status"],"emergency")
    def test_separate_negative_does_not_hide_breathing_emergency(self):
        r=self.engine.answer("Nobody is unconscious but my child is not breathing",stage="active")
        self.assertEqual(r["status"],"emergency")
    def test_historical_clause_does_not_hide_current_emergency(self):
        r=self.engine.answer("Last week I was fine but now I cannot breathe",stage="active")
        self.assertEqual(r["status"],"emergency")
    def test_active_stage_excludes_followup_deadline(self):
        r=self.engine.retrieve("Washington file report days","WA",stage="active")
        self.assertNotIn("WA_REPORT",[c["id"] for c in r["cards"]])
    def test_semantic_timeout_is_bounded(self):
        self.engine.meta["embedding_model"]="test"; self.engine.vectors={"STATEMENT":[1.0,0.0]}
        self.engine.semantic_deadline=.001
        def slow(*args): time.sleep(.05); return [[1.0,0.0]]
        with patch("rag.embed",side_effect=slow):
            started=time.perf_counter()
            r=self.engine.retrieve("recorded statement","WA")
            self.assertLess(time.perf_counter()-started,.04)
            self.assertTrue(r["warnings"]); self.assertFalse(r["semantic_used"])
    def test_structured_flag(self):
        r=self.engine.answer("Help",stage="active",flags={"unresponsive":True})
        self.assertEqual(r["status"],"emergency")
    def test_invalid_flags(self):
        with self.assertRaises(ValueError): self.engine.answer("Hi",flags={"fire":"false"})
    def test_persona_explicit_choice_wins(self):
        r=self.engine.answer("I am scared and overwhelmed",persona="practical",stage="followup")
        self.assertEqual(r["persona"],"practical"); self.assertFalse(r["answer"].startswith("That sounds"))
    def test_cache_isolation(self):
        first=self.engine.retrieve("neck injury","WA")
        first["cards"][0]["body"]="corrupted"
        second=self.engine.retrieve("neck injury","WA")
        self.assertTrue(second["cache_hit"]); self.assertNotEqual(second["cards"][0]["body"],"corrupted")
    def test_context_budget(self):
        r=self.engine.retrieve("insurance recorded statement coverage report photos damage neck injury","WA",max_context_chars=500)
        self.assertLessEqual(len(r["context"]),500)
    def test_unknown_topic_abstains(self):
        r=self.engine.answer("quantum chromodynamics renormalization",stage="followup")
        self.assertEqual(r["status"],"insufficient_evidence")
    def test_bad_query(self):
        for value in ("",None,"x"*4001):
            with self.subTest(value=str(value)[:10]):
                with self.assertRaises(ValueError): self.engine.retrieve(value)
    def test_fts_injection_safe(self):
        self.engine.retrieve('" OR * DELETE FROM cards; --', "WA")
        self.assertEqual(len(self.engine.cards),20)
    def test_invalid_stage(self):
        with self.assertRaises(ValueError): self.engine.answer("help",stage="banana")
    def test_invalid_jurisdiction(self):
        with self.assertRaises(ValueError): self.engine.retrieve("help","Washington")
    def test_model_cannot_invent_advice(self):
        self.engine.llm_model="test"
        with patch("rag.post_local",return_value={"response":json.dumps({"card_ids":["INVENTED"]})}):
            r=self.engine.answer("recorded statement","WA","followup")
        self.assertFalse(r["model_used"]); self.assertIsNotNone(r["warning"])
        self.assertNotIn("INVENTED",r["answer"])
    def test_model_valid_evidence_selection(self):
        self.engine.llm_model="test"
        with patch("rag.post_local",return_value={"response":json.dumps({"card_ids":["STATEMENT"]})}):
            r=self.engine.answer("recorded statement","WA","followup")
        self.assertTrue(r["model_used"]); self.assertEqual(r["evidence_ids"],["STATEMENT"])
    def test_semantic_failure_falls_back(self):
        self.engine.meta["embedding_model"]="test"; self.engine.vectors={"STATEMENT":[1.0,0.0]}
        with patch("rag.embed",side_effect=OSError("offline")):
            r=self.engine.retrieve("recorded statement","WA")
        self.assertIn("STATEMENT",[c["id"] for c in r["cards"]])
        self.assertTrue(r["warnings"])
    def test_semantic_vector_fusion(self):
        self.engine.meta["embedding_model"]="test"; self.engine.vectors={"STATEMENT":[1.0,0.0]}
        with patch("rag.embed",return_value=[[1.0,0.0]]):
            r=self.engine.retrieve("zqx unfamiliar wording","WA")
        self.assertTrue(r["semantic_used"]); self.assertEqual(r["cards"][0]["id"],"STATEMENT")
    def test_ingestion_failure_preserves_index(self):
        self.corpus["cards"][0]["source_ids"]=["MISSING"]
        self.path.write_text(json.dumps(self.corpus),encoding="utf-8")
        with self.assertRaises(ValueError): rag.ingest(self.path,self.db)
        self.assertTrue(self.db.exists())
        self.assertEqual(self.engine.retrieve("neck injury","WA")["status"],"retrieved")
    def test_http_answer_and_invalid_request(self):
        server=rag.make_server(self.engine,0)
        t=threading.Thread(target=server.serve_forever,daemon=True); t.start()
        base=f"http://127.0.0.1:{server.server_port}"
        try:
            with urllib.request.urlopen(base+"/health") as r:
                self.assertEqual(json.load(r)["status"],"ok")
            request=urllib.request.Request(base+"/v1/answer",data=json.dumps({"query":"my friend is not breathing","stage":"active"}).encode(),headers={"Content-Type":"application/json"})
            with urllib.request.urlopen(request) as r: self.assertEqual(json.load(r)["status"],"emergency")
            bad=urllib.request.Request(base+"/v1/retrieve",data=b'{"query":""}')
            with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen(bad)
            self.assertEqual(e.exception.code,400); e.exception.close()
        finally:
            server.shutdown(); server.server_close(); t.join()
    def test_cross_origin_rejected(self):
        server=rag.make_server(self.engine,0)
        t=threading.Thread(target=server.serve_forever,daemon=True); t.start()
        try:
            req=urllib.request.Request(f"http://127.0.0.1:{server.server_port}/v1/answer",data=b'{"query":"hi"}',headers={"Origin":"https://evil.example"})
            with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen(req)
            self.assertEqual(e.exception.code,403); e.exception.close()
        finally: server.shutdown(); server.server_close(); t.join()

if __name__=="__main__": unittest.main()
