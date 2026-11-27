# Written under the former name Podlight.
# Runs INSIDE the spike pod. Answers two questions for Podlight's dead-man switch:
#  1. Does RunPod put a key into the container, and what may it do?
#  2. Can the pod stop itself with it?
# Never writes a secret value anywhere: only variable names, lengths and HTTP status codes.
import json, os, shutil, sys, threading, time, urllib.request, http.server

POD_ID = os.environ.get("RUNPOD_POD_ID", "")
HOLD = int(os.environ.get("SPIKE_HOLD_SECONDS", "360"))
report = {"started": time.time(), "pod_id_env": bool(POD_ID), "steps": []}

def note(step, **data):
    report["steps"].append({"t": round(time.time() - report["started"], 1), "step": step, **data})

def call(method, url, key, body=None):
    req = urllib.request.Request(url, method=method, data=json.dumps(body).encode() if body else None,
                                 headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json",
                                          "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            raw = r.read()
            return r.status, raw
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:300]
    except Exception as e:  # network trouble is a result too
        return -1, str(e).encode()[:300]

# 1. What is in the environment? Names only.
interesting = sorted(k for k in os.environ if k.startswith("RUNPOD") or "KEY" in k or "TOKEN" in k)
note("env", names={k: len(os.environ[k]) for k in interesting},
     runpodctl=shutil.which("runpodctl"))

key = os.environ.get("RUNPOD_API_KEY", "")
if key and POD_ID:
    # 2. Scope: may it see the whole account, or only this pod?
    s, raw = call("GET", "https://api.runpod.io/v2/pods", key)
    count = None
    try:
        count = len(json.loads(raw).get("pods", []))
    except Exception:
        pass
    note("list_all_pods_v2", status=s, pods_visible=count)
    s, _ = call("GET", f"https://api.runpod.io/v2/pods/{POD_ID}", key)
    note("get_own_pod_v2", status=s)
    s, _ = call("GET", f"https://rest.runpod.io/v1/pods/{POD_ID}", key)
    note("get_own_pod_v1", status=s)
    s, _ = call("GET", "https://api.runpod.io/v2/catalog/gpus", key)
    note("catalog_v2", status=s)
else:
    note("no_injected_key")

# Serve the report so it can be read from outside through RunPod's proxy.
class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        body = json.dumps(report, indent=1).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers()
        self.wfile.write(body)
    def log_message(self, *a): pass

threading.Thread(target=http.server.ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever, daemon=True).start()
note("serving", hold_seconds=HOLD)
time.sleep(HOLD)

# 3. The actual brake.
if key and POD_ID:
    s, raw = call("POST", f"https://api.runpod.io/v2/pods/{POD_ID}/action", key, {"action": "stop"})
    note("self_stop_v2", status=s, body=raw.decode(errors="replace")[:200])
    if s not in (200, 201, 202, 204):
        s, raw = call("POST", f"https://rest.runpod.io/v1/pods/{POD_ID}/stop", key)
        note("self_stop_v1", status=s, body=raw.decode(errors="replace")[:200])
    time.sleep(120)  # if the stop worked we never get here

# 4. Fallback question: what does RunPod do when the main process simply ends?
note("exiting_main_process")
sys.stdout.flush()
sys.exit(0)
