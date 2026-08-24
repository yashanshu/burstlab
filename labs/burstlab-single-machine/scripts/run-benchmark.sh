#!/usr/bin/env bash
set -uo pipefail

lab_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$lab_dir"
source_files=(
  .env.example compose.yaml go.mod go.sum k6-config.json load.js main.go main_test.go
  scripts/capture-evidence.sh scripts/preflight.sh scripts/reset-lab.sh
  scripts/run-benchmark.sh scripts/summarize-queue-trace.sh scripts/wait-for-drain.sh
)

value_sha256() {
  printf '%s' "$1" | sha256sum | awk '{ print $1 }'
}

cli_profile=${1:-}
cli_rate=${2:-}
cli_duration=${3:-}
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

PROFILE=${cli_profile:-${PROFILE:-smoke}}
TARGET_RPS=${cli_rate:-${TARGET_RPS:-100}}
case "$PROFILE" in
  smoke | health | discovery | confirmation) ;;
  *) printf 'usage: bash scripts/run-benchmark.sh {smoke|health|discovery|confirmation} [target-rps] [discovery-duration]\n' >&2; exit 2 ;;
esac
if [[ ! $TARGET_RPS =~ ^[1-9][0-9]*$ ]]; then
  printf 'target-rps must be a positive integer\n' >&2
  exit 2
fi
confirmation_low_rps=$(( TARGET_RPS / 15 ))
(( confirmation_low_rps < 1 )) && confirmation_low_rps=1
if [[ -n $cli_duration ]]; then
  if [[ $PROFILE != discovery || ! $cli_duration =~ ^[1-9][0-9]*(s|m|h)$ ]]; then
    printf 'the optional duration is only for discovery and must look like 30s, 2m, or 1h\n' >&2
    exit 2
  fi
  DISCOVERY_DURATION=$cli_duration
  export DISCOVERY_DURATION
fi
case "${ALLOW_STOPPED_WORKER:-0}" in
  0 | 1) ;;
  *) printf 'ALLOW_STOPPED_WORKER must be 0 or 1\n' >&2; exit 2 ;;
esac
if [[ ${ALLOW_STOPPED_WORKER:-0} == 1 && $PROFILE != discovery ]]; then
  printf 'ALLOW_STOPPED_WORKER=1 is permitted only for the deliberate discovery backlog probe\n' >&2
  exit 2
