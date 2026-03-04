# vllm-flox-monitoring

Monitoring stack for vLLM inference servers — Prometheus scraping, Grafana dashboards, and pre-configured plugins, packaged as a Flox catalog package (`flox/vllm-flox-monitoring`).

Designed to work with `flox/vllm-flox-runtime` but usable with any vLLM deployment that exposes `/metrics`.

## What's in the package

| Output | Contents |
|--------|----------|
| `$out/bin/vllm-monitoring-init` | Sourced from `on-activate`; creates mutable dirs, seeds plugins/config, exports `GF_*` vars, generates `prometheus.yml` |
| `$out/bin/vllm-monitoring-prometheus` | Wrapper that runs `prometheus` with correct flags |
| `$out/bin/vllm-monitoring-grafana` | Wrapper that runs `grafana server` with resolved homepath and config |
| `$out/share/vllm-flox-monitoring/` | Static assets: Prometheus template, Grafana config, provisioning, dashboards, plugins |

### Static assets (`share/vllm-flox-monitoring/`)

```
prometheus.yml.template              # Prometheus scrape config template
config.yaml                          # Default vLLM server config (seeded to project)
grafana/
  grafana.ini                        # Grafana server config (anonymous auth, no telemetry)
  provisioning/
    datasources/prometheus.yaml      # Auto-registers Prometheus as Grafana datasource
    dashboards/dashboard.yaml        # Dashboard provisioning config
  dashboards/
    vllm.json                        # 12-panel vLLM monitoring dashboard
  plugins/                           # Pre-compiled Grafana plugins (~50MB)
    grafana-exploretraces-app/       # Traces Drilldown (v1.3.2)
    grafana-lokiexplore-app/         # Logs Drilldown (v1.0.38)
    grafana-metricsdrilldown-app/    # Metrics Drilldown (v1.0.32)
    grafana-pyroscope-app/           # Profiles Drilldown (v1.17.0)
```

### vLLM dashboard panels

Token throughput, success requests/min, E2E request latency (P50/P90/P95/P99), cache utilization, time per output token, request prompt/generation length heatmaps, TTFT latency, cumulative success, scheduler state, and finish reason breakdown.

## Quick start

### 1. Install in a new environment

```toml
# .flox/env/manifest.toml
version = 1

[install]
prometheus.pkg-path = "prometheus"
grafana.pkg-path = "grafana"
vllm-flox-monitoring.pkg-path = "flox/vllm-flox-monitoring"
vllm-flox-runtime.pkg-path = "flox/vllm-flox-runtime"
vllm-python312-cuda12_9-sm120.pkg-path = "flox/vllm-python312-cuda12_9-sm120"
vllm-python312-cuda12_9-sm120.pkg-group = "vllm-python312-cuda12_9-sm120"

[hook]
on-activate = '''
  # Model
  export VLLM_MODEL="${VLLM_MODEL:-Llama-3.1-8B-Instruct}"
  export VLLM_MODEL_ORG="${VLLM_MODEL_ORG:-meta-llama}"
  export VLLM_MODEL_SOURCES="${VLLM_MODEL_SOURCES:-local,hf-cache,hf-hub}"
  export VLLM_MODELS_DIR="${VLLM_MODELS_DIR:-$FLOX_ENV_PROJECT/models}"
  export VLLM_SERVED_MODEL_NAME="${VLLM_SERVED_MODEL_NAME:-$VLLM_MODEL}"

  # Server
  export VLLM_HOST="${VLLM_HOST:-127.0.0.1}"
  export VLLM_PORT="${VLLM_PORT:-8000}"
  export VLLM_API_KEY="${VLLM_API_KEY:-sk-vllm-local-dev}"

  # Engine tuning
  export VLLM_TENSOR_PARALLEL_SIZE="${VLLM_TENSOR_PARALLEL_SIZE:-1}"
  export VLLM_PIPELINE_PARALLEL_SIZE="${VLLM_PIPELINE_PARALLEL_SIZE:-1}"
  export VLLM_PREFIX_CACHING="${VLLM_PREFIX_CACHING:-false}"
  export VLLM_KV_CACHE_DTYPE="${VLLM_KV_CACHE_DTYPE:-auto}"
  export VLLM_MAX_MODEL_LEN="${VLLM_MAX_MODEL_LEN:-4096}"
  export VLLM_MAX_NUM_BATCHED_TOKENS="${VLLM_MAX_NUM_BATCHED_TOKENS:-4096}"

  # Logging / metrics
  export VLLM_LOGGING_LEVEL="${VLLM_LOGGING_LEVEL:-WARNING}"
  export PROMETHEUS_MULTIPROC_DIR="${PROMETHEUS_MULTIPROC_DIR:-/tmp/vllm-prometheus}"

  mkdir -p "$VLLM_MODELS_DIR"
  mkdir -p "$PROMETHEUS_MULTIPROC_DIR"

  # Monitoring setup
  . vllm-monitoring-init
'''

[services]
vllm.command = "vllm-preflight && vllm-resolve-model && vllm-serve"
prometheus.command = "vllm-monitoring-prometheus"
grafana.command = "vllm-monitoring-grafana"
```

Note: `prometheus` and `grafana` binaries are installed separately via `[install]`. The monitoring package provides wrappers and config, not the server binaries — this allows independent version pinning. The vLLM Python/CUDA package (`vllm-python312-cuda12_9-sm120`) must also be installed separately; swap the SM variant to match your GPU (e.g., `sm90` for H100, `sm89` for RTX 4090).

### 2. Activate

```bash
VLLM_MODEL=DeepSeek-R1-Distill-Qwen-7B \
VLLM_MODEL_ORG=deepseek-ai \
  flox activate --start-services
```

