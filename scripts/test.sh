#!/bin/bash
set -euo pipefail

project_dir="$(cd "$(dirname "$0")/.." && pwd)"
# Match the packaging toolchain without changing the machine's xcode-select.
if [[ -z "${DEVELOPER_DIR:-}" && -d /Applications/Xcode.app/Contents/Developer ]]; then
    export DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer
fi
test_dir="$(mktemp -d "${TMPDIR:-/tmp}/photonic-tests.XXXXXX")"
cleanup() {
    # Only remove the exact directory created by this invocation.
    if [[ -d "$test_dir" && "${test_dir##*/}" == photonic-tests.* ]]; then
        rm -rf -- "$test_dir"
    fi
}
trap cleanup EXIT
mkdir -p "$test_dir/cache" "$test_dir/config" "$test_dir/security" "$test_dir/clang"

# A separate SwiftPM scratch/cache/config avoids touching the developer's .build
# or global SwiftPM state. Tests inject desktop effects and do not run main.swift.
CLANG_MODULE_CACHE_PATH="$test_dir/clang" \
SWIFTPM_MODULECACHE_OVERRIDE="$test_dir/clang" \
    swift test --package-path "$project_dir" \
    --scratch-path "$test_dir/build" \
    --cache-path "$test_dir/cache" \
    --config-path "$test_dir/config" \
    --security-path "$test_dir/security" \
    --disable-dependency-cache --manifest-cache local "$@"
