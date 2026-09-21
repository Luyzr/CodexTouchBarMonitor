#!/usr/bin/env python3
"""Read-only PoC. No prompts, credentials, or raw threads are persisted."""
import json, subprocess, selectors, time, sys, threading, queue
from pathlib import Path
exe = "/Applications/ChatGPT.app/Contents/Resources/codex"
args = [exe, "app-server"] + (["proxy", "--sock", str(Path.home()/".codex/app-server-control/app-server-control.sock")] if "--proxy" in sys.argv else [])
p = subprocess.Popen(args, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
messages=queue.Queue()
def read_lines():
    for line in p.stdout: messages.put(line)
    messages.put(None)
threading.Thread(target=read_lines, daemon=True).start()
def send(value):
    p.stdin.write((json.dumps(value)+"\n").encode()); p.stdin.flush()
def call(i, method, params={}):
    send(dict(id=i, method=method, params=params))
    deadline=time.monotonic()+20
    while time.monotonic()<deadline:
        try: line=messages.get(timeout=1)
        except queue.Empty: continue
        if not line: raise RuntimeError("server exited")
        value=json.loads(line)
        if value.get("id")==i:
            if "error" in value: return {"rpcError": value["error"].get("code")}
            return value.get("result", {})
    return {"timeout": True}
report={}
try:
    initialized = call(1,"initialize",{"clientInfo":{"name":"touchbar_readonly_probe","version":"0.1.0"}})
    report["initialize"] = "rpcError" not in initialized and "timeout" not in initialized
    if not report["initialize"]: raise RuntimeError("initialize failed: " + str(initialized))
    send({"method":"initialized","params":{}})
    quota=call(2,"account/rateLimits/read")
    bucket=quota.get("rateLimitsByLimitId",{}).get("codex") or quota.get("rateLimits") or {}
    report["quotaReadError"] = quota.get("rpcError", quota.get("timeout"))
    report["weeklyWindowPresent"]=any((bucket.get(k) or {}).get("windowDurationMins")==10080 for k in ("primary","secondary"))
    loaded=call(3,"thread/loaded/list")
    report["ownServerLoadedCount"]=len(loaded.get("data",[]))
    listing=call(4,"thread/list",{"limit":100})
    threads=listing.get("data",[])
    report["storedThreadCountFirstPage"]=len(threads)
    report["storedThreadStatusCounts"]={}
    for t in threads:
        state=(t.get("status") or {}).get("type","absent")
        report["storedThreadStatusCounts"][state]=report["storedThreadStatusCounts"].get(state,0)+1
    report["hasMoreStoredThreads"]=bool(listing.get("nextCursor"))
finally:
    p.stdin.close()
    try: p.wait(timeout=3)
    except subprocess.TimeoutExpired: p.terminate(); p.wait(timeout=3)
Path("work").mkdir(exist_ok=True)
Path("work/app-server-proxy-probe.json" if "--proxy" in sys.argv else "work/app-server-probe.json").write_text(json.dumps(report,indent=2))
print(json.dumps(report,indent=2))
