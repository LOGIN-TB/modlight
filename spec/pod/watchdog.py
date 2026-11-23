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
import json, os, socketserver, subprocess, sys, threading, time, urllib.request, urllib.error
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

POD_ID = os.environ.get("RUNPOD_POD_ID", "")
RUNPOD_KEY = os.environ.get("RUNPOD_API_KEY", "")
GATEWAY_KEY = os.environ.get("PODLIGHT_API_KEY", "")
MINUTES = float(os.environ.get("PODLIGHT_HEARTBEAT_MINUTES", "15"))
BOOT_GRACE_MINUTES = float(os.environ.get("PODLIGHT_BOOT_GRACE_MINUTES", "20"))
PORT = int(os.environ.get("PODLIGHT_WATCHDOG_PORT", "8001"))
HOST = os.environ.get("PODLIGHT_WATCHDOG_HOST", "0.0.0.0")  # all interfaces in the pod; tests use loopback
API = os.environ.get("PODLIGHT_RUNPOD_API", "https://api.runpod.io")  # overridable for tests only
CHECK_SECONDS = float(os.environ.get("PODLIGHT_CHECK_SECONDS", "15"))
ENGINE_PID_FILE = os.environ.get("PODLIGHT_ENGINE_PID_FILE", "/tmp/podlight-engine.pid")
ENGINE_EXIT_FILE = os.environ.get("PODLIGHT_ENGINE_EXIT_FILE", "/tmp/podlight-engine.exit")
ENGINE_LOG = os.environ.get("PODLIGHT_ENGINE_LOG", "/tmp/podlight-engine.log")
# After the engine exits, wait this long before stopping, so Podlight can read the reason.
ENGINE_EXIT_GRACE = float(os.environ.get("PODLIGHT_ENGINE_EXIT_GRACE", "120"))
# Telemetry: how often it is measured, and where. The paths are overridable for tests only.
TELEMETRY_SECONDS = float(os.environ.get("PODLIGHT_TELEMETRY_SECONDS", "5"))
NVIDIA_SMI = os.environ.get("PODLIGHT_NVIDIA_SMI", "nvidia-smi")
CGROUP = os.environ.get("PODLIGHT_CGROUP", "/sys/fs/cgroup")
PROC = os.environ.get("PODLIGHT_PROC", "/proc")
ENGINE_URL = os.environ.get("PODLIGHT_ENGINE_URL", "http://127.0.0.1:8000")
DISKS = {"disk": os.environ.get("PODLIGHT_DISK_PATH", "/"), "volume": os.environ.get("PODLIGHT_VOLUME_PATH", "/workspace")}

state = {
    "started": time.time(),
    # Until the first heartbeat arrives the engine is still downloading; allow extra time then.
    "last_heartbeat": None,
    # A resumed pod keeps the environment it was created with, so its deadline may be long past;
    # only a future one counts. The app's heartbeat sets the current one.
    "deadline": (lambda d: d if d and d > time.time() else None)(float(os.environ.get("PODLIGHT_DEADLINE") or 0)),
    "stopping": None,
    "engine_exited_at": None,
}
lock = threading.Lock()
# Direct connections only: the pod has no proxy, and resolving system proxy settings can stall.
opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))


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
            with opener.open(req, timeout=20) as r:
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


def engine_exit_code():
    try:
        return int(open(ENGINE_EXIT_FILE).read().strip())
    except (OSError, ValueError):
        return None


def engine_log_tail(lines=250):
    try:
        with open(ENGINE_LOG, "rb") as f:
            f.seek(0, 2)
            f.seek(max(0, f.tell() - 160_000))
            return f.read().decode("utf-8", "replace").splitlines()[-lines:]
    except OSError:
        return []


def engine_alive():
    if engine_exit_code() is not None:
        return False
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
            with lock:
                if state["engine_exited_at"] is None:
                    state["engine_exited_at"] = now
                    log(f"engine exited (code {engine_exit_code()}); stopping in {ENGINE_EXIT_GRACE:g} s")
                exited_at = state["engine_exited_at"]
            if now - exited_at >= ENGINE_EXIT_GRACE:
                stop(f"engine exited with code {engine_exit_code()}")
        time.sleep(CHECK_SECONDS)


# MARK: telemetry
#
# What the pod is doing, measured here because RunPod's API does not say how much GPU memory or
# disk is in use. Sent back with every heartbeat. A source that is missing leaves out its fields;
# nothing here may break a heartbeat.

