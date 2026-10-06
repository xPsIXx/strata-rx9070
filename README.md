# Strata for AMD RDNA (gfx1201)

Self-contained Docker image for [Strata](https://github.com/Niko1221/Strata) —
the 125B MoE engine — on an **RX 9070 / 9070 XT** (gfx1201, 16 GB). The C++
engine is compiled at `docker build` time; the container serves an
OpenAI/Anthropic-compatible API. Models are **not** auto-downloaded — you put
the GGUF shards in `/models` yourself (see below).

Built for a specific host: Ryzen 5 5700X (AVX2, **no** AVX-512) + 64 GB RAM.
The Dockerfile's `-DSTRATA_PORTABLE=ON` is what makes that safe — see below.

## What it is / isn't

- **Is:** a standalone service container, like the Bonsai sidecar. Run it next
  to llama-swap and add `http://<host>:8066/v1` as another OpenAI provider in
  OpenWebUI (any API key works if you don't set `API_KEY`).
- **Isn't:** a drop-in binary for llama-swap's bin folder. Strata is an engine +
  Python server + model pack, not a single `llama-server` replacement, and its
  model packs (GSQ-RCO / Unsloth shards) are only runnable by Strata itself —
  llama.cpp cannot load them.

## Run

```sh
docker run -d --name strata \
  --device /dev/kfd --device /dev/dri \
  --ulimit memlock=-1:-1 \
  -p 8066:8080 \
  -v /mnt/user/appdata/strata:/data \
  -v /mnt/user/AI/llama-swap/strata:/models \
  ghcr.io/xpsixx/strata-rx9070:latest
```

- `/models` — **your** GGUF shards (see below). Mounted at a subfolder of the
  llama-swap model dir so both engines share one location; it's kept separate
  because Strata's shard scanner globs the folder and would trip over
  llama-swap's GGUFs. The container never fetches a model on its own; if the
  folder is empty it falls back to setup.py's download.
- `/data` — Strata's install config + derived files (pack index, MTP layer).
  Recreating the container is free.

### Putting a model in

Download the shards yourself (e.g. `huggingface-cli` or browser) into
`/mnt/user/AI/llama-swap/strata`, keeping the published names:

| family/model | files (in `/mnt/user/AI/llama-swap/strata`) | size |
|---|---|---|
| `FAMILY=qwen MODEL=IQ2_XS` ← start here | `Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-0000{1,2}-of-00002.gguf` | ≈68 GB |
| `FAMILY=coder MODEL=IQ1_M` (low-RAM floor) | `Qwen3.8-Flash-Next-GSQ-RCO-IQ1_M-0000{1,2}-of-00002.gguf` | ≈58 GB |
| `FAMILY=swift MODEL=IQ2_XS` (shorter answers) | `Swift-Qwen3.8-Flash-Next-GSQ-RCO-IQ2_XS-0000{1,2}-of-00002.gguf` | ≈68 GB |

from `ISTA-DASLab/Qwen3.8-Flash-Next-GSQ-RCO-GGUF` (qwen),
`.../GSQ-RCO-Coder-GGUF` (coder) or `ukisai/Swift-1.5-Qwen3.8-Flash-Next-GSQ-RCO-GGUF`
(swift). Then set `FAMILY`/`MODEL` to match and start — setup runs once in
Strata's own `--gguf-dir` mode (no download; it still fetches the ~5 GB MTP
draft layer, that can't be skipped) and serves.

The Unsloth family (`UD-IQ4_XS`) is also engine-supported but needs SSD
streaming + per-run tuning — not worth it on this box; `UD-Q4_K_XL` is
NVIDIA-only.

### Model choice and RAM

`MODEL` picks the quant of Qwen3.8-Flash-Next (Strata's only model). "Coder" in
Strata's docs is a separate *family* (`FAMILY=coder`) whose only size is IQ1_M —
half the experts kept, chosen for code: it's the RAM floor but weaker outside
code. Set `FAMILY=coder MODEL=IQ1_M` together (the pairing is validated).

| env | experts in RAM | notes                                  |
|-----|----------------|----------------------------------------|
| `FAMILY=qwen MODEL=IQ2_XS` | ≈48 GB | **start here** — fastest decode (~60 tok/s) |
| `FAMILY=swift MODEL=IQ2_XS` | ≈48 GB | same speed/RAM, ~63% shorter answers    |
| `FAMILY=coder MODEL=IQ1_M` | ≈32 GB | "Coder" — low-RAM floor; best at code, ~44 tok/s |

(Also available: `IQ3_XXS`, `IQ3_S` — bigger and slower to load.)

### Running it alongside llama-swap

Strata's experts live in system RAM while the model is up. If you run both
containers, unload llama-swap's current model first (its loaded GGUF + KV
cache are gone) so there's headroom — that's the plan: same model location,
one engine resident at a time. With ~29 GB free right now and IQ2_XS wanting
~48 GB for its experts, llama-swap unloaded is required for IQ2_XS; the Coder
(IQ1_M, ~32 GB) is the one that can share the box with other containers.

### Env vars
`FAMILY` (qwen|swift|coder), `MODEL` (IQ2_XS|Q2_0|IQ3_XXS|IQ3_S|IQ1_M*),
`CONTEXT` (32768), `PORT` (8080 — map it with `-p 8066:8080`), `HOST`,
`API_KEY`, `KV` (int8|q4_0|k8v4), `VISION` (no|cpu — AMD has no GPU image
encoder yet), `LOW_RAM` (auto|on), `STRATA_MODELS` (/models), `REINSTALL=1` to
re-run setup after changing any of them.

## Why the Dockerfile is shaped this way

- **ROCm base:** `rocm/dev-ubuntu-24.04:7.14.1-full` — one image carries both the
  HIP toolchain (build) and the runtime libraries, so build and run never disagree.
  Strata's own HIP benchmarks use ROCm 7.x; its system minimum is 7.0.
- **Portability:** GitHub runners are AVX-512; the host CPU is not. Strata's
  `setup.py` normally leaves ggml at `GGML_NATIVE=ON`, which would bake in the
  runner's ISA and crash the host with *Illegal instruction* (same bug class as
  the ROCmFPX build). `-DSTRATA_PORTABLE=ON` is Strata's own switch for exactly
  this: AVX2 baseline, no AVX-512 — and it matches what `setup.py` expects on an
  AVX2 host (empty `isa_floor`), so the runtime setup pass keeps the compiled
  engine instead of recompiling.
- **BUILD.json:** generated by Strata's own `setup.py` module at build time, so
  the source hash can't drift; a drifted stamp would make the container try to
  recompile on start.
- **llama.cpp** is fetched at the commit Strata pins (`3cf03257`, via its own
  `LLAMA_CPP_ZIP`), so the engine's ggml matches the source tree.

## Build / update

Push to the repo → GitHub Actions builds and pushes to GHCR (tags: `latest`,
short SHA, timestamp). To move to a newer Strata release, bump `STRATA_REF` in
the Dockerfile and push; the engine rebuilds automatically because the source
hash changes.
