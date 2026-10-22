import copy, datetime as dt, hashlib, json, tempfile, threading, unittest, urllib.request
from pathlib import Path
import rag
from incident_context import normalize_incident, assist
from transport_adapter import mode_observation, prepare_imu_window, analyze_motion
from build_repo_context import build
try:
    import numpy as np
except ImportError:
    np=None

class IntegrationTests(unittest.TestCase):
    def setUp(self):
        self.temp=tempfile.TemporaryDirectory()
        corpus=rag.read_json(rag.ROOT/"knowledge"/"corpus.json")
        for card in corpus["cards"]: card["expires"]=(dt.date.today()+dt.timedelta(days=30)).isoformat()
        p=Path(self.temp.name)/"corpus.json"; p.write_text(json.dumps(corpus),encoding="utf-8")
        self.db=Path(self.temp.name)/"medical.sqlite3"; rag.ingest(p,self.db)
        self.engine=rag.Engine(self.db)
        self.packet={"schema_version":1,"captured_at":dt.datetime.now(dt.timezone.utc).isoformat(),
            "is_simulated":False,"decision":"suspectedCrash","peak_g":6.1,
            "evidence":["strongImpact","speedLoss"],"issues":["missingReliableGPS"],
            "transport":{"label":"car","basis":"profile"}}
    def tearDown(self):
        self.engine.close(); self.temp.cleanup()
    def test_observation_preserves_provenance(self):
        result=normalize_incident(self.packet)
        self.assertEqual(result["authority"],"experimental_sensor_observation")
        self.assertEqual(result["transport"]["basis"],"profile")
    def test_observation_is_not_injected_into_medical_corpus(self):
        count=len(self.engine.cards)
        result=assist(self.engine,"What should I document?","WA","followup",incident=self.packet)
        self.assertEqual(count,len(self.engine.cards))
        self.assertIn("possible collision",result["answer"])
        self.assertNotIn("REPO_",json.dumps(result["citations"]))
    def test_sensor_decision_never_suppresses_reported_emergency(self):
        self.packet["decision"]="rejected"
        result=assist(self.engine,"my chest hurts","WA","followup",incident=self.packet)
        self.assertEqual(result["status"],"emergency")
        self.assertTrue(result["answer"].startswith("Call 911"))
    def test_sensor_does_not_assert_emergency_or_injury(self):
        result=assist(self.engine,"What photographs should I take?","WA","followup",incident=self.packet)
        self.assertNotEqual(result["status"],"emergency")
        self.assertEqual(result["dispatch_status"] if "dispatch_status" in result else "not_requested","not_requested")
    def test_simulation_label_preserved(self):
        self.packet["is_simulated"]=True
        r=assist(self.engine,"documentation","WA","followup",incident=self.packet)
        self.assertTrue(r["answer"].startswith("Demo incident"))
    def test_stale_data_labeled(self):
        self.packet["captured_at"]=(dt.datetime.now(dt.timezone.utc)-dt.timedelta(minutes=5)).isoformat()
        self.assertTrue(normalize_incident(self.packet)["stale"])
    def test_future_timestamp_rejected(self):
        self.packet["captured_at"]=(dt.datetime.now(dt.timezone.utc)+dt.timedelta(hours=1)).isoformat()
        with self.assertRaises(ValueError): normalize_incident(self.packet)
    def test_naive_time_rejected(self):
        self.packet["captured_at"]="2026-10-22T12:00:00"
        with self.assertRaises(ValueError): normalize_incident(self.packet)
    def test_private_profile_fields_rejected(self):
        for key in ["medical_notes","policy_number","latitude","family_contacts"]:
            packet=copy.deepcopy(self.packet); packet[key]="private"
            with self.subTest(key=key):
                with self.assertRaises(ValueError): normalize_incident(packet)
    def test_nonfinite_value_rejected(self):
        self.packet["peak_g"]=float("nan")
        with self.assertRaises(ValueError): normalize_incident(self.packet)
    def test_invalid_emergency_flags_rejected_before_routing(self):
        with self.assertRaises(ValueError): assist(self.engine,"Help",flags={"fire":"false"})
    def test_profile_motorcycle_is_not_model_prediction(self):
        self.packet["transport"]={"label":"motorcycle","basis":"profile"}
        self.assertEqual(normalize_incident(self.packet)["transport"]["basis"],"profile")
        self.packet["transport"]["basis"]="model"
        with self.assertRaises(ValueError): normalize_incident(self.packet)
    def test_no_invented_motorcycle_class(self):
        with self.assertRaises(ValueError): mode_observation([0]*8+[1],"fake")
    def test_low_score_abstains(self):
        self.assertEqual(mode_observation([.125]*8,"test")["label"],"unknown")
    def test_bike_label_maps_to_app_bicycle(self):
        p=[0.0]*8; p[3]=1.
        self.assertEqual(mode_observation(p,"test")["label"],"bicycle")
    def test_model_confidence_is_not_crash_probability(self):
        self.packet["transport"]=mode_observation([0,0,0,0,1,0,0,0],"test")
        result=normalize_incident(self.packet)
        self.assertIn("not calibrated",result["transport"]["caveat"])
    def test_invalid_probability_rejected(self):
        with self.assertRaises(ValueError): mode_observation([1.]*8,"bad")
    @unittest.skipIf(np is None,"numpy optional dependency unavailable")
    def test_missing_normalization_contract_fails_closed(self):
        with self.assertRaises(ValueError): prepare_imu_window(np.zeros((250,9)),{})
    @unittest.skipIf(np is None,"numpy optional dependency unavailable")
    def test_normalization_channel_mask_matches_upstream(self):
        meta={"input_contract":{"channels":["laccx","laccy","laccz","gyrx","gyry","gyrz","magx","magy","magz"],
            "linear_acceleration_unit":"m/s2","gyroscope_unit":"rad/s","sample_rate_hz":50,"window_samples":250},
            "norm_stats":{"mode":"perwin","floor":[.01]*9,"clip":3},"mask_channels":["lacc","gyr"]}
        x=np.arange(250*9,dtype=np.float32).reshape(250,9)
        result=prepare_imu_window(x,meta)
        expected=(x-x.mean(axis=0))/np.maximum(x.std(axis=0),.01)
        np.testing.assert_allclose(result["laccx_input"][0,:,0],expected[:,0])
        self.assertEqual(result["laccx_input"].shape,(1,250,1))
        self.assertTrue(np.all(result["magx_input"]==0))
    def test_developer_route_without_index_is_503(self):
        server=rag.make_server(self.engine,0)
        t=threading.Thread(target=server.serve_forever,daemon=True); t.start()
        try:
            req=urllib.request.Request(f"http://127.0.0.1:{server.server_port}/v1/developer/retrieve",data=b'{"query":"sensor acquisition"}')
            with self.assertRaises(urllib.error.HTTPError) as e: urllib.request.urlopen(req)
            self.assertEqual(e.exception.code,503); e.exception.close()
        finally: server.shutdown(); server.server_close(); t.join()
    def test_real_http_assist_contract(self):
        server=rag.make_server(self.engine,0)
        t=threading.Thread(target=server.serve_forever,daemon=True); t.start()
        try:
            payload={"query":"What photos should I take?","jurisdiction":"WA","stage":"followup","persona":"practical","incident":self.packet}
            req=urllib.request.Request(f"http://127.0.0.1:{server.server_port}/v1/assist",data=json.dumps(payload).encode(),headers={"Content-Type":"application/json"})
            with urllib.request.urlopen(req) as response: data=json.load(response)
            self.assertEqual(data["status"],"answered"); self.assertEqual(data["incident_context"]["decision"],"suspectedCrash")
            self.assertTrue(data["citations"])
        finally: server.shutdown(); server.server_close(); t.join()