def _number(text):
    try:
        value = float(text.strip())
    except (ValueError, AttributeError):
        return None  # "[N/A]", "[Not Supported]"
    return int(value) if value.is_integer() else value


def parse_nvidia_smi(text):
    """CSV from --query-gpu=index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,
    power.draw,power.limit --format=csv,noheader,nounits."""
    gpus = []
    for line in text.strip().splitlines():
        cells = [c.strip() for c in line.split(",")]
        if len(cells) < 8:
            continue
        index, name, util, used, total, temp, power, limit = cells[:8]
        mib = lambda v: None if _number(v) is None else int(_number(v) * 1024 * 1024)
        gpus.append({"index": _number(index), "name": name, "utilPercent": _number(util),
                     "memoryUsedBytes": mib(used), "memoryTotalBytes": mib(total),
                     "temperatureC": _number(temp), "powerW": _number(power), "powerLimitW": _number(limit)})
    return gpus


def parse_prometheus(text):
    """Metric name -> values, one per label set. Comments are skipped."""
    metrics = {}
    for line in text.splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if "}" in line:
            name, rest = line.split("{", 1)[0], line[line.rindex("}") + 1:]
        else:
            name, _, rest = line.partition(" ")
        fields = rest.split()
        value = _number(fields[0]) if fields else None
        if name and value is not None and abs(value) != float("inf") and value == value:
            metrics.setdefault(name, []).append(float(value))
    return metrics


# Engine metric names: vLLM first, then llama.cpp (needs --metrics). Older vLLM used gpu_cache.
ENGINE_METRICS = {
    "running": (["vllm:num_requests_running", "llamacpp:requests_processing"], sum),
    "waiting": (["vllm:num_requests_waiting", "llamacpp:requests_deferred"], sum),
    "kvCache": (["vllm:kv_cache_usage_perc", "vllm:gpu_cache_usage_perc", "llamacpp:kv_cache_usage_ratio"], max),
    "promptTokens": (["vllm:prompt_tokens_total", "llamacpp:prompt_tokens_total"], sum),
    "generationTokens": (["vllm:generation_tokens_total", "llamacpp:tokens_predicted_total"], sum),
}


def engine_values(metrics):
    values = {}
    for key, (names, combine) in ENGINE_METRICS.items():
        for name in names:
            if metrics.get(name):
                values[key] = combine(metrics[name])
                break
    return values


def engine_telemetry(values, previous, seconds):
    """Requests, KV cache and token rates since the previous sample. A counter that went down
    (the engine restarted) gives no rate."""
    out = {}
    for key in ("running", "waiting"):
        if key in values:
            out[key] = int(values[key])
    if "kvCache" in values:
        out["kvCachePercent"] = round(values["kvCache"] * 100, 1)
    for key, field in (("promptTokens", "promptTokensPerSecond"), ("generationTokens", "generationTokensPerSecond")):
        if previous and seconds and seconds > 0 and key in values and key in previous and values[key] >= previous[key]:
            out[field] = round((values[key] - previous[key]) / seconds, 1)
    return out


def _read(path):
    try:
        with open(path) as f:
            return f.read()
    except OSError:
        return None


def cpu_seconds():
    """CPU time the container has used, and how many CPUs it may use."""
    stat = _read(f"{CGROUP}/cpu.stat")  # cgroup v2
    if stat:
        usage = dict(line.split() for line in stat.splitlines() if len(line.split()) == 2).get("usage_usec")
        quota = (_read(f"{CGROUP}/cpu.max") or "max").split()
        cpus = int(quota[0]) / int(quota[1]) if quota[0] != "max" and len(quota) > 1 else os.cpu_count()
        if usage is not None:
            return int(usage) / 1e6, cpus
    usage = _read(f"{CGROUP}/cpuacct/cpuacct.usage")  # cgroup v1
    if usage:
        return int(usage) / 1e9, os.cpu_count()
    fields = (_read(f"{PROC}/stat") or "").split("\n", 1)[0].split()[1:]
    if len(fields) >= 4:  # whole machine: busy jiffies
        busy = sum(int(v) for v in fields[:8]) - int(fields[3]) - (int(fields[4]) if len(fields) > 4 else 0)
        return busy / os.sysconf("SC_CLK_TCK"), os.cpu_count()
    return None, None


