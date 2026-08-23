#!/usr/bin/env bash
set -uo pipefail

lab_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$lab_dir"
mkdir -p results
report="results/preflight-$(date -u +%Y%m%dT%H%M%SZ)-$$.txt"
exec > >(tee "$report") 2>&1

missing=0
target_mismatch=0

section() {
  printf '\n## %s\n' "$1"
}

require() {
  if ! command -v "$1" >/dev/null 2>&1; then
    printf 'MISSING: %s\n' "$1"
    missing=1
  fi
}

section "Benchmark identity"
printf 'captured_utc=%s\n' "$(date -u +%FT%TZ)"
printf 'lab_dir=%s\n' "$lab_dir"

section "Required commands"
for command_name in docker go k6 nats curl lscpu lsblk ss vmstat sha256sum; do
  require "$command_name"
done

section "Benchmark environment"
mapfile -t ambient_k6_names < <(env | awk -F= '$1 ~ /^K6_/ { print $1 }' | LC_ALL=C sort -u)
if (( ${#ambient_k6_names[@]} > 0 )); then
  printf 'FAIL: unset ambient k6 overrides:'
  printf ' %s' "${ambient_k6_names[@]}"
  printf '\n'
  missing=1
else
  printf 'ambient_k6_overrides=none\n'
fi
sha256sum k6-config.json || missing=1

section "Host"
uname -a
sed -n 's/^\(ID\|VERSION_ID\|PRETTY_NAME\)=/\1=/p' /etc/os-release
lscpu
free -b
lsblk -o NAME,TYPE,SIZE,ROTA,MODEL,MOUNTPOINTS
df -T "$lab_dir"
printf 'open_file_limit=%s\n' "$(ulimit -n)"
printf 'logical_cpus=%s (target: 10)\n' "$(nproc --all)"
awk '/MemTotal/ { printf "memory_kib=%s (target: approximately 32 GiB installed)\n", $2 }' /proc/meminfo
logical_cpus=$(nproc --all)
memory_kib=$(awk '/MemTotal/ { print $2 }' /proc/meminfo)
os_id=$(sed -n 's/^ID=//p' /etc/os-release | tr -d '"')
os_version=$(sed -n 's/^VERSION_ID=//p' /etc/os-release | tr -d '"')
[[ $logical_cpus == 10 ]] || { printf 'TARGET MISMATCH: expected exactly 10 logical CPUs.\n'; target_mismatch=1; }
(( memory_kib >= 30 * 1024 * 1024 )) || { printf 'TARGET MISMATCH: expected at least 30 GiB visible RAM.\n'; target_mismatch=1; }
[[ $(uname -m) == x86_64 ]] || { printf 'TARGET MISMATCH: expected x86_64.\n'; target_mismatch=1; }
[[ $os_id == ubuntu && $os_version == 24.04 ]] || { printf 'TARGET MISMATCH: expected Ubuntu 24.04.\n'; target_mismatch=1; }
if (( target_mismatch != 0 )) && [[ ${ALLOW_NON_TARGET:-0} != 1 ]]; then
  printf 'Set ALLOW_NON_TARGET=1 only for a labeled functional check; do not publish its RPS as the target result.\n'
  missing=1
fi

section "Tool versions"
command -v go >/dev/null 2>&1 && go version
command -v k6 >/dev/null 2>&1 && k6 version
command -v nats >/dev/null 2>&1 && nats --version
if command -v docker >/dev/null 2>&1; then
  printf 'docker_context=%s\n' "$(docker context show 2>/dev/null || printf unavailable)"
  docker version
  docker compose version || missing=1
  docker compose config --quiet || missing=1
  docker info --format 'docker_os={{.OperatingSystem}} docker_cpus={{.NCPU}} docker_memory_bytes={{.MemTotal}}' || missing=1
  docker_root=$(docker info --format '{{.DockerRootDir}}' 2>/dev/null || true)
  printf 'docker_root=%s\n' "$docker_root"
  if [[ -n $docker_root ]]; then
    df -T "$docker_root" || printf 'WARNING: could not inspect the Docker root filesystem; record it manually.\n'
  fi
fi

section "Listening TCP sockets"
ss -ltnp

section "Result"
if (( missing != 0 )); then
  printf 'FAIL: install or start the missing requirements before benchmarking.\n'
else
  printf 'PASS: required commands and Docker daemon are available. Review the recorded hardware against the target before continuing.\n'
fi
printf 'report=%s\n' "$report"
exit "$missing"
