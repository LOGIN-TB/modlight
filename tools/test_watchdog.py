"""Tests for the pod's dead-man switch (spec/pod/watchdog.py).

Runs the real watchdog against a fake RunPod API on localhost, with the timings shortened, and
checks that it stops the pod in each case it must, and only then. Standard library only:

    python3 -I tools/test_watchdog.py
"""
import http.client, importlib.util, json, os, shutil, socket, stat, subprocess, sys, tempfile, threading, time, unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

WATCHDOG = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "spec", "pod", "watchdog.py")


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
                    PODLIGHT_ENGINE_PID_FILE=self.pidfile, PODLIGHT_ENGINE_EXIT_FILE=self.pidfile + ".exit",
                    PODLIGHT_ENGINE_LOG=self.pidfile + ".log", PODLIGHT_ENGINE_EXIT_GRACE="0")
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
        for path in (self.pidfile, self.pidfile + ".exit", self.pidfile + ".log"):
            if os.path.exists(path): os.remove(path)

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

    def get(self, path, key="gw"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request("GET", path, headers={"Authorization": f"Bearer {key}"})
            response = conn.getresponse()
            return response.status, json.loads(response.read() or b"{}")
        finally:
            conn.close()

    def test_an_engine_exit_waits_for_the_grace_period_and_serves_the_log(self):
        # Podlight reads why the engine failed during the grace period; RunPod keeps no output.
        self.start(PODLIGHT_HEARTBEAT_MINUTES="10", PODLIGHT_ENGINE_EXIT_GRACE="3")
        with open(self.pidfile + ".log", "w") as f:
            f.write("INFO starting\nValueError: The model's max seq len is larger than the KV cache\n")
        with open(self.pidfile + ".exit", "w") as f:
            f.write("1")
        time.sleep(1.5)
        self.assertEqual(self.api.stops, [], "must not stop before the grace period")
        status, body = self.get("/")
        self.assertEqual((status, body["engineAlive"], body["engineExitCode"]), (200, False, 1))
        # The log size lets Podlight tell a working engine from a hung one.
        self.assertEqual(body["engineLogBytes"], os.path.getsize(self.pidfile + ".log"))
        status, log = self.get("/log")
        self.assertIn("KV cache", log["lines"][-1])
        self.assertEqual(self.get("/log", key="wrong")[0], 401)
        self.assertEqual(len(self.wait_for_stop(10)), 1)

    def test_a_past_deadline_from_the_environment_is_ignored(self):
        # A resumed pod keeps its creation-time environment; that old deadline must not fire.
        self.start(PODLIGHT_HEARTBEAT_MINUTES="10", PODLIGHT_DEADLINE=str(int(time.time()) - 3600))
        time.sleep(2)
        self.assertEqual(self.api.stops, [])


    def test_reports_telemetry_with_each_heartbeat(self):
        fake = tempfile.mkdtemp()
        self.addCleanup(shutil.rmtree, fake)
        smi = os.path.join(fake, "nvidia-smi")
        with open(smi, "w") as f:
            # In loop mode it keeps printing (55 %); a single call says 87 %. The watchdog must use the loop.
            # Readings alternate 30 % and 80 %: the sample reports their average, 55 %.
            f.write("#!/bin/sh\ncase \"$*\" in *--loop-ms*) while true; do echo '0, NVIDIA A40, 30, 43210, 46068, 55, 250.31, 300.00'; sleep 0.05;"
                    " echo '0, NVIDIA A40, 80, 43210, 46068, 55, 250.31, 300.00'; sleep 0.05; done;;\n"
                    "*) echo '0, NVIDIA A40, 87, 43210, 46068, 55, 250.31, 300.00';; esac\n")
        os.chmod(smi, os.stat(smi).st_mode | stat.S_IEXEC)
        cgroup = os.path.join(fake, "cgroup")
        os.mkdir(cgroup)
        files = {"cpu.stat": "usage_usec 1000000\n", "cpu.max": "200000 100000\n",
                 "memory.current": "3000000000\n", "memory.max": "50000000000\n", "memory.stat": "inactive_file 1000000000\n"}
        for name, text in files.items():
            with open(os.path.join(cgroup, name), "w") as f: f.write(text)
        engine = FakeEngine()
        self.addCleanup(engine.close)
        self.start(PODLIGHT_HEARTBEAT_MINUTES="10", PODLIGHT_TELEMETRY_SECONDS="0.3", PODLIGHT_NVIDIA_SMI=smi,
                   PODLIGHT_CGROUP=cgroup, PODLIGHT_ENGINE_URL=f"http://127.0.0.1:{engine.port}")
        time.sleep(0.5)
        # One second of CPU time later, on a container allowed two CPUs.
        with open(os.path.join(cgroup, "cpu.stat"), "w") as f: f.write("usage_usec 2000000\n")
        engine.generated = 1500
        time.sleep(0.8)
        status, body = self.get("/")
        self.assertEqual(status, 200)
        t = body["telemetry"]
        # Any average of alternating 30/80 readings lies strictly between them. A slow runner can put
        # a single reading (30 or 80) into one sample, so watch a few samples; a single call of
        # nvidia-smi would say 87 and must never show.
        seen = [t["gpus"][0]["utilPercent"]]
        deadline = time.time() + 5
        while not any(30 < u < 80 for u in seen) and time.time() < deadline:
            time.sleep(0.1)
            seen.append(self.get("/")[1]["telemetry"]["gpus"][0]["utilPercent"])
        self.assertTrue(any(30 < u < 80 for u in seen), f"averaged readings of the long-running nvidia-smi, got {seen}")
        self.assertNotIn(87, seen)
        self.assertEqual(t["gpus"][0]["memoryUsedBytes"], 43210 * 1024 * 1024)
        self.assertEqual(t["memoryUsedBytes"], 2_000_000_000)  # without the file cache
        self.assertEqual(t["memoryTotalBytes"], 50_000_000_000)
        self.assertIn("diskTotalBytes", t)
        self.assertEqual(t["engine"]["running"], 2)
        self.assertEqual(t["engine"]["kvCachePercent"], 41.0)
        self.assertEqual(engine.auth, "Bearer gw")
        # The rates covered the change once; later samples see no new tokens.
        status, beat = self.post_json("/heartbeat", {"deadline": None})
        self.assertEqual(status, 200)
        self.assertIn("telemetry", beat)

    def test_missing_sources_leave_a_working_heartbeat(self):
        self.start(PODLIGHT_HEARTBEAT_MINUTES="10", PODLIGHT_TELEMETRY_SECONDS="0.2", PODLIGHT_NVIDIA_SMI="/nonexistent",
                   PODLIGHT_CGROUP="/nonexistent", PODLIGHT_PROC="/nonexistent", PODLIGHT_ENGINE_URL="http://127.0.0.1:9")
        time.sleep(0.6)
        status, body = self.post_json("/heartbeat", {"deadline": None})
        self.assertEqual(status, 200)
        t = body["telemetry"]
        self.assertNotIn("gpus", t)
        self.assertNotIn("engine", t)
        self.assertNotIn("cpuPercent", t)

    def post_json(self, path, body, key="gw"):
        conn = http.client.HTTPConnection("127.0.0.1", self.port, timeout=5)
        try:
            conn.request("POST", path, body=json.dumps(body),
                         headers={"Authorization": f"Bearer {key}", "Content-Type": "application/json"})
            response = conn.getresponse()
            return response.status, json.loads(response.read() or b"{}")
        finally:
            conn.close()


class FakeEngine:
    """A /metrics endpoint as vLLM serves it."""
    def __init__(self):
        self.generated, self.auth = 1000, None
        outer = self

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                outer.auth = self.headers.get("Authorization")
                text = ("# HELP vllm:num_requests_running Number of requests in model execution batches.\n"
                        "# TYPE vllm:num_requests_running gauge\n"
                        'vllm:num_requests_running{engine="0",model_name="m"} 2.0\n'
                        'vllm:num_requests_waiting{engine="0",model_name="m"} 0.0\n'
                        'vllm:kv_cache_usage_perc{engine="0",model_name="m"} 0.41\n'
                        f'vllm:generation_tokens_total{{engine="0",model_name="m"}} {outer.generated}.0\n'
                        'vllm:generation_tokens_created{engine="0",model_name="m"} 1.7e9\n').encode()
                self.send_response(200); self.send_header("Content-Length", str(len(text))); self.end_headers()
                self.wfile.write(text)

            def log_message(self, *a): pass

        self.port = free_port()
        self.server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


def load_watchdog():
    spec = importlib.util.spec_from_file_location("watchdog", WATCHDOG)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class TelemetryParsingTest(unittest.TestCase):
    """The parsers on their own, with the shapes the cases in spec/cases/telemetry.json name."""
    w = load_watchdog()

    def test_cases(self):
        path = os.path.join(os.path.dirname(WATCHDOG), "..", "cases", "telemetry.json")
        with open(path) as f:
            cases = json.load(f)["cases"]
        for case in cases:
            with self.subTest(case["id"]):
                given = case["input"]
                if case["function"] == "nvidiaSmi":
                    got = self.w.parse_nvidia_smi(given["csv"])
                else:
                    values = self.w.engine_values(self.w.parse_prometheus(given["metrics"]))
                    previous = self.w.engine_values(self.w.parse_prometheus(given["previousMetrics"])) if "previousMetrics" in given else None
                    got = self.w.engine_telemetry(values, previous, given.get("seconds"))
                self.assertEqual(got, case["expected"])


class FakeHub:
    """Hugging Face's model API and file downloads, for the text-only check."""
    def __init__(self, files, config):
        hub = self
        hub.files, hub.config, hub.auth = files, config, []

        class Handler(BaseHTTPRequestHandler):
            def do_GET(self):
                hub.auth.append(self.headers.get("Authorization"))
                if self.path.startswith("/api/models/"):
                    body = {"siblings": [{"rfilename": f} for f in hub.files]}
                elif self.path.endswith("/resolve/main/config.json"):
                    body = hub.config
                else:
                    self.send_response(404); self.end_headers(); return
                data = json.dumps(body).encode()
                self.send_response(200); self.send_header("Content-Length", str(len(data))); self.end_headers()
                self.wfile.write(data)
            def log_message(self, *a): pass

        self.port = free_port()
        self.server = ThreadingHTTPServer(("127.0.0.1", self.port), Handler)
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def close(self):
        self.server.shutdown()


class TextOnlyCheckTest(unittest.TestCase):
    """An image-and-text model without its image processor runs text-only (vLLM --language-model-only)."""
    w = load_watchdog()
    vision = {"architectures": ["Qwen3_5MoeForConditionalGeneration"], "vision_config": {}, "text_config": {}}

    def test_the_rule(self):
        self.assertTrue(self.w.needs_text_only(self.vision, {"config.json", "tokenizer.json"}))
        self.assertFalse(self.w.needs_text_only(self.vision, {"config.json", "preprocessor_config.json"}))
        self.assertFalse(self.w.needs_text_only(self.vision, {"config.json", "processor_config.json"}))
        self.assertFalse(self.w.needs_text_only({"architectures": ["Qwen3ForCausalLM"]}, {"config.json"}))
        self.assertTrue(self.w.needs_text_only({"audio_config": {}}, set()))

    def run_check(self, hub, token=None):
        env = dict(os.environ, HF_ENDPOINT=f"http://127.0.0.1:{hub.port}")
        env.pop("HF_TOKEN", None)
        if token: env["HF_TOKEN"] = token
        out = subprocess.run([sys.executable, "-I", WATCHDOG, "text-only-check", "org/model"], env=env,
                             capture_output=True, text=True, timeout=30)
        return out.stdout.strip()

    def test_asks_the_hub_from_the_command_line(self):
        hub = FakeHub(["config.json", "model.safetensors.index.json", "tokenizer.json"], self.vision)
        self.addCleanup(hub.close)
        self.assertEqual(self.run_check(hub, token="hf_x"), "1")
        self.assertIn("Bearer hf_x", hub.auth, "a gated model needs the token")
        hub.files.append("preprocessor_config.json")
        self.assertEqual(self.run_check(hub), "0")

    def test_an_unreachable_hub_changes_nothing(self):
        env = dict(os.environ, HF_ENDPOINT=f"http://127.0.0.1:{free_port()}")
        out = subprocess.run([sys.executable, "-I", WATCHDOG, "text-only-check", "org/model"], env=env,
                             capture_output=True, text=True, timeout=30)
        self.assertEqual(out.stdout.strip(), "0")


if __name__ == "__main__":
    unittest.main(verbosity=2)