def memory():
    """Used and total bytes, as `docker stats` counts them: without reclaimable file cache."""
    current, limit = _read(f"{CGROUP}/memory.current"), _read(f"{CGROUP}/memory.max")
    stat_name = "inactive_file"
    if current is None:  # cgroup v1
        current, limit = _read(f"{CGROUP}/memory/memory.usage_in_bytes"), _read(f"{CGROUP}/memory/memory.limit_in_bytes")
        stat_name = "total_inactive_file"
    stat = _read(f"{CGROUP}/memory.stat") or _read(f"{CGROUP}/memory/memory.stat") or ""
    meminfo = dict((l.split(":")[0], l.split()[1]) for l in (_read(f"{PROC}/meminfo") or "").splitlines() if ":" in l)
    total = int(meminfo["MemTotal"]) * 1024 if "MemTotal" in meminfo else None
    if limit and limit.strip().isdigit() and (total is None or int(limit) < total):
        total = int(limit)
    if current is None or not current.strip().isdigit():
        if "MemAvailable" in meminfo and total:
            return total - int(meminfo["MemAvailable"]) * 1024, total
        return None, total
    inactive = dict(l.split() for l in stat.splitlines() if len(l.split()) == 2).get(stat_name, "0")
    return max(0, int(current) - int(inactive)), total


def disk(path):
    try:
        if path != "/" and not os.path.ismount(path):
            return None, None
        st = os.statvfs(path)
        return (st.f_blocks - st.f_bfree) * st.f_frsize, st.f_blocks * st.f_frsize
    except OSError:
        return None, None


telemetry_state = {"latest": None, "cpu": None, "engine": None, "time": None}
GPU_QUERY = "index,name,utilization.gpu,memory.used,memory.total,temperature.gpu,power.draw,power.limit"
# One long-running nvidia-smi, read every second. Starting nvidia-smi for every sample
# re-initialises the driver's counters, and the first reading after that often says 0 % load even
# while the card is busy (seen on 2026-11-22: 0 % at 297 tokens/s and 49 of 70 W). Its load figure
# covers only the last fraction of a second, so the sample reports the average over the readings
# since the previous sample: a short burst of requests between two samples still shows.
gpu_lines = {"cards": {}, "loads": {}, "time": 0.0}
GPU_READ_MS = int(os.environ.get("PODLIGHT_GPU_READ_MS", "1000"))


def gpu_reader():
    while True:
        try:
            proc = subprocess.Popen([NVIDIA_SMI, f"--query-gpu={GPU_QUERY}", "--format=csv,noheader,nounits",
                                     f"--loop-ms={GPU_READ_MS}"],
                                    stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, text=True)
        except OSError:
            return  # no nvidia-smi in this image
        for line in proc.stdout:
            for gpu in parse_nvidia_smi(line):
                with lock:
                    gpu_lines["cards"][gpu["index"]] = gpu
                    if gpu["utilPercent"] is not None:
                        gpu_lines["loads"].setdefault(gpu["index"], []).append(gpu["utilPercent"])
                    gpu_lines["time"] = time.time()
        proc.wait()
        time.sleep(10)  # it ended (driver trouble): start it again


def gpus_now():
    """Fresh lines from the long-running nvidia-smi, else one call of its own."""
    with lock:
        fresh = time.time() - gpu_lines["time"] < max(15, TELEMETRY_SECONDS * 3) and gpu_lines["cards"]
        if fresh:
            cards, loads = dict(gpu_lines["cards"]), gpu_lines["loads"]
            gpu_lines["loads"] = {}
    if fresh:
        out = []
        for k in sorted(cards, key=lambda k: (k is None, k or 0)):
            gpu = dict(cards[k])
            if loads.get(k):
                gpu["utilPercent"] = round(sum(loads[k]) / len(loads[k]), 1)
            out.append(gpu)
        return out
    result = subprocess.run([NVIDIA_SMI, f"--query-gpu={GPU_QUERY}", "--format=csv,noheader,nounits"],
                            capture_output=True, text=True, timeout=3)
    return parse_nvidia_smi(result.stdout) if result.returncode == 0 else None


