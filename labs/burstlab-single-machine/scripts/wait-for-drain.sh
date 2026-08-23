#!/usr/bin/env bash
set -euo pipefail

lab_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$lab_dir"
if [[ -f .env ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env
  set +a
fi

run_id=${1:-}
timeout_seconds=${2:-1800}
if [[ ! $run_id =~ ^[A-Za-z0-9][A-Za-z0-9_-]{0,47}$ ]] || \
  [[ ! $timeout_seconds =~ ^[1-9][0-9]*$ ]]; then
  printf 'usage: bash scripts/wait-for-drain.sh RUN_ID [TIMEOUT_SECONDS]\n' >&2
  exit 2
fi
benchmark_manifest="results/${run_id}-benchmark.env"
if [[ -f $benchmark_manifest ]]; then
  while IFS='=' read -r key value; do
    if [[ $key == NATS_URL ]]; then
      NATS_URL=$value
      export NATS_URL
    fi
  done <"$benchmark_manifest"
fi
if ! command -v nats >/dev/null 2>&1; then
  printf 'the nats CLI is required\n' >&2
  exit 1
fi

mkdir -p results
poll_file="results/${run_id}-drain-poll.tsv"
end_file="results/${run_id}-drain-end.epoch"
if [[ -e $poll_file || -e $end_file ]]; then
  printf 'refusing to overwrite existing drain evidence for %s\n' "$run_id" >&2
  exit 2
fi
started=$(date +%s)
set -o noclobber
if ! printf 'timestamp\tpending\tack_pending\tbacklog\n' >"$poll_file"; then
  printf 'could not reserve drain evidence for %s\n' "$run_id" >&2
  exit 2
fi
set +o noclobber
printf 'timestamp\tpending\tack_pending\tbacklog\n'
while (( $(date +%s) - started <= timeout_seconds )); do
  timestamp=$(date -u +%FT%TZ)
  if ! state=$(nats --server "${NATS_URL:-nats://127.0.0.1:4222}" \
    consumer info EVENTS burstlab-worker --json 2>/dev/null); then
    printf '%s\tunavailable\tunavailable\tunavailable\n' "$timestamp" | tee -a "$poll_file"
    sleep 1
    continue
  fi
  pending=$(awk '/"num_pending"[[:space:]]*:/ { value=$2; gsub(/[^0-9]/, "", value); print value; exit }' <<<"$state")
  ack_pending=$(awk '/"num_ack_pending"[[:space:]]*:/ { value=$2; gsub(/[^0-9]/, "", value); print value; exit }' <<<"$state")
  if [[ -z $pending || -z $ack_pending ]]; then
    printf '%s\tunparseable\tunparseable\tunparseable\n' "$timestamp" | tee -a "$poll_file"
    sleep 1
    continue
  fi
  backlog=$(( pending + ack_pending ))
  printf '%s\t%s\t%s\t%s\n' "$timestamp" "$pending" "$ack_pending" "$backlog" | tee -a "$poll_file"
  if (( backlog == 0 )); then
    end_epoch=$(date +%s)
    set -o noclobber
    if ! printf '%s\n' "$end_epoch" >"$end_file"; then
      printf 'could not create drain end marker %s\n' "$end_file" >&2
      exit 2
    fi
    set +o noclobber
    printf '%s\n' "$end_epoch"
    printf 'drained_utc=%s\nend_epoch_file=%s\n' "$timestamp" "$end_file"
    exit 0
  fi
  sleep 1
done

printf 'backlog did not reach zero within %s seconds\n' "$timeout_seconds" >&2
exit 1
