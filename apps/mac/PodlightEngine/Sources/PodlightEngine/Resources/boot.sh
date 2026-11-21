#!/usr/bin/env bash
# Podlight pod start. Runs as the container command in the stock vLLM image (RunPod lets the
# entrypoint be replaced), so Podlight needs no image of its own.
#
# Starts the dead-man switch first, then the engine. If the engine exits, the pod stops itself:
# a pod that cannot answer must not keep billing.
set -uo pipefail

log() { printf '[podlight] %s\n' "$*" >&2; }

echo "$PODLIGHT_WATCHDOG_B64" | base64 -d > /tmp/podlight-watchdog.py
python3 /tmp/podlight-watchdog.py &
log "watchdog started"

args=(
  "$PODLIGHT_MODEL"
  --host 0.0.0.0
  --port 8000
  --api-key "$PODLIGHT_API_KEY"
  --served-model-name "$PODLIGHT_SERVED_NAME"
  --gpu-memory-utilization "${PODLIGHT_GPU_UTILIZATION:-0.94}"
)
[[ -n "${PODLIGHT_MAX_LEN:-}" ]] && args+=(--max-model-len "$PODLIGHT_MAX_LEN")
# Hybrid-attention models need one recurrent cache block per concurrent sequence; vLLM's default
# of 256 does not fit beside large weights and the engine refuses to start.
[[ -n "${PODLIGHT_MAX_SEQS:-}" ]] && args+=(--max-num-seqs "$PODLIGHT_MAX_SEQS")
# Several cards: split the model across them.
[[ "${PODLIGHT_TP:-1}" -gt 1 ]] && args+=(--tensor-parallel-size "$PODLIGHT_TP")
[[ -n "${PODLIGHT_TOOL_PARSER:-}" ]] && args+=(--enable-auto-tool-choice --tool-call-parser "$PODLIGHT_TOOL_PARSER")
[[ -n "${PODLIGHT_REASONING_PARSER:-}" ]] && args+=(--reasoning-parser "$PODLIGHT_REASONING_PARSER")

log "starting vLLM for $PODLIGHT_MODEL as $PODLIGHT_SERVED_NAME"
# shellcheck disable=SC2086 # extra args are intentionally word-split
vllm serve "${args[@]}" ${PODLIGHT_EXTRA_ARGS:-} &
echo $! > /tmp/podlight-engine.pid
wait "$(cat /tmp/podlight-engine.pid)"
code=$?
log "engine exited with $code"
python3 /tmp/podlight-watchdog.py stop "engine exited with code $code"
# Keep the container alive so the stop request can finish and the logs stay readable.
sleep 600
