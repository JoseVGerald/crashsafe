"""Build a separate developer-only index from explicit, inspected repository files."""
import argparse, datetime as dt, hashlib, json
from pathlib import Path
from rag import ingest

SELECTED={
 "crashsafe": ["README.md","docs/crash-detection.md",
  "CrashSafe/Services/Assistant/AssistantService.swift",
  "CrashSafe/Features/Assistant/AssistantContext+Make.swift",
  "CrashSafe/Services/CrashDetection/CrashEvidence.swift",
  "CrashSafe/Services/CrashDetection/CrashPipeline.swift",
  "CrashSafe/Services/Sensors/SensorTypes.swift"],
 "transport": ["project-root/README.md","project-root/CHECKPOINTS.md",
  "docs/06_model_architecture.md","docs/09_eval_methodology.md","docs/10_behavior_branch.md",
  "project-root/src/behavior/events.py","project-root/src/behavior/signal.py",
  "project-root/scripts/eval_cross.py"]
}
URLS={"crashsafe":"https://github.com/JoseVGerald/crashsafe",
 "transport":"https://github.com/udaykamboj/multi-placement-transportation-mode-classification-ML-system"}

def revision(root):
    head=(root/".git"/"HEAD").read_text().strip()
    if head.startswith("ref: "):
        ref=head[5:]; file=root/".git"/ref
        if file.exists(): return file.read_text().strip()
        for line in (root/".git"/"packed-refs").read_text().splitlines():
            if line.endswith(" "+ref): return line.split()[0]
        raise ValueError("Cannot resolve Git revision")
    return head

def build(app_root,ml_root,output):
    today=dt.date.today(); expiry=(today+dt.timedelta(days=90)).isoformat()
    roots={"crashsafe":Path(app_root).resolve(),"transport":Path(ml_root).resolve()}
    sources=[]; cards=[]; manifest={"repositories":{},"files":[],"domain":"developer_only"}
    for name,root in roots.items():
        rev=revision(root); manifest["repositories"][name]={"root":str(root),"commit":rev,"url":URLS[name],"commit_is_base_reference":True}
        for i,relative in enumerate(SELECTED[name]):
            p=(root/relative).resolve()
            if not p.is_relative_to(root) or p.is_symlink(): raise ValueError("Source escapes repository")
            if not p.exists(): continue
            raw=p.read_bytes(); text=raw.decode("utf-8-sig")
            digest=hashlib.sha256(raw).hexdigest(); sid=f"REPO_{name}_{i}"
            sources.append({"id":sid,"title":relative,"publisher":name+" repository",
                "url":URLS[name]+"/blob/"+rev+"/"+relative,"path":str(p),"commit":rev,"sha256":digest,
                "authority":"engineering_reference_not_medical","professional_review":"not_applicable",
                "snapshot":"local_working_tree","commit_is_base_reference":True})
            manifest["files"].append({"repo":name,"path":relative,"sha256":digest,"bytes":len(raw)})
            # Bounded code/document excerpts; filenames and provenance survive retrieval.
            for offset in range(0,len(text),1300):
                body=text[offset:offset+1500]
                if not body.strip(): continue
                cards.append({"id":f"{sid}_{offset}","title":name+" "+relative+f" excerpt {offset}",
                    "body":body,"terms":relative.replace("/"," ").replace("_"," "),
                    "scope":"US","stage":"any","source_ids":[sid],"status":"source_verified",
                    "expires":expiry,"audience":"developer","authority":"engineering_reference_not_medical"})
    output=Path(output); output.mkdir(parents=True,exist_ok=True)
    corpus=output/"repository-corpus.json"
    corpus.write_text(json.dumps({"sources":sources,"cards":cards},indent=2),encoding="utf-8")
    (output/"repository-manifest.json").write_text(json.dumps(manifest,indent=2),encoding="utf-8")
    result=ingest(corpus,output/"developer.sqlite3")
    return {"files":len(sources),"cards":result["indexed"],"output":str(output)}
if __name__=="__main__":
    p=argparse.ArgumentParser(description=__doc__)
    p.add_argument("--app-root",required=True); p.add_argument("--ml-root",required=True)
    p.add_argument("--output",default=str(Path(__file__).parent/"data"))
    args=p.parse_args()
    print(json.dumps(build(args.app_root,args.ml_root,args.output),indent=2))
