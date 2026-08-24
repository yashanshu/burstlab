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

source_fingerprint() {
  sha256sum "${source_files[@]}" | sha256sum | awk '{ print $1 }'
}

cli_profile=${3:-}
cli_rate=${4:-}
cli_discovery_duration=${5:-}
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi
current_token_input_sha256=$(value_sha256 "${TOKEN:-}")
current_api_token_digest=${TOKEN_SHA256:-}
current_database_url_sha256=$(value_sha256 "${DATABASE_URL:-}")
current_postgres_password_sha256=$(value_sha256 "${POSTGRES_PASSWORD:-}")

run_id=${1:-manual}
phase=${2:-snapshot}
PROFILE=${cli_profile:-${PROFILE:-unset}}
TARGET_RPS=${cli_rate:-${TARGET_RPS:-unset}}
DISCOVERY_DURATION=${cli_discovery_duration:-${DISCOVERY_DURATION:-30s}}
if [[ ! $run_id =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || [[ ! $phase =~ ^[A-Za-z0-9_-]+$ ]]; then
  printf 'run ID and phase may contain only letters, digits, underscores, and hyphens\n' >&2
  exit 2
fi

mkdir -p results
benchmark_manifest="results/${run_id}-benchmark.env"
manifest_present=0
if [[ -f $benchmark_manifest ]]; then
  manifest_present=1
  while IFS='=' read -r key value; do
    case "$key" in
      DOCKER_HOST | DOCKER_CONTEXT | COMPOSE_FILE | COMPOSE_PROJECT_NAME | COMPOSE_PROFILES)
        if [[ -n $value ]]; then
          printf -v "$key" '%s' "$value"
          export "$key"
        else
          unset "$key"
        fi
        ;;
      PROFILE | TARGET_RPS | URL | HTTP_ADDR | NATS_URL | NATS_SYNC_INTERVAL | POSTGRES_DB | POSTGRES_USER | \
        NATS_IMAGE | POSTGRES_IMAGE | DOCKER_CONTEXT_RESOLVED | BENCHMARK_K6_CONFIG | \
        LAB_SOURCE_FINGERPRINT | COMPOSE_CONFIG_FINGERPRINT | TOKEN_INPUT_SHA256 | \
        API_TOKEN_DIGEST | DATABASE_URL_SHA256 | POSTGRES_PASSWORD_SHA256 | HEALTH_DURATION | \
        DISCOVERY_DURATION | CONFIRMATION_LOW_RPS | LOW_DURATION | RAMP_DURATION | HOLD_DURATION | \
        PRE_ALLOCATED_VUS | MAX_VUS | MAX_FAILURE_RATE | MAX_P95_MS | ALLOW_STOPPED_WORKER)
        printf -v "$key" '%s' "$value"
        export "$key"
        ;;
      '') ;;
      *) printf 'unknown key %s in %s\n' "$key" "$benchmark_manifest" >&2; exit 2 ;;
    esac
  done <"$benchmark_manifest"
fi
if (( manifest_present == 1 )) && [[ -z ${DOCKER_HOST:-} && -z ${DOCKER_CONTEXT:-} ]]; then
  DOCKER_CONTEXT=${DOCKER_CONTEXT_RESOLVED:-}
  export DOCKER_CONTEXT
fi
output="results/${run_id}-${phase}.evidence.txt"
if [[ -e $output ]]; then
  printf 'refusing to overwrite existing evidence %s\n' "$output" >&2
  exit 2
fi

configuration_integrity=unfrozen
integrity_notes=()
current_source_fingerprint=unavailable
current_compose_config_fingerprint=unavailable
current_docker_context=unavailable
if current_source_fingerprint=$(source_fingerprint); then :; fi
if current_compose_config_fingerprint=$(docker compose config | sha256sum | awk '{ print $1 }'); then :; fi
if current_docker_context=$(docker context show 2>/dev/null); then :; fi
if (( manifest_present == 1 )); then
  configuration_integrity=match
  if [[ $current_source_fingerprint != "${LAB_SOURCE_FINGERPRINT:-missing}" ]]; then
    configuration_integrity=mismatch
    integrity_notes+=(lab_source_fingerprint)
  fi
  if [[ $current_compose_config_fingerprint != "${COMPOSE_CONFIG_FINGERPRINT:-missing}" ]]; then
    configuration_integrity=mismatch
    integrity_notes+=(compose_config_fingerprint)
  fi
  if [[ $current_docker_context != "${DOCKER_CONTEXT_RESOLVED:-missing}" ]]; then
    configuration_integrity=mismatch
    integrity_notes+=(docker_context)
  fi
  if [[ $current_token_input_sha256 != "${TOKEN_INPUT_SHA256:-missing}" ]]; then
    configuration_integrity=mismatch
    integrity_notes+=(load_token)
  fi
  if [[ $current_api_token_digest != "${API_TOKEN_DIGEST:-missing}" ]]; then
    configuration_integrity=mismatch
    integrity_notes+=(api_token_digest)
  fi
  if [[ $current_database_url_sha256 != "${DATABASE_URL_SHA256:-missing}" ]]; then
    configuration_integrity=mismatch
    integrity_notes+=(database_url)
  fi
  if [[ $current_postgres_password_sha256 != "${POSTGRES_PASSWORD_SHA256:-missing}" ]]; then
    configuration_integrity=mismatch
    integrity_notes+=(postgres_password)
  fi
