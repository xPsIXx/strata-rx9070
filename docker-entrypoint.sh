#!/bin/sh
# Entry point for the Strata (gfx1201) container. The engine is compiled into the
# image at build time; this script never downloads anything on its own.
#
# Models: put the GGUF shards you want in $STRATA_MODELS (/models by default —
#   mount a volume there). Strata's --gguf-dir mode picks them up and setup skips
#   every download (the ~5 GB MTP draft layer is still fetched on first setup,
#   it cannot be avoided). Keep the published file names:
#     qwen  : Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-0000{1,2}-of-00002.gguf
#     coder : Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-0000{1,2}-of-00002.gguf
#   (one model's shards per run; a differently-named shard is matched by name)
#
# Env: FAMILY (qwen | coder), MODEL (IQ2_XS | Q2_0 | IQ3_XXS | IQ3_S | IQ1_M*),
#      CONTEXT, VISION (no|yes|cpu), HOST, PORT, API_KEY, KV (int8|q4_0|k8v4),
#      LOW_RAM (auto|on), STRATA_DATA (/data), STRATA_MODELS (/models), REINSTALL=1
# * IQ1_M is the Coder's only size: set FAMILY=coder MODEL=IQ1_M together.
set -e
cd /opt/strata || exit 1

STRATA_DATA="${STRATA_DATA:-/data}"
STRATA_MODELS="${STRATA_MODELS:-/models}"
FAMILY="${FAMILY:-qwen}"
MODEL="${MODEL:-IQ2_XS}"
CONTEXT="${CONTEXT:-32768}"
VISION="${VISION:-no}"          # AMD: no GPU image encoder yet; "cpu" builds the CPU one
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"            # container port; map it on the host with -p 8066:8080
API_KEY="${API_KEY:-}"
KV="${KV:-}"                    # empty: setup.py's own default (int8)
LOW_RAM="${LOW_RAM:-auto}"      # on: experts stream from the pack, not resident in RAM

# setup.py starts the newest strata-*.json it finds, so link in exactly the one
# this family and model were set up with. qwen has an empty family tag.
case "$FAMILY" in qwen) prefix="" ;; *) prefix="${FAMILY}-" ;; esac
tag="${prefix}$(printf '%s' "$MODEL" | tr 'A-Z' 'a-z')"
cfg="$STRATA_DATA/config/strata-$tag.json"
mkdir -p "$STRATA_DATA/config"

# REINSTALL=1 re-runs setup for an already-set-up model (new context/KV/API key).
if [ "${REINSTALL:-0}" = "1" ] || [ ! -f "$cfg" ]; then
  if [ -n "$(find "$STRATA_MODELS" -name '*.gguf' 2>/dev/null | head -1)" ]; then
    echo "Using the GGUFs in $STRATA_MODELS (no model download; ~5 GB MTP layer fetched once)."
    set -- --family "$FAMILY" --model "$MODEL" --context "$CONTEXT" --vision "$VISION" \
      --data-dir "$STRATA_DATA" --gguf-dir "$STRATA_MODELS" \
      --host "$HOST" --api-key "$API_KEY" --port "$PORT" --no-start --low-ram "$LOW_RAM"
  else
    echo "No GGUFs in $STRATA_MODELS — downloading the $FAMILY/$MODEL pack (set up a volume there to supply your own)."
    set -- --family "$FAMILY" --model "$MODEL" --context "$CONTEXT" --vision "$VISION" \
      --data-dir "$STRATA_DATA" \
      --host "$HOST" --api-key "$API_KEY" --port "$PORT" --no-start --low-ram "$LOW_RAM"
  fi
  if [ -n "$KV" ]; then set -- "$@" --kv "$KV"; fi
  .venv/bin/python setup.py --setup --yes "$@"
  [ -e "/opt/strata/strata-$tag.json" ] && { cmp -s "/opt/strata/strata-$tag.json" "$cfg" || cp -f "/opt/strata/strata-$tag.json" "$cfg"; }
else
  [ -e "/opt/strata/strata-$tag.json" ] || ln -s "$cfg" "/opt/strata/strata-$tag.json"
fi

# Later starts skip straight here: setup.py finds the installed config and
# launches serve/server.py (OpenAI + Anthropic API on $PORT).
set -- --port "$PORT"
exec .venv/bin/python setup.py "$@"
