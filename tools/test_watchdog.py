"""Tests for the pod's dead-man switch (apps/mac/PodlightEngine/Sources/PodlightEngine/Resources/watchdog.py).

Runs the real watchdog against a fake RunPod API on localhost, with the timings shortened, and
checks that it stops the pod in each case it must, and only then. Standard library only:

    python3 -I tools/test_watchdog.py
"""
import http.client, json, os, socket, subprocess, sys, threading, time, unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WATCHDOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "apps", "mac", "PodlightEngine",
                        "Sources", "PodlightEngine", "Resources", "watchdog.py")


def free_port():
    with socket.socket() as s:
        s.bind(("127.0.0.1", 0))
        return s.getsockname()[1]


class FakeRunPod:
    def __init__(self):
        self.stops = []
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_POST(self):
                body = self.rfile.read(int(self.headers.get("Content-Length") or 0))
                outer.stops.append((self.path, self.headers.get("Authorization"), json.loads(body)))
                self.send_response(200); self.end_headers(); self.wfile.write(b"{}")

            def log_message(self, *a): pass

        self.port = free_port()
        self.server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


class WatchdogTest(unittest.TestCase):
    def start(self, **env):
        self.api = FakeRunPod()
        self.port = free_port()
        self.pidfile = f"/tmp/podlight-test-engine-{self.port}.pid"
        full = dict(os.environ, RUNPOD_POD_ID="pod123", RUNPOD_API_KEY="pod-scoped", PODLIGHT_API_KEY="gw",
                    PODLIGHT_HEARTBEAT_MINUTES="0.05", PODLIGHT_BOOT_GRACE_MINUTES="0", PODLIGHT_CHECK_SECONDS="0.3",
                    PODLIGHT_WATCHDOG_PORT=str(self.port), PODLIGHT_WATCHDOG_HOST="127.0.0.1", PODLIGHT_RUNPOD_API=f"http://127.0.0.1:{self.api.port}",
                    PODLIGHT_ENGINE_PID_FILE=self.pidfile)
        full.update(env)
        self.output = open(f"/tmp/podlight-test-watchdog-{self.port}.log", "w+")
        self.proc = subprocess.Popen([sys.executable, "-I", WATCHDOG], env=full,
                                     stdout=self.output, stderr=subprocess.STDOUT)
        for _ in range(200):
            try:
                socket.create_connection(("127.0.0.1", self.port), timeout=0.1).close()
                return
            except OSError:
                time.sleep(0.1)
        self.output.seek(0)
        self.fail(f"watchdog did not start (exit {self.proc.poll()}):\n{self.output.read()}")

    def tearDown(self):
        self.proc.kill(); self.proc.wait()
        self.output.close(); os.remove(self.output.name)
        self.api.close()
        if os.path.exists(self.pidfile): os.remove(self.pidfile)

    def post(self, path, body, key="gw"):
        # http.client directly: urllib consults the system proxy settings on every request, which
        # is slow enough on CI runners to make heartbeats arrive late.
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request("POST", path, body=json.dumps(body),
                         headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
            response = conn.getresponse()
            response.read()
            return response.status
        finally:
            conn.close()

    def wait_for_stop(self, seconds):
        end = time.time() + seconds
        while time.time() < end and not self.api.stops:
            time.sleep(0.1)
        return self.api.stops

    def test_stops_without_heartbeat(self):
        self.start()
        stops = self.wait_for_stop(20)
        self.assertEqual(len(stops), 1)
        path, auth, body = stops[0]
        self.assertEqual(path, "/v2/pods/pod123/action")
        self.assertEqual(auth, "Bearer pod-scoped")  # the key RunPod injects, never the user's
        self.assertEqual(body, {"action": "stop"})

    def test_heartbeats_keep_it_running_and_a_past_deadline_stops_it(self):
        self.start()
        for _ in range(12):  # 6 s, twice the heartbeat limit
            self.assertEqual(self.post("/heartbeat", {"deadline": None}), 200)
            time.sleep(0.5)
        self.assertEqual(self.api.stops, [])
        self.assertEqual(self.post("/heartbeat", {"deadline": time.time() - 1}), 200)
        self.assertEqual(len(self.wait_for_stop(10)), 1)

    def test_rejects_a_heartbeat_without_the_key(self):
        self.start()
        self.assertEqual(self.post("/heartbeat", {}, key="wrong"), 401)

    def test_stops_when_the_engine_has_exited(self):
        dead = subprocess.Popen(["true"]); dead.wait()
        self.start(PODLIGHT_HEARTBEAT_MINUTES="10")
        with open(self.pidfile, "w") as f: f.write(str(dead.pid))
        self.assertEqual(len(self.wait_for_stop(10)), 1)

    def test_a_past_deadline_from_the_environment_is_ignored(self):
        # A resumed pod keeps its creation-time environment; that old deadline must not fire.
        self.start(PODLIGHT_HEARTBEAT_MINUTES="10", PODLIGHT_DEADLINE=str(int(time.time()) - 3600))
        time.sleep(2)
        self.assertEqual(self.api.stops, [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