fi
mapfile -t ambient_k6_names < <(env | awk -F= '$1 ~ /^K6_/ { print $1 }' | LC_ALL=C sort -u)
if (( ${#ambient_k6_names[@]} > 0 )); then
  printf 'Unset ambient k6 overrides before benchmarking:' >&2
  printf ' %s' "${ambient_k6_names[@]}" >&2
  printf '\n' >&2
  exit 2
fi
if ! command -v docker >/dev/null 2>&1 || ! command -v k6 >/dev/null 2>&1 || \
  ! command -v curl >/dev/null 2>&1 || ! command -v vmstat >/dev/null 2>&1 || \
  ! command -v nats >/dev/null 2>&1 || ! command -v sha256sum >/dev/null 2>&1; then
  printf 'Docker, k6, curl, vmstat, sha256sum, and the nats CLI are required; run the preflight first\n' >&2
  exit 1
fi

RUN_ID=${RUN_ID:-$(date -u +%Y%m%dT%H%M%SZ)-$$}
if [[ ! $RUN_ID =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,31}$ ]]; then
  printf 'RUN_ID must contain 1-32 letters, digits, underscores, or hyphens\n' >&2
  exit 2
fi

mkdir -p results
if compgen -G "results/${RUN_ID}-*" >/dev/null; then
  printf 'refusing to reuse RUN_ID %s because matching evidence already exists\n' "$RUN_ID" >&2
  exit 2
fi

export PROFILE TARGET_RPS RUN_ID
BENCHMARK_K6_CONFIG=k6-config.json
if ! lab_source_fingerprint=$(sha256sum "${source_files[@]}" | sha256sum | awk '{ print $1 }'); then
  printf 'could not fingerprint lab sources\n' >&2
  exit 1
fi
if ! compose_config_fingerprint=$(docker compose config | sha256sum | awk '{ print $1 }'); then
  printf 'could not resolve and fingerprint the Compose configuration\n' >&2
  exit 1
fi
if ! docker_context_resolved=$(docker context show); then
  printf 'could not resolve the Docker context\n' >&2
  exit 1
fi
benchmark_manifest="results/${RUN_ID}-benchmark.env"
if ! {
  printf 'PROFILE=%s\n' "$PROFILE"
  printf 'TARGET_RPS=%s\n' "$TARGET_RPS"
  printf 'URL=%s\n' "${URL:-http://127.0.0.1:8080}"
  printf 'HTTP_ADDR=%s\n' "${HTTP_ADDR:-127.0.0.1:8080}"
  printf 'NATS_URL=%s\n' "${NATS_URL:-nats://127.0.0.1:4222}"
  printf 'POSTGRES_DB=%s\n' "${POSTGRES_DB:-burstlab}"
  printf 'POSTGRES_USER=%s\n' "${POSTGRES_USER:-burstlab}"
  printf 'NATS_IMAGE=%s\n' "${NATS_IMAGE:-nats:2.14.5-alpine3.22}"
  printf 'POSTGRES_IMAGE=%s\n' "${POSTGRES_IMAGE:-postgres:18.6-bookworm}"
  printf 'DOCKER_HOST=%s\n' "${DOCKER_HOST:-}"
  printf 'DOCKER_CONTEXT=%s\n' "${DOCKER_CONTEXT:-}"
  printf 'COMPOSE_FILE=%s\n' "${COMPOSE_FILE:-}"
  printf 'COMPOSE_PROJECT_NAME=%s\n' "${COMPOSE_PROJECT_NAME:-}"
  printf 'COMPOSE_PROFILES=%s\n' "${COMPOSE_PROFILES:-}"
  printf 'DOCKER_CONTEXT_RESOLVED=%s\n' "$docker_context_resolved"
  printf 'BENCHMARK_K6_CONFIG=%s\n' "$BENCHMARK_K6_CONFIG"
  printf 'LAB_SOURCE_FINGERPRINT=%s\n' "$lab_source_fingerprint"
  printf 'COMPOSE_CONFIG_FINGERPRINT=%s\n' "$compose_config_fingerprint"
  printf 'TOKEN_INPUT_SHA256=%s\n' "$(value_sha256 "${TOKEN:-}")"
  printf 'API_TOKEN_DIGEST=%s\n' "${TOKEN_SHA256:-}"
  printf 'DATABASE_URL_SHA256=%s\n' "$(value_sha256 "${DATABASE_URL:-}")"
  printf 'POSTGRES_PASSWORD_SHA256=%s\n' "$(value_sha256 "${POSTGRES_PASSWORD:-}")"
  printf 'HEALTH_DURATION=%s\n' "${HEALTH_DURATION:-30s}"
  printf 'DISCOVERY_DURATION=%s\n' "${DISCOVERY_DURATION:-30s}"
  printf 'CONFIRMATION_LOW_RPS=%s\n' "$confirmation_low_rps"
  printf 'LOW_DURATION=%s\n' "${LOW_DURATION:-2m}"
  printf 'RAMP_DURATION=%s\n' "${RAMP_DURATION:-3m}"
  printf 'HOLD_DURATION=%s\n' "${HOLD_DURATION:-10m}"
  printf 'PRE_ALLOCATED_VUS=%s\n' "${PRE_ALLOCATED_VUS:-100}"
  printf 'MAX_VUS=%s\n' "${MAX_VUS:-1000}"
  printf 'MAX_FAILURE_RATE=%s\n' "${MAX_FAILURE_RATE:-0.005}"
  printf 'MAX_P95_MS=%s\n' "${MAX_P95_MS:-150}"
  printf 'ALLOW_STOPPED_WORKER=%s\n' "${ALLOW_STOPPED_WORKER:-0}"
} >"$benchmark_manifest"; then
  printf 'could not write benchmark manifest %s\n' "$benchmark_manifest" >&2
  exit 1
fi
health_path=ready
[[ $PROFILE == health ]] && health_path=live
api_url=${URL:-http://127.0.0.1:8080}
for service in nats postgres; do
  service_container=$(docker compose ps -q "$service")
  if [[ -z $service_container ]]; then
    printf 'Compose service %s is absent; no load was generated\n' "$service" >&2
    exit 1
  fi
  service_health=$(docker inspect --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}{{.State.Status}}{{end}}' "$service_container")
  if [[ $service_health != healthy ]]; then
    printf 'Compose service %s is %s, not healthy; no load was generated\n' "$service" "$service_health" >&2
    exit 1
  fi
done
if ! curl -fsS --max-time 2 "${api_url%/}/health/${health_path}" >/dev/null; then
  printf 'API /health/%s is not ready; no load was generated\n' "$health_path" >&2
  exit 1
fi
if [[ $PROFILE != health ]] && ! nats --server "${NATS_URL:-nats://127.0.0.1:4222}" \
  consumer info EVENTS burstlab-worker >/dev/null 2>&1; then
  printf 'The durable worker consumer is absent; start the worker before event load\n' >&2
  exit 1
fi
if [[ $PROFILE != health && ${ALLOW_STOPPED_WORKER:-0} != 1 ]]; then
  worker_connections=$(curl -fsS --max-time 2 'http://127.0.0.1:8222/connz' | \
    grep -Ec '"name"[[:space:]]*:[[:space:]]*"burstlab-worker"' || true)
  if [[ $worker_connections != 1 ]]; then
    printf 'Expected exactly one connected burstlab-worker client; observed %s\n' "$worker_connections" >&2
    exit 1
  fi
elif [[ $PROFILE != health ]]; then
  printf 'WARNING: ALLOW_STOPPED_WORKER=1; this run may create deliberate backlog and is not a sustainable-rate test\n' >&2
fi

printf 'run_id=%s profile=%s target_rps=%s\n' "$RUN_ID" "$PROFILE" "$TARGET_RPS"
printf 'allow_stopped_worker=%s discovery_duration=%s\n' \
  "${ALLOW_STOPPED_WORKER:-0}" "${DISCOVERY_DURATION:-30s}"
printf 'benchmark_manifest=%s\n' "$benchmark_manifest"
if ! bash scripts/capture-evidence.sh "$RUN_ID" before "$PROFILE" "$TARGET_RPS" "${DISCOVERY_DURATION:-30s}"; then
  printf 'before-load evidence failed; no load was generated\n' >&2
  exit 1
fi

monitor_pids=()
stop_monitors() {
  local pid attempt
  for pid in "${monitor_pids[@]}"; do
    kill "$pid" 2>/dev/null || true
  done
  for pid in "${monitor_pids[@]}"; do
    for attempt in {1..10}; do
      kill -0 "$pid" 2>/dev/null || break
      sleep 0.1
    done
    kill -KILL "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
  done
  monitor_pids=()
}
trap stop_monitors EXIT

vmstat -t 1 >"results/${RUN_ID}-vmstat.txt" &
monitor_pids+=("$!")
mapfile -t dependency_containers < <(docker compose ps -q nats postgres)
if (( ${#dependency_containers[@]} > 0 )); then
  docker stats --format '{{json .}}' "${dependency_containers[@]}" >"results/${RUN_ID}-docker-stats.jsonl" &
  monitor_pids+=("$!")
fi
(
  while true; do
    captured_utc=$(date -u +%FT%TZ)
    if api_stats=$(curl -fsS --max-time 2 "${api_url%/}/stats" 2>/dev/null); then
      printf '{"captured_utc":"%s","stats":%s}\n' "$captured_utc" "$api_stats"
    else
      printf '{"captured_utc":"%s","stats":null}\n' "$captured_utc"
    fi
    sleep 1
  done
) >"results/${RUN_ID}-api-stats.jsonl" &
monitor_pids+=("$!")
if [[ $PROFILE != health ]]; then
  (
    while true; do
      printf '\n### %s\n' "$(date -u +%FT%TZ)"
      nats --server "${NATS_URL:-nats://127.0.0.1:4222}" stream info EVENTS --json
      nats --server "${NATS_URL:-nats://127.0.0.1:4222}" \
        consumer info EVENTS burstlab-worker --json
      worker_connections=$(curl -fsS --max-time 2 'http://127.0.0.1:8222/connz' | \
        grep -Ec '"name"[[:space:]]*:[[:space:]]*"burstlab-worker"' || true)
      printf 'worker_connections=%s\n' "$worker_connections"
      sleep 1
    done
  ) >"results/${RUN_ID}-queue-trace.txt" 2>&1 &
  monitor_pids+=("$!")
fi

if ! date -u +%FT%TZ >"results/${RUN_ID}-load-start.utc"; then
  printf 'could not write the load-start marker; no load was generated\n' >&2
  exit 1
fi
set +e
k6 --config "$BENCHMARK_K6_CONFIG" run load.js 2>&1 | tee "results/${RUN_ID}-${PROFILE}.log"
pipeline_status=("${PIPESTATUS[@]}")
end_marker_status=0
if ! date -u +%FT%TZ >"results/${RUN_ID}-load-end.utc"; then
  printf 'could not write the load-end marker\n' >&2
  end_marker_status=1
fi
set -e
status=${pipeline_status[0]}
(( pipeline_status[1] != 0 )) && status=${pipeline_status[1]}
(( end_marker_status != 0 )) && status=1
stop_monitors
bash scripts/capture-evidence.sh "$RUN_ID" after "$PROFILE" "$TARGET_RPS" "${DISCOVERY_DURATION:-30s}"

printf 'run_id=%s exit_status=%s\n' "$RUN_ID" "$status"
printf 'After the worker drains, capture reconciliation with:\n  bash scripts/capture-evidence.sh %s drained %s %s %s\n' \
  "$RUN_ID" "$PROFILE" "$TARGET_RPS" "${DISCOVERY_DURATION:-30s}"
exit "$status"
