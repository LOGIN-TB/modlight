# Written under the former name Podlight.
# Runs INSIDE the spike pod. Question: can the key RunPod injects into a pod see OTHER pods?
# Read-only towards the foreign pod. Only status codes and field NAMES are reported, never values.
import json, os, threading, time, urllib.request, urllib.error, http.server

POD_ID = os.environ.get("RUNPOD_POD_ID", "")
FOREIGN = os.environ.get("FOREIGN_POD_ID", "")
HOLD = int(os.environ.get("SPIKE_HOLD_SECONDS", "600"))
KEY = os.environ.get("RUNPOD_API_KEY", "")
report = {"started": time.time(), "has_key": bool(KEY), "steps": []}

def note(step, **d):
    report["steps"].append({"t": round(time.time() - report["started"], 1), "step": step, **d})

def get(url):
    req = urllib.request.Request(url, headers={"Authorization": f"Bearer {KEY}", "Accept": "application/json"})
    try:
        with urllib.request.urlopen(req, timeout=20) as r:
            body = r.read()
            try:
                keys = sorted(json.loads(body).keys())
            except Exception:
                keys = None
            return r.status, keys
    except urllib.error.HTTPError as e:
        return e.code, e.read()[:200].decode(errors="replace")
    except Exception as e:
        return -1, str(e)[:200]

s, k = get(f"https://api.runpod.io/v2/pods/{POD_ID}")
note("get_own_pod", status=s)
s, k = get(f"https://api.runpod.io/v2/pods/{FOREIGN}")
note("get_foreign_pod", status=s, detail=k if s != 200 else f"{len(k or [])} fields returned")
s, k = get(f"https://api.runpod.io/v2/pods/{FOREIGN}/logs")
note("get_foreign_pod_logs", status=s, detail=k if s != 200 else "body returned")
s, k = get("https://api.runpod.io/v2/networkvolumes")
note("list_network_volumes", status=s)

class H(http.server.BaseHTTPRequestHandler):
    def do_GET(self):
        b = json.dumps(report, indent=1).encode()
        self.send_response(200); self.send_header("Content-Type", "application/json"); self.end_headers(); self.wfile.write(b)
    def log_message(self, *a): pass

threading.Thread(target=http.server.ThreadingHTTPServer(("0.0.0.0", 8000), H).serve_forever, daemon=True).start()
note("serving", hold_seconds=HOLD)
time.sleep(HOLD)
# Safety net in case nobody deletes this pod: stop itself (the mechanism measured in run 1).
req = urllib.request.Request(f"https://api.runpod.io/v2/pods/{POD_ID}/action", method="POST",
                             data=b'{"action":"stop"}',
                             headers={"Authorization": f"Bearer {KEY}", "Content-Type": "application/json"})
try:
    urllib.request.urlopen(req, timeout=20)
except Exception:
    pass
time.sleep(600)
