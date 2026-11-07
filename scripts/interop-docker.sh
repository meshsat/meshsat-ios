#!/usr/bin/env bash
# Runs the Kit's Python interop tests (Interop*Tests, LxmfOracleTests) against the pinned Python RNS/LXMF
# in a swift:6.2-noble container with python3 (scripts/interop/Dockerfile). The container's ~/.cache is a
# host mount (~/.cache/meshsat-interop: the RNS venv under meshsat/, SwiftPM's and clang's caches) so pip
# runs once. Usage:
#   scripts/interop-docker.sh                 # every interop test
#   scripts/interop-docker.sh InteropNodeTests # one class (passed to --filter)
#   MESHSAT_RNS_VERSION=1.5.7 scripts/interop-docker.sh   # another RNS release (LXMF pin unchanged)
set -euo pipefail
cd "$(dirname "$0")/.."
IMAGE="meshsat-interop:swift-6.2-noble"
FILTER="${1:-Interop|LxmfOracle}"
CACHE="${MESHSAT_INTEROP_CACHE:-$HOME/.cache/meshsat-interop}"
mkdir -p "$CACHE"
if ! docker image inspect "$IMAGE" >/dev/null 2>&1; then
    docker build -t "$IMAGE" scripts/interop
fi
exec docker run --rm --cpus="${MESHSAT_INTEROP_CPUS:-2}" -m 10g --user "$(id -u):$(id -g)" \
    -e HOME=/tmp -e MESHSAT_INTEROP=1 \
    -e MESHSAT_RNS_VERSION="${MESHSAT_RNS_VERSION:-}" -e MESHSAT_LXMF_VERSION="${MESHSAT_LXMF_VERSION:-}" \
    -v "$PWD:/repo" -v "$CACHE:/tmp/.cache" -w /repo/Packages/MeshSatKit "$IMAGE" \
    swift test -j 2 --filter "$FILTER"
