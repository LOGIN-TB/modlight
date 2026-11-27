#!/usr/bin/env bash
# Modlight pod start. Runs as the container command in the stock vLLM or llama.cpp image (RunPod
# lets the entrypoint be replaced), so Modlight needs no image of its own.
#
# Starts the dead-man switch first, then the engine. The engine's output goes to a log the watchdog
# serves to Modlight, because RunPod keeps no container output once a pod has stopped. If the
# engine exits, the watchdog stops the pod after a short grace period, in which Modlight reads why.
set -uo pipefail

log() { printf '[modlight] %s\n' "$*" >&2; }

# GPU code the engine image lacks for this card (llama.cpp on A100, H100, H200, B200) is compiled
# on first use, which took two minutes on an H200. Keep it on the kept disk, so a resumed pod on
# the same machine skips that; the default cache is small and lives in the container.
export CUDA_CACHE_MAXSIZE=4294967296
if [[ -d /workspace && -w /workspace ]]; then
  export CUDA_CACHE_PATH=/workspace/.cache/nv-compute
  mkdir -p "$CUDA_CACHE_PATH"
fi

echo "$MODLIGHT_WATCHDOG_B64" | base64 -d > /tmp/modlight-watchdog.py
python3 /tmp/modlight-watchdog.py &
log "watchdog started"

if [[ "${MODLIGHT_ENGINE:-vllm}" == "llamacpp" ]]; then
  # llama.cpp for GGUF: downloads the chosen quantisation itself (-hf repo:quant, shards included).
  server=/app/llama-server
  [[ -x "$server" ]] || server="$(command -v llama-server)"
  parallel="${MODLIGHT_PARALLEL:-1}"
  args=(
    -hf "$MODLIGHT_MODEL:$MODLIGHT_QUANT"
    --host 0.0.0.0
    --port 8000
    --api-key "$MODLIGHT_API_KEY"
    --alias "$MODLIGHT_SERVED_NAME"
    -ngl all
    --jinja
    -np "$parallel"
    --no-mmproj
    --metrics
  )
  # The context is shared by the parallel slots, so each request gets the full window.
  [[ -n "${MODLIGHT_MAX_LEN:-}" ]] && args+=(-c "$((MODLIGHT_MAX_LEN * parallel))")
  # Several cards: layers are split across them.
  [[ "${MODLIGHT_TP:-1}" -gt 1 ]] && args+=(-sm layer)
  engine=("$server")
  engine_name="llama.cpp"
  model_label="$MODLIGHT_MODEL:$MODLIGHT_QUANT"
else
  args=(
    "$MODLIGHT_MODEL"
    --host 0.0.0.0
    --port 8000
    --api-key "$MODLIGHT_API_KEY"
    --served-model-name "$MODLIGHT_SERVED_NAME"
    --gpu-memory-utilization "${MODLIGHT_GPU_UTILIZATION:-0.94}"
  )
  [[ -n "${MODLIGHT_MAX_LEN:-}" ]] && args+=(--max-model-len "$MODLIGHT_MAX_LEN")
  # Hybrid-attention models need one recurrent cache block per concurrent sequence; vLLM's default
  # of 256 does not fit beside large weights and the engine refuses to start.
  [[ -n "${MODLIGHT_MAX_SEQS:-}" ]] && args+=(--max-num-seqs "$MODLIGHT_MAX_SEQS")
  # Several cards: split the model across them.
  [[ "${MODLIGHT_TP:-1}" -gt 1 ]] && args+=(--tensor-parallel-size "$MODLIGHT_TP")
  [[ -n "${MODLIGHT_TOOL_PARSER:-}" ]] && args+=(--enable-auto-tool-choice --tool-call-parser "$MODLIGHT_TOOL_PARSER")
  [[ -n "${MODLIGHT_REASONING_PARSER:-}" ]] && args+=(--reasoning-parser "$MODLIGHT_REASONING_PARSER")
  # An image-and-text model whose repository lacks the image processor (common in quantised
  # re-uploads) makes vLLM fail with "Can't load image processor". Serve its text part instead.
  text_only="${MODLIGHT_TEXT_ONLY:-$(python3 /tmp/modlight-watchdog.py text-only-check "$MODLIGHT_MODEL" 2>/dev/null || echo 0)}"
  if [[ "$text_only" == "1" ]]; then
    args+=(--language-model-only)
    log "no image processor in $MODLIGHT_MODEL: serving text only"
  fi
  engine=(vllm serve)
  engine_name="vLLM"
  model_label="$MODLIGHT_MODEL"
fi

engine_log=/tmp/modlight-engine.log
log "starting $engine_name for $model_label as $MODLIGHT_SERVED_NAME" 2>&1 | tee -a "$engine_log" >&2
# shellcheck disable=SC2086 # extra args are intentionally word-split
"${engine[@]}" "${args[@]}" ${MODLIGHT_EXTRA_ARGS:-} > >(tee -a "$engine_log") 2>&1 &
echo $! > /tmp/modlight-engine.pid
wait "$(cat /tmp/modlight-engine.pid)"
code=$?
echo "$code" > /tmp/modlight-engine.exit
log "engine exited with $code" 2>&1 | tee -a "$engine_log" >&2
# The watchdog stops the pod after its grace period; keep the container alive until then.
sleep 900