class LocalRepositoryTests(unittest.TestCase):
    def setUp(self):
        manifest=rag.ROOT/"data"/"repository-manifest.json"
        if not manifest.exists(): self.skipTest("Run build_repo_context.py with the local clones first")
        self.manifest=rag.read_json(manifest)
        self.ml=Path(self.manifest["repositories"]["transport"]["root"])
        if not self.ml.exists(): self.skipTest("Source clone not present on this machine")
    @unittest.skipIf(np is None,"numpy optional dependency unavailable")
    def test_actual_upstream_behavior_module_with_unit_conversion(self):
        expected=next(x["sha256"] for x in self.manifest["files"] if x["repo"]=="transport" and x["path"].endswith("behavior/events.py"))
        samples=[{"uptime":i/50,"acceleration_g":[-.4,0,0],"rotation_rad_s":[0,0,0],"speed_mps":20} for i in range(100)]
        result=analyze_motion(samples,self.ml,expected,heading_axis=0,orientation_verified=True)
        self.assertEqual(result["events"][0]["kind"],"harsh_brake")
        self.assertAlmostEqual(result["events"][0]["severity"],.75)
        self.assertFalse(result["legal_speed_limit_known"])
    @unittest.skipIf(np is None,"numpy optional dependency unavailable")
    def test_unaligned_device_frame_rejected(self):
        with self.assertRaises(ValueError): analyze_motion([],self.ml,"",0)
    @unittest.skipIf(np is None,"numpy optional dependency unavailable")
    def test_changed_upstream_code_rejected(self):
        samples=[{"uptime":i/50,"acceleration_g":[0,0,0],"rotation_rad_s":[0,0,0],"speed_mps":0} for i in range(2)]
        with self.assertRaises(ValueError): analyze_motion(samples,self.ml,"wrong",0,True)
    def test_developer_index_is_separate(self):
        developer=rag.Engine(rag.ROOT/"data"/"developer.sqlite3")
        try:
            r=developer.retrieve("AssistantContext profile scenario")
            self.assertTrue(r["cards"])
            self.assertTrue(all(c["audience"]=="developer" for c in r["cards"]))
            self.assertTrue(all(s.startswith("REPO_") for c in r["cards"] for s in c["source_ids"]))
        finally: developer.close()
    @unittest.skipIf(np is None,"numpy optional dependency unavailable")
    def test_rotation_labels_are_not_exposed(self):
        expected=next(x["sha256"] for x in self.manifest["files"] if x["repo"]=="transport" and x["path"].endswith("behavior/events.py"))
        samples=[{"uptime":i/50,"acceleration_g":[0,0,0],"rotation_rad_s":[3,0,0],"speed_mps":20} for i in range(100)]
        result=analyze_motion(samples,self.ml,expected,0,True)
        self.assertEqual(result["events"],[])
        self.assertIn("sharp_corner",result["suppressed_event_kinds"])
    @unittest.skipIf(np is None,"numpy optional dependency unavailable")
    def test_fixed_speed_rule_does_not_hide_braking(self):
        expected=next(x["sha256"] for x in self.manifest["files"] if x["repo"]=="transport" and x["path"].endswith("behavior/events.py"))
        samples=[{"uptime":i/50,"acceleration_g":[-.4,0,0],"rotation_rad_s":[0,0,0],"speed_mps":40} for i in range(100)]
        result=analyze_motion(samples,self.ml,expected,0,True)
        self.assertEqual(result["events"][0]["kind"],"harsh_brake")
    def test_checkpoint_metadata_gap_is_real(self):
        exp=self.ml/"project-root"/"outputs"/"experiments"/"msrlstmnp_p2_fs1_accgyr_20260927_000934"
        self.assertTrue((exp/"best.h5").exists())
        # This assertion records the inspected checkout; update the audit when metadata is added.
        self.assertFalse((exp/"metrics.json").exists())

if __name__=="__main__": unittest.main()