fi
api_url=${URL:-http://127.0.0.1:8080}
mapfile -t dependency_containers < <(docker compose ps -q nats postgres 2>/dev/null)

capture() {
  local title=$1
  shift
  printf '\n## %s\n' "$title"
  "$@" 2>&1 || printf '[unavailable: command exited %s]\n' "$?"
}

tmp_output=$(mktemp "results/.${run_id}-${phase}.XXXXXX")
trap 'rm -f -- "$tmp_output"' EXIT
if ! {
  printf 'run_id=%s\nphase=%s\ncaptured_utc=%s\n' "$run_id" "$phase" "$(date -u +%FT%TZ)"
  printf 'profile=%s\ntarget_rps=%s\n' "$PROFILE" "$TARGET_RPS"
  printf 'nats_sync_interval=%s\n' "${NATS_SYNC_INTERVAL:-always}"
  printf 'allow_stopped_worker=%s\n' "${ALLOW_STOPPED_WORKER:-0}"
  printf 'health_duration=%s\ndiscovery_duration=%s\nconfirmation_low_rps=%s\nlow_duration=%s\nramp_duration=%s\nhold_duration=%s\n' \
    "${HEALTH_DURATION:-30s}" "$DISCOVERY_DURATION" "${CONFIRMATION_LOW_RPS:-unrecorded}" "${LOW_DURATION:-2m}" \
    "${RAMP_DURATION:-3m}" "${HOLD_DURATION:-10m}"
  printf 'pre_allocated_vus=%s\nmax_vus=%s\nmax_failure_rate=%s\nmax_p95_ms=%s\n' \
    "${PRE_ALLOCATED_VUS:-100}" "${MAX_VUS:-1000}" "${MAX_FAILURE_RATE:-0.005}" "${MAX_P95_MS:-150}"
  printf 'configuration_integrity=%s\n' "$configuration_integrity"
  printf 'lab_source_fingerprint=%s\ncompose_config_fingerprint=%s\ndocker_context=%s\n' \
    "$current_source_fingerprint" "$current_compose_config_fingerprint" "$current_docker_context"
  for note in "${integrity_notes[@]}"; do
    printf 'configuration_mismatch=%s\n' "$note"
  done
  if [[ -f $benchmark_manifest ]]; then
    printf 'benchmark_manifest=%s\n' "$benchmark_manifest"
    capture "Benchmark manifest fingerprint" sha256sum "$benchmark_manifest"
  else
    printf 'benchmark_manifest=absent\n'
  fi
  capture "Lab source fingerprints" sha256sum "${source_files[@]}"
  capture "Native tool versions" bash -c 'go version; k6 version; nats --version'
  capture "Host pressure" uptime
  capture "Memory" free -b
  capture "Lab filesystem" df -hT "$lab_dir"
  capture "Native burstlab processes" ps -C burstlab -o pid,ppid,etimes,%cpu,%mem,rss,args
  if [[ -x ./burstlab ]]; then
    capture "Native binary fingerprint" sha256sum ./burstlab
    capture "Native binary build metadata" go version -m ./burstlab
  else
    printf '\n## Native binary fingerprint\n[unavailable: ./burstlab is absent or not executable]\n'
  fi
  capture "Compose services" docker compose ps
  if (( ${#dependency_containers[@]} > 0 )); then
    capture "Container resource snapshot" docker stats --no-stream "${dependency_containers[@]}"
  else
    printf '\n## Container resource snapshot\n[unavailable: no dependency containers]\n'
  fi
  capture "Resolved image identities" docker image inspect \
    --format '{{.Id}} {{json .RepoTags}} {{json .RepoDigests}}' \
    "${NATS_IMAGE:-nats:2.14.5-alpine3.22}" \
    "${POSTGRES_IMAGE:-postgres:18.6-bookworm}"
  capture "API counters" curl -fsS --max-time 2 "${api_url%/}/stats"
  capture "NATS server state" curl -fsS --max-time 2 http://127.0.0.1:8222/varz
  capture "JetStream stream state" nats --server "${NATS_URL:-nats://127.0.0.1:4222}" \
    stream info EVENTS --json
  capture "JetStream consumer state" nats --server "${NATS_URL:-nats://127.0.0.1:4222}" \
    consumer info EVENTS burstlab-worker --json
  capture "PostgreSQL counts" docker compose exec -T postgres psql \
    -U "${POSTGRES_USER:-burstlab}" -d "${POSTGRES_DB:-burstlab}" -At \
    -c "SELECT count(*) AS run_events FROM events WHERE starts_with(request_id, '${run_id}-'); SELECT count(*) AS total_events FROM events; SELECT count(*) AS quarantine FROM quarantine;"
  capture "PostgreSQL database counters" docker compose exec -T postgres psql \
    -U "${POSTGRES_USER:-burstlab}" -d "${POSTGRES_DB:-burstlab}" -At \
    -c "SELECT datname,numbackends,xact_commit,xact_rollback,blks_read,blks_hit,temp_files,temp_bytes,deadlocks FROM pg_stat_database WHERE datname=current_database();"
  capture "PostgreSQL identity and durability settings" docker compose exec -T postgres psql \
    -U "${POSTGRES_USER:-burstlab}" -d "${POSTGRES_DB:-burstlab}" -At \
    -c "SELECT version(); SHOW fsync; SHOW synchronous_commit; SHOW full_page_writes;"
} >"$tmp_output" 2>&1; then
  printf 'could not write complete evidence for %s/%s\n' "$run_id" "$phase" >&2
  exit 1
fi
if ! ln -- "$tmp_output" "$output"; then
  printf 'could not finalize evidence %s\n' "$output" >&2
  exit 1
fi
rm -f -- "$tmp_output"
trap - EXIT

printf '%s\n' "$output"
if [[ $configuration_integrity == mismatch ]]; then
  printf 'evidence captured, but frozen configuration integrity failed\n' >&2
  exit 1
fi
