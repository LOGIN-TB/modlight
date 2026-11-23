#!/usr/bin/env bash
# Podlight pod start. Runs as the container command in the stock vLLM or llama.cpp image (RunPod
# lets the entrypoint be replaced), so Podlight needs no image of its own.
#
# Starts the dead-man switch first, then the engine. The engine's output goes to a log the watchdog
# serves to Podlight, because RunPod keeps no container output once a pod has stopped. If the
# engine exits, the watchdog stops the pod after a short grace period, in which Podlight reads why.
set -uo pipefail

log() { printf '[podlight] %s\n' "$*" >&2; }

echo "$PODLIGHT_WATCHDOG_B64" | base64 -d > /tmp/podlight-watchdog.py
python3 /tmp/podlight-watchdog.py &
log "watchdog started"

if [[ "${PODLIGHT_ENGINE:-vllm}" == "llamacpp" ]]; then
  # llama.cpp for GGUF: downloads the chosen quantisation itself (-hf repo:quant, shards included).
  server=/app/llama-server
  [[ -x "$server" ]] || server="$(command -v llama-server)"
  parallel="${PODLIGHT_PARALLEL:-1}"
  args=(
    -hf "$PODLIGHT_MODEL:$PODLIGHT_QUANT"
    --host 0.0.0.0
    --port 8000
    --api-key "$PODLIGHT_API_KEY"
    --alias "$PODLIGHT_SERVED_NAME"
    -ngl all
    --jinja
    -np "$parallel"
    --no-mmproj
    --metrics
  )
  # The context is shared by the parallel slots, so each request gets the full window.
  [[ -n "${PODLIGHT_MAX_LEN:-}" ]] && args+=(-c "$((PODLIGHT_MAX_LEN * parallel))")
  # Several cards: layers are split across them.
  [[ "${PODLIGHT_TP:-1}" -gt 1 ]] && args+=(-sm layer)
  engine=("$server")
  engine_name="llama.cpp"
  model_label="$PODLIGHT_MODEL:$PODLIGHT_QUANT"
else
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
  engine=(vllm serve)
  engine_name="vLLM"
  model_label="$PODLIGHT_MODEL"
fi

engine_log=/tmp/podlight-engine.log
log "starting $engine_name for $model_label as $PODLIGHT_SERVED_NAME" 2>&1 | tee -a "$engine_log" >&2
# shellcheck disable=SC2086 # extra args are intentionally word-split
"${engine[@]}" "${args[@]}" ${PODLIGHT_EXTRA_ARGS:-} > >(tee -a "$engine_log") 2>&1 &
echo $! > /tmp/podlight-engine.pid
wait "$(cat /tmp/podlight-engine.pid)"
code=$?
echo "$code" > /tmp/podlight-engine.exit
log "engine exited with $code" 2>&1 | tee -a "$engine_log" >&2
# The watchdog stops the pod after its grace period; keep the container alive until then.
sleep 900
