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

if [[ ${1:-} != --yes ]]; then
  printf '%s\n' 'This deletes every synthetic event in the local EVENTS stream and course database.' >&2
  printf '%s\n' 'Stop the native API and worker, then rerun with --yes.' >&2
  exit 2
fi
case "${NATS_URL:-nats://127.0.0.1:4222}" in
  nats://127.0.0.1:* | nats://localhost:*) ;;
  *) printf 'refusing to purge a non-loopback NATS server\n' >&2; exit 2 ;;
esac
if ! command -v nats >/dev/null 2>&1; then
  printf 'the native nats CLI is required for a safe stream purge\n' >&2
  exit 1
fi

# Prove both local stores are reachable before mutating either one.
docker compose exec -T postgres psql \
  -U "${POSTGRES_USER:-burstlab}" -d "${POSTGRES_DB:-burstlab}" -Atqc 'SELECT 1' >/dev/null
nats --server "${NATS_URL:-nats://127.0.0.1:4222}" stream ls >/dev/null
stream_exists=0
if nats --server "${NATS_URL:-nats://127.0.0.1:4222}" stream info EVENTS >/dev/null 2>&1; then
  stream_exists=1
fi

if (( stream_exists == 1 )); then
  nats --server "${NATS_URL:-nats://127.0.0.1:4222}" stream purge EVENTS --force
fi
docker compose exec -T postgres psql \
  -U "${POSTGRES_USER:-burstlab}" -d "${POSTGRES_DB:-burstlab}" -v ON_ERROR_STOP=1 \
  -c 'TRUNCATE TABLE events, quarantine;'
printf 'Local synthetic queue and database rows were cleared; named volumes remain.\n'
