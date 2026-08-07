#!/usr/bin/env python3
from __future__ import annotations
import argparse, gc, hashlib, json, os, platform, sys, time
from pathlib import Path
from typing import Any

ACCURACY = {
    "yolo26x.pt": 57.5,
    "yolo26l.pt": 55.0,
    "yolo26m.pt": 53.1,
    "yolo26s.pt": 48.6,
    "yolo26n.pt": 40.9,
}
CACHE = Path(os.environ.get("XDG_CACHE_HOME", str(Path.home()/".cache"))) / "ophanim-av"
DATA = Path(os.environ.get("XDG_DATA_HOME", str(Path.home()/".local/share"))) / "ophanim-av"
SELECTION = CACHE / "yolo-selection.json"
WEIGHTS = DATA / "models" / "ultralytics"

def ram_bytes() -> int:
    try:
        if sys.platform == "win32":
            import ctypes
            class M(ctypes.Structure):
                _fields_=[("dwLength",ctypes.c_ulong),("dwMemoryLoad",ctypes.c_ulong),
                    ("ullTotalPhys",ctypes.c_ulonglong),("ullAvailPhys",ctypes.c_ulonglong),
                    ("ullTotalPageFile",ctypes.c_ulonglong),("ullAvailPageFile",ctypes.c_ulonglong),
                    ("ullTotalVirtual",ctypes.c_ulonglong),("ullAvailVirtual",ctypes.c_ulonglong),
                    ("ullAvailExtendedVirtual",ctypes.c_ulonglong)]
            m=M(); m.dwLength=ctypes.sizeof(M); ctypes.windll.kernel32.GlobalMemoryStatusEx(ctypes.byref(m)); return int(m.ullTotalPhys)
        return int(os.sysconf("SC_PHYS_PAGES") * os.sysconf("SC_PAGE_SIZE"))
    except Exception:
        return 0

def release() -> None:
    gc.collect()
    try:
        import torch
        if torch.cuda.is_available():
            torch.cuda.empty_cache(); torch.cuda.ipc_collect()
    except Exception:
        pass

def profile() -> dict[str, Any]:
    import torch
    p={"platform":platform.platform(),"machine":platform.machine(),"cpu_threads":os.cpu_count() or 1,
       "ram_bytes":ram_bytes(),"torch":getattr(torch,"__version__","unknown"),"backend":"cpu",
       "device":"cpu","gpu_name":None,"vram_total":0,"vram_free":0,"compute_capability":None}
    if torch.cuda.is_available():
        i=torch.cuda.current_device(); props=torch.cuda.get_device_properties(i); free,total=torch.cuda.mem_get_info(i)
        p.update(backend="cuda",device=str(i),gpu_name=props.name,vram_total=int(total),vram_free=int(free),
                 compute_capability=list(torch.cuda.get_device_capability(i)))
    elif getattr(torch.backends,"mps",None) is not None and torch.backends.mps.is_available():
        p.update(backend="mps",device="mps",gpu_name="Apple MPS")
    return p

def signature(p: dict[str, Any]) -> str:
    keys=("platform","machine","cpu_threads","ram_bytes","torch","backend","gpu_name","vram_total","compute_capability")
    return hashlib.sha256(json.dumps({k:p[k] for k in keys},sort_keys=True).encode()).hexdigest()

def candidates(p: dict[str, Any], policy: str) -> list[str]:
    v=p["vram_total"]/(1024**3); r=p["ram_bytes"]/(1024**3); t=int(p["cpu_threads"])
    if policy=="speed": return ["yolo26n.pt","yolo26s.pt"]
    if p["backend"]=="cuda":
        if v>=10: out=["yolo26x.pt","yolo26l.pt","yolo26m.pt","yolo26s.pt","yolo26n.pt"]
        elif v>=7: out=["yolo26l.pt","yolo26m.pt","yolo26s.pt","yolo26n.pt"]
        elif v>=5: out=["yolo26m.pt","yolo26s.pt","yolo26n.pt"]
        elif v>=3: out=["yolo26s.pt","yolo26n.pt"]
        else: out=["yolo26n.pt"]
        if policy=="balanced" and out[0]=="yolo26x.pt": out=out[1:]
        return out
    if p["backend"]=="mps":
        return (["yolo26l.pt","yolo26m.pt","yolo26s.pt","yolo26n.pt"] if r>=32 else
                ["yolo26m.pt","yolo26s.pt","yolo26n.pt"] if r>=16 else ["yolo26s.pt","yolo26n.pt"])
    if policy=="accuracy" and t>=12 and r>=24: return ["yolo26m.pt","yolo26s.pt","yolo26n.pt"]
    return ["yolo26s.pt","yolo26n.pt"] if t>=8 and r>=12 else ["yolo26n.pt"]

def device_for(p: dict[str, Any], force: str|None=None) -> str:
    if force: return force
    return p["device"] if p["backend"] in {"cuda","mps"} else "cpu"

