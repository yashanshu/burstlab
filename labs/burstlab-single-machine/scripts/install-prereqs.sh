#!/usr/bin/env bash
# Install the exact prerequisite versions Guided action 1.2 verifies. Every
# download is pinned and checksummed: a benchmark is only comparable against
# the reference result if the toolchain matches, and an unpinned installer
# silently changes the thing being measured.
#
# Safe to rerun — anything already at the pinned version is left alone.
set -euo pipefail

lab_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
cd "$lab_dir"

go_version=1.27.0
go_sha=675c26c449cbb18fc24b74650de1eabbae6e16f64326fd85a283fb3b58280685
k6_version=2.2.0
k6_sha=b5a8003c86f35f5cd5ceef1490312c48e587696c94d998cefc6d7b3b4cb1597d
nats_version=0.4.0
nats_sha=8dbd437c826b953dbd7432cf890ef22ba3c33dccc3dce5e71b3e8d055427849c

[ "$(uname -s)" = Linux ] && [ "$(uname -m)" = x86_64 ] || {
  echo "install-prereqs: the pinned builds are linux/amd64 only" >&2; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

# Download and verify before anything is unpacked or run. TLS proves the host;
# the pinned digest proves the artifact, which is the part TLS cannot.
get() {
  local url=$1 sha=$2 out=$tmp/${1##*/}
  echo "install-prereqs: fetching ${1##*/}" >&2
  curl -fSL --proto '=https' --tlsv1.2 -o "$out" "$url"
  printf '%s  %s\n' "$sha" "$out" | sha256sum -c - >/dev/null \
    || { echo "install-prereqs: checksum mismatch on $url" >&2; exit 1; }
  printf '%s\n' "$out"
}

# installed <needle> <command...> — true when the command reports that version.
installed() {
  local needle=$1; shift
  command -v "$1" >/dev/null 2>&1 && "$@" 2>&1 | grep -qF "$needle"
}

if installed "go$go_version" go version; then
  echo "install-prereqs: go $go_version already installed"
else
  tarball=$(get "https://go.dev/dl/go$go_version.linux-amd64.tar.gz" "$go_sha")
  sudo rm -rf /usr/local/go
  sudo tar -C /usr/local -xzf "$tarball"
  # Go's own instruction. profile.d rather than a symlink so GOROOT resolution
  # and `go install` targets behave the way the upstream docs describe.
  echo 'export PATH=$PATH:/usr/local/go/bin' | sudo tee /etc/profile.d/go.sh >/dev/null
  export PATH=$PATH:/usr/local/go/bin
fi

if installed "$k6_version" k6 version; then
  echo "install-prereqs: k6 $k6_version already installed"
else
  tarball=$(get "https://github.com/grafana/k6/releases/download/v$k6_version/k6-v$k6_version-linux-amd64.tar.gz" "$k6_sha")
  tar -C "$tmp" -xzf "$tarball"
  sudo install -m 0755 "$tmp/k6-v$k6_version-linux-amd64/k6" /usr/local/bin/k6
fi

if installed "$nats_version" nats --version; then
  echo "install-prereqs: nats $nats_version already installed"
else
  archive=$(get "https://github.com/nats-io/natscli/releases/download/v$nats_version/nats-$nats_version-linux-amd64.zip" "$nats_sha")
  # ponytail: python3 is on every Ubuntu image; unzip is not always.
  python3 -m zipfile -e "$archive" "$tmp/nats"
  sudo install -m 0755 "$tmp/nats/nats-$nats_version-linux-amd64/nats" /usr/local/bin/nats
fi

if docker version >/dev/null 2>&1; then
  echo "install-prereqs: docker already installed and reachable"
else
  # Docker's own convenience installer. It has no stable digest to pin, so it
  # is saved and run rather than piped, leaving a copy you can read first.
  echo "install-prereqs: installing Docker Engine via https://get.docker.com" >&2
  curl -fSL --proto '=https' --tlsv1.2 -o "$tmp/get-docker.sh" https://get.docker.com
  sudo sh "$tmp/get-docker.sh"
  sudo usermod -aG docker "$USER"
  echo "install-prereqs: log out and back in for docker group membership" >&2
fi

echo
echo "## Guided action 1.2 verification"
go version
k6 version
nats --version
docker version --format '{{.Server.Version}}' 2>/dev/null || echo "docker: not reachable yet — log out and back in"
docker compose version 2>/dev/null || true
