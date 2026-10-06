#!/bin/sh
# Entry point for the Strata (gfx1201) container. The engine is compiled into the
# image at build time; the first start only downloads the model pack (~70 GB) and
# serves an OpenAI/Anthropic-compatible API. The install config lives on /data so
# a recreated container skips setup and goes straight to serving.
#
# Env: FAMILY (qwen | coder), MODEL (IQ2_XS | Q2_0 | IQ3_XXS | IQ3_S | IQ1_M*),
#      CONTEXT, VISION (no|yes|cpu), HOST, PORT, API_KEY, KV (int8|q4_0|k8v4),
#      LOW_RAM (auto|on), REINSTALL=1
# * IQ1_M is the Coder's only size: set FAMILY=coder MODEL=IQ1_M together.
set -e
cd /opt/strata || exit 1

STRATA_DATA="${STRATA_DATA:-/data}"
FAMILY="${FAMILY:-qwen}"
MODEL="${MODEL:-IQ2_XS}"
CONTEXT="${CONTEXT:-32768}"
VISION="${VISION:-no}"          # AMD: no GPU image encoder yet; "cpu" builds the CPU one
HOST="${HOST:-0.0.0.0}"
PORT="${PORT:-8080}"
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
  echo "Setting up $tag: downloading the model pack (~70 GB; the engine is already in the image)."
  set -- --family "$FAMILY" --model "$MODEL" --context "$CONTEXT" --vision "$VISION" \
    --data-dir "$STRATA_DATA" --host "$HOST" --api-key "$API_KEY" \
    --port "$PORT" --no-start --low-ram "$LOW_RAM"
  if [ -n "$KV" ]; then set -- "$@" --kv "$KV"; fi
  .venv/bin/python setup.py --setup --yes "$@"
  [ -e "/opt/strata/strata-$tag.json" ] && { cmp -s "/opt/strata/strata-$tag.json" "$cfg" || cp -f "/opt/strata/strata-$tag.json" "$cfg"; }
else
  [ -e "/opt/strata/strata-$tag.json" ] || ln -s "$cfg" "/opt/strata/strata-$tag.json"
fi

# Later starts skip straight here: setup.py finds the installed config and
# launches serve/server.py (OpenAI + Anthropic API on :8080).
set -- --port "$PORT"
exec .venv/bin/python setup.py "$@"