def measure():
    now = time.time()
    previous_time = telemetry_state["time"]
    seconds = now - previous_time if previous_time else None
    sample = {"time": int(now)}
    try:
        used, cpus = cpu_seconds()
        if used is not None:
            prev = telemetry_state["cpu"]
            if prev and seconds and cpus:
                sample["cpuPercent"] = round(max(0.0, min(100.0, (used - prev) / seconds / cpus * 100)), 1)
            telemetry_state["cpu"] = used
    except Exception as e:
        log(f"telemetry cpu: {e}")
    try:
        used, total = memory()
        if used is not None: sample["memoryUsedBytes"] = used
        if total is not None: sample["memoryTotalBytes"] = total
    except Exception as e:
        log(f"telemetry memory: {e}")
    for key, path in DISKS.items():
        used, total = disk(path)
        if used is not None and total:
            sample[f"{key}UsedBytes"], sample[f"{key}TotalBytes"] = used, total
    try:
        gpus = gpus_now()
        if gpus is not None:
            sample["gpus"] = gpus
    except (OSError, subprocess.SubprocessError):
        pass  # no nvidia-smi in this image
    try:
        req = urllib.request.Request(f"{ENGINE_URL}/metrics", headers={"Authorization": f"Bearer {GATEWAY_KEY}"})
        with opener.open(req, timeout=2) as r:
            values = engine_values(parse_prometheus(r.read().decode("utf-8", "replace")))
        sample["engine"] = engine_telemetry(values, telemetry_state["engine"], seconds)
        telemetry_state["engine"] = values
    except Exception:
        telemetry_state["engine"] = None  # engine still loading, or no metrics
    telemetry_state["time"] = now
    telemetry_state["latest"] = sample


def telemetry_loop():
    while True:
        try:
            measure()
        except Exception as e:  # never let telemetry end the thread
            log(f"telemetry: {e}")
        time.sleep(TELEMETRY_SECONDS)


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
                "engineExitCode": engine_exit_code(),
                "uptimeSeconds": int(time.time() - state["started"]),
                "telemetry": telemetry_state["latest"],
            }

    def do_GET(self):
        if not self._authorised():
            return self._reply(401, {"error": "unauthorized"})
        if self.path == "/log":
            return self._reply(200, {"lines": engine_log_tail()})
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


# --- Text-only check, asked by boot.sh before vLLM starts ----------------------------------------

PROCESSOR_FILES = ("preprocessor_config.json", "processor_config.json")


def needs_text_only(config, files):
    """True for a model whose config describes images (or audio) while its repository carries no
    processor for them. vLLM then fails with "Can't load image processor"; with
    --language-model-only it serves the text part, which is all an agent needs."""
    multimodal = any(key in (config or {}) for key in ("vision_config", "audio_config"))
    return multimodal and not any(name in files for name in PROCESSOR_FILES)


def text_only_check(repo):
    """Asks Hugging Face for the repository's files and config. Any failure answers False: then
    vLLM starts as before."""
    endpoint = os.environ.get("HF_ENDPOINT", "https://huggingface.co").rstrip("/")
    headers = {"User-Agent": "podlight-pod"}
    token = os.environ.get("HF_TOKEN")
    if token:
        headers["Authorization"] = "Bearer " + token
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    try:
        with opener.open(urllib.request.Request(f"{endpoint}/api/models/{repo}", headers=headers), timeout=20) as r:
            files = {s.get("rfilename") for s in json.load(r).get("siblings", [])}
        with opener.open(urllib.request.Request(f"{endpoint}/{repo}/resolve/main/config.json", headers=headers), timeout=20) as r:
            config = json.load(r)
    except Exception:
        return False
    return needs_text_only(config, files)


class Server(ThreadingHTTPServer):
    # http.server looks up its own host name with getfqdn() when binding. That reverse DNS lookup
    # can hang for many seconds (seen on CI runners); the name is never used here.
    def server_bind(self):
        socketserver.TCPServer.server_bind(self)
        self.server_name, self.server_port = str(self.server_address[0]), self.server_address[1]


if __name__ == "__main__":
    if len(sys.argv) > 2 and sys.argv[1] == "stop":
        stop(" ".join(sys.argv[2:]))
        sys.exit(0)
    if len(sys.argv) > 2 and sys.argv[1] == "text-only-check":
        print("1" if text_only_check(sys.argv[2]) else "0")
        sys.exit(0)
    if not POD_ID or not RUNPOD_KEY:
        log("RUNPOD_POD_ID or RUNPOD_API_KEY missing: the pod cannot stop itself")
    threading.Thread(target=check_loop, daemon=True).start()
    if TELEMETRY_SECONDS > 0:
        threading.Thread(target=gpu_reader, daemon=True).start()
        threading.Thread(target=telemetry_loop, daemon=True).start()
    log(f"watching: heartbeat every {MINUTES:g} min, deadline {state['deadline']}")
    Server((HOST, PORT), Handler).serve_forever()
