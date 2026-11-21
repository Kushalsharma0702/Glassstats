#!/bin/bash
set -euo pipefail
cd "$(dirname "$0")/.."

flags=(--disable-xctest)
if [[ "${GLASSSTATS_BUILD_WORKSPACE_CACHE:-0}" == 1 ]]; then
    export CLANG_MODULE_CACHE_PATH="$PWD/.build/ModuleCache"
    export SWIFTPM_MODULECACHE_OVERRIDE="$CLANG_MODULE_CACHE_PATH"
    mkdir -p "$CLANG_MODULE_CACHE_PATH"
    flags+=(--disable-sandbox --manifest-cache local)
fi
developer_dir="$(xcode-select -p)"
if [[ "$developer_dir" == */CommandLineTools ]]; then
    frameworks="$developer_dir/Library/Developer/Frameworks"
    interop="$developer_dir/Library/Developer/usr/lib"
    flags+=(-Xswiftc "-F$frameworks" -Xlinker -rpath -Xlinker "$frameworks")
    if [[ -d "$interop" ]]; then flags+=(-Xlinker -rpath -Xlinker "$interop"); fi
fi
fixture_dir="$(mktemp -d /tmp/glassstats-tests.XXXXXXXX)"
trap 'rm -rf "$fixture_dir"' EXIT
xcrun clang Tests/Fixtures/Listener.c -o "$fixture_dir/listener"
export GLASSSTATS_LISTENER_FIXTURE="$fixture_dir/listener"
swift test "${flags[@]}" "$@"
