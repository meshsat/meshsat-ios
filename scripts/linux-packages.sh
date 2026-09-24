#!/usr/bin/env bash
# Build and test the Linux-capable Swift package (Packages/MeshSatKit).
#
# On a machine with a Swift toolchain:   scripts/linux-packages.sh
# Through Docker (no toolchain needed):  scripts/linux-packages.sh --docker
# One module only:                        scripts/linux-packages.sh --target MeshSatHemb
#
# CI runs the same thing in the swift:6.2-noble image (.gitlab-ci.yml, test:linux).
set -euo pipefail
cd "$(dirname "$0")/.."

IMAGE="${SWIFT_IMAGE:-swift:6.2-noble}"
MODE=native
TARGET=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        --docker) MODE=docker ;;
        --target) TARGET="$2"; shift ;;
        *) echo "usage: $0 [--docker] [--target <module>]" >&2; exit 2 ;;
    esac
    shift
done

run() {
    if [[ -n "$TARGET" ]]; then
        swift build --target "$TARGET" && swift test --filter "${TARGET}Tests" || swift test --skip-build
    else
        swift build && swift test --parallel
    fi
}

if [[ "$MODE" == docker ]]; then
    exec docker run --rm -v "$PWD:/repo" -w /repo/Packages/MeshSatKit \
        -e TARGET="$TARGET" "$IMAGE" bash -c "$(declare -f run); run"
else
    cd Packages/MeshSatKit
    run
fi
