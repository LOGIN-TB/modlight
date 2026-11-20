# Podlight dead-man switch. Runs inside every pod Podlight starts, beside the engine.
#
# The pod stops itself when
#   - Podlight has not sent a heartbeat for PODLIGHT_HEARTBEAT_MINUTES (Mac asleep, app quit or
#     crashed, network gone), or
#   - the hard deadline has passed ("Läuft bis" plus a grace period), or
#   - the engine process has exited (a pod that cannot answer must not bill).
#
# It stops itself with the key RunPod injects into every pod (RUNPOD_API_KEY). Measured on
# 2026-11-20: that key can read and stop only its own pod. Stop, not terminate: the disk is kept
# so the next start is fast, and Podlight deletes unused pods itself after three days.
#
# Standard library only: it must run in any image that has python3.
import json, os, sys, threading, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POD_ID = os.environ.get("RUNPOD_POD_ID", "")
RUNPOD_KEY = os.environ.get("RUNPOD_API_KEY", "")
GATEWAY_KEY = os.environ.get("PODLIGHT_API_KEY", "")
MINUTES = float(os.environ.get("PODLIGHT_HEARTBEAT_MINUTES", "15"))
BOOT_GRACE_MINUTES = float(os.environ.get("PODLIGHT_BOOT_GRACE_MINUTES", "20"))
PORT = int(os.environ.get("PODLIGHT_WATCHDOG_PORT", "8001"))
API = os.environ.get("PODLIGHT_RUNPOD_API", "https://api.runpod.io")  # overridable for tests only
CHECK_SECONDS = float(os.environ.get("PODLIGHT_CHECK_SECONDS", "15"))
ENGINE_PID_FILE = os.environ.get("PODLIGHT_ENGINE_PID_FILE", "/tmp/podlight-engine.pid")

state = {
    "started": time.time(),
    # Until the first heartbeat arrives the engine is still downloading; allow extra time then.
    "last_heartbeat": None,
    # A resumed pod keeps the environment it was created with, so its deadline may be long past;
    # only a future one counts. The app's heartbeat sets the current one.
    "deadline": (lambda d: d if d and d > time.time() else None)(float(os.environ.get("PODLIGHT_DEADLINE") or 0)),
    "stopping": None,
}
lock = threading.Lock()


def log(msg):
    print(f"[podlight-watchdog] {msg}", flush=True)


def stop(reason):
    with lock:
        if state["stopping"]:
            return
        state["stopping"] = reason
    log(f"stopping pod: {reason}")
    body = json.dumps({"action": "stop"}).encode()
    for attempt in range(6):
        req = urllib.request.Request(
            f"{API}/v2/pods/{POD_ID}/action", data=body, method="POST",
            headers={"Authorization": f"Bearer {RUNPOD_KEY}", "Content-Type": "application/json"})
        try:
            with urllib.request.urlopen(req, timeout=20) as r:
                log(f"stop accepted: HTTP {r.status}")
                return
        except urllib.error.HTTPError as e:
            log(f"stop failed: HTTP {e.code}")
        except Exception as e:  # network trouble: try again
            log(f"stop failed: {e}")
        time.sleep(10 * (attempt + 1))
    # Last resort: end every process. RunPod restarts the container, which brings the watchdog
    # back with a fresh grace period; the app sees a pod that never becomes ready.
    log("could not stop through the API")


def engine_alive():
    try:
        pid = int(open(ENGINE_PID_FILE).read().strip())
        os.kill(pid, 0)
        return True
    except (OSError, ValueError):
        return None if not os.path.exists(ENGINE_PID_FILE) else False


def check_loop():
    while True:
        now = time.time()
        with lock:
            last = state["last_heartbeat"]
            deadline = state["deadline"]
        allowed = MINUTES * 60 if last else (MINUTES + BOOT_GRACE_MINUTES) * 60
        since = now - (last or state["started"])
        if since > allowed:
            stop(f"no heartbeat for {int(since // 60)} minutes")
        elif deadline and now > deadline:
            stop("deadline reached")
        elif engine_alive() is False:
            stop("engine exited")
        time.sleep(CHECK_SECONDS)


class Handler(BaseHTTPRequestHandler):
    def _authorised(self):
        return GATEWAY_KEY and self.headers.get("Authorization", "") == f"Bearer {GATEWAY_KEY}"

    def _reply(self, code, payload):
        data = json.dumps(payload).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def _status(self):
        with lock:
            return {
                "lastHeartbeat": state["last_heartbeat"],
                "deadline": state["deadline"],
                "stopping": state["stopping"],
                "heartbeatMinutes": MINUTES,
                "engineAlive": engine_alive(),
                "uptimeSeconds": int(time.time() - state["started"]),
            }

    def do_GET(self):
        if not self._authorised():
            return self._reply(401, {"error": "unauthorized"})
        self._reply(200, self._status())

    def do_POST(self):
        if not self._authorised():
            return self._reply(401, {"error": "unauthorized"})
        if self.path != "/heartbeat":
            return self._reply(404, {"error": "not found"})
        length = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(length) or b"{}")
        except ValueError:
            return self._reply(400, {"error": "bad json"})
        with lock:
            state["last_heartbeat"] = time.time()
            if "deadline" in body:
                state["deadline"] = float(body["deadline"]) if body["deadline"] else None
        self._reply(200, self._status())

    def log_message(self, *args):
        pass


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "stop":
        stop(" ".join(sys.argv[2:]))
        sys.exit(0)
    if not POD_ID or not RUNPOD_KEY:
        log("RUNPOD_POD_ID or RUNPOD_API_KEY missing: the pod cannot stop itself")
    threading.Thread(target=check_loop, daemon=True).start()
    log(f"watching: heartbeat every {MINUTES:g} min, deadline {state['deadline']}")
    ThreadingHTTPServer(("0.0.0.0", PORT), Handler).serve_forever()