def probe(name: str, p: dict[str, Any], force_device: str|None=None) -> dict[str, Any]:
    import numpy as np, torch
    from ultralytics import YOLO
    WEIGHTS.mkdir(parents=True,exist_ok=True); old=Path.cwd(); dev=device_for(p,force_device)
    try:
        os.chdir(WEIGHTS)
        if dev not in {"cpu","mps"}: torch.cuda.reset_peak_memory_stats(int(dev))
        model=YOLO(name); image=np.zeros((640,640,3),dtype=np.uint8)
        kw=dict(source=image,device=dev,imgsz=640,batch=1,verbose=False,save=False)
        if dev not in {"cpu","mps"}: kw.update(quantize=16,channels_last=True)
        model.predict(**kw)
        start=time.perf_counter(); model.predict(**kw); ms=(time.perf_counter()-start)*1000
        peak=int(torch.cuda.max_memory_allocated(int(dev))) if dev not in {"cpu","mps"} else 0
        local=WEIGHTS/name
        return {"model":name,"model_path":str(local if local.is_file() else name),"device":dev,
                "latency_ms_640":round(ms,2),"peak_vram_bytes":peak,"coco_map_50_95":ACCURACY[name]}
    finally:
        os.chdir(old); release()

def select(*,force=False,policy=None,force_device=None) -> dict[str, Any]:
    policy=(policy or os.environ.get("OPHANIM_YOLO_POLICY","accuracy")).lower()
    if policy not in {"accuracy","balanced","speed"}: raise ValueError(policy)
    p=profile(); sig=signature(p)
    if not force and force_device is None and SELECTION.is_file():
        try:
            c=json.loads(SELECTION.read_text())
            mp=c.get("selected",{}).get("model_path")
            if c.get("signature")==sig and c.get("policy")==policy and mp and (Path(mp).is_file() or not Path(mp).is_absolute()): return c
        except Exception: pass
    errors=[]
    for name in candidates(p,policy):
        try:
            chosen=probe(name,p,force_device); break
        except Exception as e:
            errors.append({"model":name,"error":f"{type(e).__name__}: {e}"}); release()
    else:
        raise RuntimeError("No YOLO26 model passed: "+json.dumps(errors))
    out={"signature":sig,"policy":policy,"profile":p,"selected":chosen,"failures":errors,
         "created_at":time.strftime("%Y-%m-%dT%H:%M:%SZ",time.gmtime())}
    if force_device is None:
        CACHE.mkdir(parents=True,exist_ok=True); tmp=SELECTION.with_suffix(".tmp"); tmp.write_text(json.dumps(out,indent=2)); os.replace(tmp,SELECTION)
    return out

def resolve(requested: str, force_device: str|None=None) -> dict[str, Any]:
    if requested.strip().lower()=="auto": return select(force_device=force_device)
    p=profile(); return {"signature":signature(p),"policy":"explicit","profile":p,"failures":[],
        "selected":{"model":requested,"model_path":requested,"device":device_for(p,force_device),
                    "latency_ms_640":None,"peak_vram_bytes":None,"coco_map_50_95":ACCURACY.get(requested)}}

def gib(n:int)->str: return f"{n/(1024**3):.2f} GiB" if n else "0 GiB"
def show(out:dict[str,Any])->None:
    p=out["profile"]; s=out["selected"]
    print("OphanimAV YOLO hardware profile")
    print("===============================")
    print("Backend:       ",p["backend"]); print("GPU:           ",p["gpu_name"] or "none")
    print("VRAM:          ",gib(p["vram_total"])); print("System RAM:    ",gib(p["ram_bytes"])); print("CPU threads:   ",p["cpu_threads"])
    print("Policy:        ",out["policy"]); print("Selected model:",s["model"]); print("Device:        ",s["device"])
    print("640 latency:   ",s["latency_ms_640"],"ms"); print("Peak VRAM:     ",gib(s["peak_vram_bytes"] or 0)); print("COCO mAP:      ",s["coco_map_50_95"])

def main()->int:
    ap=argparse.ArgumentParser(); sp=ap.add_subparsers(dest="cmd",required=True)
    sp.add_parser("profile"); sp.add_parser("status")
    s=sp.add_parser("select"); s.add_argument("--force",action="store_true"); s.add_argument("--policy",choices=("accuracy","balanced","speed"),default="accuracy")
    a=ap.parse_args()
    if a.cmd=="profile":
        p=profile(); show({"profile":p,"selected":{"model":"not selected","device":p["device"],"latency_ms_640":None,"peak_vram_bytes":0,"coco_map_50_95":None},"policy":"n/a"}); return 0
    if a.cmd=="status":
        if not SELECTION.is_file(): print("No cached YOLO selection."); return 1
        show(json.loads(SELECTION.read_text())); return 0
    show(select(force=a.force,policy=a.policy)); return 0
if __name__=="__main__": raise SystemExit(main())