### 3. Verify

```bash
# Prometheus targets
curl http://127.0.0.1:9090/api/v1/targets

# Grafana (default: admin/admin)
open http://127.0.0.1:3000
```

## How it works

### Immutable vs mutable split

The package stores config and dashboards in the immutable Nix store. Grafana data and plugins (which Grafana writes to at runtime) live in mutable directories under `$FLOX_ENV_PROJECT`:

| Path | Source | Mutable? |
|------|--------|----------|
| `GF_PATHS_PROVISIONING` | `$FLOX_ENV/share/vllm-flox-monitoring/grafana/provisioning` | No |
| `GRAFANA_DASHBOARDS_DIR` | `$FLOX_ENV/share/vllm-flox-monitoring/grafana/dashboards` | No |
| `GF_PATHS_DATA` | `$FLOX_ENV_PROJECT/grafana/data` | Yes |
| `GF_PATHS_PLUGINS` | `$FLOX_ENV_PROJECT/grafana/plugins` | Yes |
| Prometheus TSDB | `$FLOX_ENV_PROJECT/prometheus/data` | Yes |

### `vllm-monitoring-init`

This script is **sourced** (not executed) so `export` statements propagate into the shell:

1. Locates the package's `share/` directory via `$FLOX_ENV`
2. Creates mutable directories: `grafana/data`, `grafana/plugins`, `prometheus/data`
3. Seeds plugins from the package on first run (copies from Nix store, sets writable permissions)
4. Seeds `config.yaml` to the project root if not present (never overwrites)
5. Exports `GF_PATHS_*`, `GRAFANA_DASHBOARDS_DIR`, `GF_SERVER_*`, `GF_SECURITY_*`, `PROMETHEUS_*`
6. Generates `prometheus.yml` from the template via `sed`

### Plugin seeding

Grafana plugins are copied from the immutable Nix store into `$FLOX_ENV_PROJECT/grafana/plugins/` on first activation. Grafana requires write access to plugin directories at runtime, so they can't be served directly from the store.

To re-seed plugins (e.g., after a package update):

```bash
rm -rf grafana/plugins/*
flox activate   # triggers re-seed
```

## Environment variables

All variables have defaults and can be overridden at activation time:

```bash
VLLM_PORT=9000 PROMETHEUS_PORT=9191 GF_SERVER_HTTP_PORT=3001 flox activate --start-services
```

| Variable | Default | Description |
|----------|---------|-------------|
| `VLLM_SCRAPE_HOST` | `127.0.0.1` | Where Prometheus connects to scrape vLLM |
| `VLLM_PORT` | `8000` | vLLM metrics port (used in Prometheus scrape target) |
| `PROMETHEUS_HOST` | `0.0.0.0` | Prometheus listen address |
| `PROMETHEUS_PORT` | `9090` | Prometheus listen port |
| `GF_SERVER_HTTP_ADDR` | `0.0.0.0` | Grafana listen address |
| `GF_SERVER_HTTP_PORT` | `3000` | Grafana listen port |
| `GF_SECURITY_ADMIN_PASSWORD` | `admin` | Grafana admin password |

## Building from source

```bash
cd build-vllm-flox-monitoring
flox build
```

The build output lands in `./result-vllm-flox-monitoring/`:

```
result-vllm-flox-monitoring/
  bin/
    vllm-monitoring-init
    vllm-monitoring-prometheus
    vllm-monitoring-grafana
  share/vllm-flox-monitoring/
    prometheus.yml.template
    config.yaml
    grafana/
      grafana.ini
      provisioning/...
      dashboards/vllm.json
      plugins/...
```

### Publishing

```bash
flox publish -o flox vllm-flox-monitoring
```

## Architecture

This package is part of a composable vLLM stack:

```
┌───────────────────────────────────────────────────────┐
│  Consuming Environment                                │
│                                                       │
│  [install]                                            │
│    prometheus                  # binary               │
│    grafana                     # binary               │
│    flox/vllm-flox-monitoring   # config + wrappers    │
│    flox/vllm-flox-runtime      # vLLM scripts         │
│    flox/vllm-python312-cuda*   # vLLM + CUDA          │
│                                                       │
│  [hook]                                               │
│    on-activate = '... && . vllm-monitoring-init'       │
│                                                       │
│  [services]                                           │
│    vllm        → vllm-preflight && ... && vllm-serve  │
│    prometheus  → vllm-monitoring-prometheus            │
│    grafana     → vllm-monitoring-grafana               │
│                                                       │
│  ┌─────────────┐  ┌────────────┐  ┌────────────────┐ │
│  │ vLLM :8000  │◄─┤ Prometheus │  │ Grafana :3000  │ │
│  │ /metrics    │  │ :9090      │─►│ dashboards     │ │
│  └─────────────┘  └────────────┘  └────────────────┘ │
└───────────────────────────────────────────────────────┘
```

The `[include]`-based composition from the original vllm-monitoring repo is replaced by installing both packages in `[install]` — no relative path coupling between repos.

## Repo structure

```
build-vllm-flox-monitoring/
  .flox/
    env/manifest.toml                    # Minimal build manifest
    pkgs/vllm-flox-monitoring.nix        # Nix derivation
  scripts/
    vllm-monitoring-init                 # Setup script (sourced from on-activate)
    vllm-monitoring-prometheus           # Prometheus wrapper
    vllm-monitoring-grafana              # Grafana wrapper
  share/
    prometheus.yml.template
    config.yaml
    grafana/
      grafana.ini
      provisioning/{datasources,dashboards}/
      dashboards/vllm.json
      plugins/ (4 pre-compiled plugin dirs)
  .gitignore
```
