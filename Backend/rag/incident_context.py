"""Typed incident context. Observations do not become medical or insurance evidence."""
from __future__ import annotations
import datetime as dt
import math
from motion_intel import normalize_impact, normalize_activity, describe_impact

EVIDENCE={"sustainedImpact","strongImpact","rapidRotation","speedLoss","settledAfterImpact","possiblePhoneDrop","continuedTravel","largeImpactDeltaV"}
ISSUES={"insufficientBaseline","insufficientPostImpact","motionGap","missingReliableGPS"}
MODES={"car","motorcycle","bicycle","still","walk","run","bus","train","subway","unknown"}
BEHAVIOR={"harsh_brake","harsh_accel","sharp_corner","instability","speeding"}

def number(value, name, lo=0, hi=100000):
    if type(value) not in (int,float) or not math.isfinite(value) or not lo<=value<=hi:
        raise ValueError("Invalid "+name)
    return value

def normalize_incident(raw, now=None):
    if raw is None: return None
    if not isinstance(raw,dict): raise ValueError("incident must be an object")
    allowed={"schema_version","captured_at","is_simulated","decision","evidence","issues","peak_g","speed_drop_mps","transport","behavior_events","impact"}
    if set(raw)-allowed: raise ValueError("Unsupported incident fields; do not send private profile details")
    if type(raw.get("schema_version")) is not int or raw.get("schema_version")!=1 or type(raw.get("is_simulated")) is not bool:
        raise ValueError("Invalid incident version or simulation flag")
    captured=raw.get("captured_at")
    if not isinstance(captured,str): raise ValueError("captured_at must be an ISO timestamp")
    try: timestamp=dt.datetime.fromisoformat(captured.replace("Z","+00:00"))
    except ValueError as e: raise ValueError("Invalid captured_at") from e
    if timestamp.tzinfo is None: raise ValueError("Timestamp must include timezone")
    now=now or dt.datetime.now(dt.timezone.utc)
    age=(now-timestamp).total_seconds()
    if age < -5: raise ValueError("Incident timestamp is in the future")
    decision=raw.get("decision","inconclusive")
    if decision not in {"suspectedCrash","rejected","inconclusive"}: raise ValueError("Invalid decision")
    result={"schema_version":1,"captured_at":timestamp.isoformat(),"age_seconds":round(max(age,0),3),
        "stale":age>120,"is_simulated":raw["is_simulated"],"decision":decision,"authority":"experimental_sensor_observation"}
    for key,values in (("evidence",EVIDENCE),("issues",ISSUES)):
        xs=raw.get(key,[])
        if not isinstance(xs,list) or len(xs)>16 or any(not isinstance(x,str) or x not in values for x in xs):
            raise ValueError("Invalid "+key)
        result[key]=list(dict.fromkeys(xs))
    for key in ("peak_g","speed_drop_mps"):
        if raw.get(key) is not None: result[key]=number(raw[key],key,hi=1000)
    transport=raw.get("transport",{"label":"unknown","basis":"unknown"})
    if not isinstance(transport,dict) or set(transport)-{"label","basis","probability","model_id"}:
        raise ValueError("Invalid transport observation")
    label=transport.get("label","unknown"); basis=transport.get("basis","unknown")
    if label not in MODES or basis not in {"profile","model","unknown"}: raise ValueError("Invalid transport mode or basis")
    if basis=="unknown" and label!="unknown": raise ValueError("Unknown basis cannot assert a mode")
    if basis=="model" and label=="motorcycle": raise ValueError("Current SHL model has no motorcycle class")
    result["transport"]={"label":label,"basis":basis,"accepted":basis=="profile" and label!="unknown"}
    if basis=="model":
        probability=number(transport.get("probability"),"probability",hi=1)
        model_id=transport.get("model_id")
        if not isinstance(model_id,str) or not 1<=len(model_id)<=120: raise ValueError("Model provenance required")
        result["transport"].update(probability=probability,model_id=model_id,
            accepted=probability>=.8 and label!="unknown",
            caveat="Softmax score is not calibrated confidence or crash probability.")
    events=raw.get("behavior_events",[])
    if not isinstance(events,list) or len(events)>20: raise ValueError("Too many behavior events")
    clean=[]
    for event in events:
        if not isinstance(event,dict) or set(event)-{"kind","start","end","severity"} or event.get("kind") not in BEHAVIOR:
            raise ValueError("Invalid behavior event")
        start=number(event.get("start"),"event start"); end=number(event.get("end"),"event end")
        severity=number(event.get("severity"),"event severity",hi=1)
        if end<start: raise ValueError("Event end precedes start")
        clean.append({"kind":event["kind"],"start":start,"end":end,"severity":severity,
            "authority":"experimental_heuristic","legal_speed_limit_known":False})
    result["behavior_events"]=clean
    # Impact metrics from the app's rolling sensor history (motion_intel.impact_report on device).
    result["impact"]=normalize_impact(raw.get("impact"))
    result["limitations"]=["Does not establish injury, consciousness, fault, legal speeding or insurance coverage.",
        "A rejected detector event does not establish that nobody was injured."]
    return result

def assist(engine,query,jurisdiction="UNKNOWN",stage="active",persona="auto",flags=None,incident=None,activity=None):
    observation=normalize_incident(incident)
    current=normalize_activity(activity)
    # Sensor evidence never sets injury/fire/nonresponse flags, never selects jurisdiction,
    # and never cancels a user-reported emergency.
    if not isinstance(query,str) or not query.strip() or len(query)>4000:
        raise ValueError("Invalid query")
    if stage not in ("active","followup"): raise ValueError("Invalid stage")
    if flags is not None and (not isinstance(flags,dict) or any(k not in ("fire","unresponsive","serious_symptoms") or type(v) is not bool for k,v in flags.items())):
        raise ValueError("Invalid emergency flags")
    urgent=engine.emergency(query,"active",flags or {})
    result=engine.answer(query,jurisdiction,"active" if urgent else stage,persona,flags)
    result["incident_context"]=observation
    result["activity_context"]=current
    if observation:
        if observation["is_simulated"]:
            note="Demo incident data: this is a simulated event."
        elif observation["stale"]:
            note="The sensor assessment is older than two minutes; current conditions are unknown."
        elif observation["decision"]=="suspectedCrash":
            note="The experimental detector flagged a possible collision. It cannot determine whether anyone is injured."
        elif observation["decision"]=="rejected":
            note="The detector did not confirm its candidate. That does not establish that you are uninjured."
        else:
            note="The experimental sensor assessment was inconclusive."
        if observation.get("impact") and not observation["stale"]:
            note+=" "+describe_impact(observation["impact"])
        result["incident_note"]=note
        # Never put a sensor explanation before an emergency instruction.
        if result["status"] not in ("emergency","review_required"):
            result["answer"]=note+"\n\n"+result["answer"]
    return result
