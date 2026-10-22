"""Adapters for the inspected transport repo, without copying or importing its training jobs."""
from __future__ import annotations
import hashlib, importlib.util, math, sys
from pathlib import Path

CLASS_NAMES=("still","walk","run","bike","car","bus","train","subway")

def mode_observation(probabilities, model_id, threshold=.8):
    if len(probabilities)!=8 or any(type(x) not in (int,float) or not math.isfinite(x) or not 0<=x<=1 for x in probabilities):
        raise ValueError("Expected 8 SHL softmax probabilities")
    if abs(sum(probabilities)-1)>.01: raise ValueError("Probabilities must sum to one")
    if not isinstance(model_id,str) or not model_id or len(model_id)>120: raise ValueError("Model ID required")
    if not 0<=threshold<=1: raise ValueError("Invalid threshold")
    index=max(range(8),key=lambda i:probabilities[i]); probability=probabilities[index]
    label=CLASS_NAMES[index] if probability>=threshold else "unknown"
    if label=="bike": label="bicycle"
    return {"label":label,"basis":"model","probability":probability,"model_id":model_id}

def prepare_imu_window(samples, metadata):
    """Reproduce eval_cross.py per-window path, failing closed on missing contracts.

    Caller must supply metadata establishing physical units and channel semantics;
    the clone's checkpoint alone is insufficient. Never apply this to crash G values.
    """
    import numpy as np
    if metadata.get("input_contract")!={"channels":["laccx","laccy","laccz","gyrx","gyry","gyrz","magx","magy","magz"],
        "linear_acceleration_unit":"m/s2","gyroscope_unit":"rad/s","sample_rate_hz":50,"window_samples":250}:
        raise ValueError("Verified 50 Hz / 250 x 9 physical input contract required")
    x=np.asarray(samples,dtype=np.float32)
    if x.shape!=(250,9) or not np.isfinite(x).all(): raise ValueError("Expected finite 250 x 9 array")
    norm=metadata.get("norm_stats",{})
    if norm.get("mode")!="perwin" or "floor" not in norm or "clip" not in norm:
        raise ValueError("Per-window normalization metadata is missing")
    floor=np.asarray(norm["floor"],dtype=np.float32)
    if floor.shape!=(9,) or not np.isfinite(floor).all() or (floor<=0).any():
        raise ValueError("Invalid normalization floor")
    clip=float(norm["clip"])
    if not math.isfinite(clip) or clip<=0: raise ValueError("Invalid clip")
    x=(x-x.mean(axis=0,keepdims=True))/np.maximum(x.std(axis=0,keepdims=True),floor)
    x=np.clip(x,-clip,clip)
    groups={"lacc":slice(0,3),"gyr":slice(3,6),"mag":slice(6,9)}
    mask=set(metadata.get("mask_channels",[]))
    if not mask or not mask<=groups.keys(): raise ValueError("Channel mask required")
    for group,sl in groups.items():
        if group not in mask: x[:,sl]=0
    names=("laccx","laccy","laccz","gyrx","gyry","gyrz","magx","magy","magz")
    return {name+"_input":x[None,:,i:i+1] for i,name in enumerate(names)}

def analyze_motion(samples, repo_path, expected_sha256, heading_axis, orientation_verified=False, fs=50.0):
    """Run the actual upstream behavior/events.py with explicit units and alignment.

    Samples are uniformly sampled device coordinates: uptime, acceleration_g [3],
    rotation_rad_s [3], speed_mps. No raw telemetry is stored or sent to the RAG model.
    """
    import numpy as np
    if orientation_verified is not True: raise ValueError("Device-to-travel heading alignment must be verified")
    if type(heading_axis) is not int or heading_axis not in (0,1,2): raise ValueError("Explicit heading_axis required")
    if type(fs) not in (int,float) or not math.isfinite(fs) or fs<=0 or fs>200: raise ValueError("Invalid sample rate")
    if not 2<=len(samples)<=20000: raise ValueError("Expected 2-20000 samples")
    acc=[]; gyro=[]; speed=[]; times=[]
    for sample in samples:
        a=sample["acceleration_g"]; g=sample["rotation_rad_s"]; v=sample["speed_mps"]; t=sample["uptime"]
        if len(a)!=3 or len(g)!=3 or any(type(n) not in (int,float) or not math.isfinite(n) for n in [*a,*g,v,t]) or v<0 or t<0:
            raise ValueError("Invalid physical sample")
        acc.append(a); gyro.append(g); speed.append(v); times.append(t)
    if any(abs((b-a)-1/fs)>.2/fs for a,b in zip(times,times[1:])):
        raise ValueError("Uniformly sampled motion required; resample with validated alignment first")
    source=Path(repo_path)/"project-root"/"src"/"behavior"/"events.py"
    digest=hashlib.sha256(source.read_bytes()).hexdigest()
    if not expected_sha256 or digest!=expected_sha256: raise ValueError("Upstream source changed; review and update its pinned hash")
    # Explicit user-selected, inspected local code; never deserialize untrusted model pickles.
    module_name="_crashsafe_upstream_behavior_"+digest[:16]
    if module_name not in sys.modules:
        spec=importlib.util.spec_from_file_location(module_name,source)
        module=importlib.util.module_from_spec(spec); sys.modules[module_name]=module
        spec.loader.exec_module(module)
    module=sys.modules[module_name]
    events=module.analyze_trip(np.asarray(acc)*9.81,np.asarray(gyro),np.asarray(speed)*3.6,fs=fs,heading_axis=heading_axis,cfg=module.EventConfig(speed_kph=float("inf")))
    suppressed=sorted({e.kind for e in events if e.kind not in {"harsh_brake","harsh_accel"}})
    result=[{"kind":e.kind,"start":e.start,"end":e.end,"severity":e.severity} for e in events if e.kind in {"harsh_brake","harsh_accel"}]
    return {"events":result[-20:],"truncated":len(result)>20,"source_sha256":digest,
        "suppressed_event_kinds":suppressed,
        "legal_speed_limit_known":False,"warning":"Only longitudinal events are exposed. Upstream rotation rules reuse the heading axis for different physical axes, and speeding uses a fixed threshold rather than a posted limit. Those event types are suppressed. No event determines a crash or fault."}
