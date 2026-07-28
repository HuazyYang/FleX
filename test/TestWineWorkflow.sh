#!/usr/bin/env bash

set -euo pipefail

repo_root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
test_root=$(mktemp -d)
trap 'rm -rf "$test_root"' EXIT

fail()
{
    printf 'FAIL: %s\n' "$*" >&2
    exit 1
}

assert_contains()
{
    local haystack=$1
    local needle=$2
    [[ "$haystack" == *"$needle"* ]] ||
        fail "expected output to contain: $needle"
}

assert_not_contains()
{
    local haystack=$1
    local needle=$2
    [[ "$haystack" != *"$needle"* ]] ||
        fail "expected output not to contain: $needle"
}

workflow_scripts=(
    "$repo_root/Tools/wine/bootstrap-toolchain.sh"
    "$repo_root/Tools/wine/check-prefix.sh"
    "$repo_root/Tools/wine/run-demo.sh"
    "$repo_root/Tools/wine/debug-server.sh"
    "$repo_root/Tools/wine/clang-cl.sh"
    "$repo_root/Tools/wine/fxc.sh"
    "$repo_root/Tools/wine/lld-link.sh"
    "$repo_root/Tools/wine/llvm-lib.sh"
    "$repo_root/Tools/wine/llvm-mt.sh"
    "$repo_root/Tools/wine/llvm-rc.sh"
    "$repo_root/Tools/wine/wine-shader-tool.sh"
)

for script_path in "${workflow_scripts[@]}"
do
    test -x "$script_path" || fail "missing executable script: $script_path"
    bash -n "$script_path"
done

test -x "$repo_root/test/fakes/fake-wine.sh" ||
    fail 'fake Wine test helper is not executable'
bash -n "$repo_root/test/fakes/fake-wine.sh"

python3 -m json.tool "$repo_root/CMakePresets.json" >/dev/null
python3 -m json.tool "$repo_root/.vscode/tasks.json" >/dev/null
python3 -m json.tool "$repo_root/.vscode/launch.json" >/dev/null
python3 -m json.tool "$repo_root/.vscode/settings.json" >/dev/null

configure_presets=$(cd "$repo_root" && cmake --list-presets)
assert_contains "$configure_presets" '"wine-clang"'

build_presets=$(cd "$repo_root" && cmake --build --list-presets)
assert_contains "$build_presets" '"wine-clang-debug"'
assert_contains "$build_presets" '"wine-clang-release"'

workflow_presets=$(cd "$repo_root" && cmake --workflow --list-presets)
assert_contains "$workflow_presets" '"wine-clang-debug"'
assert_contains "$workflow_presets" '"wine-clang-release"'

toolchain_file="$repo_root/cmake/toolchains/windows-clang-cl.cmake"
test -f "$toolchain_file" || fail "missing toolchain file: $toolchain_file"
if NVFLEX_TOOLCHAIN_ROOT="$test_root/missing-toolchain" \
    NVFLEX_WINEPREFIX="$test_root/missing-prefix" \
    cmake -P "$toolchain_file" >"$test_root/toolchain-error.out" 2>&1
then
    fail 'missing cross-toolchain unexpectedly passed validation'
fi
toolchain_error=$(<"$test_root/toolchain-error.out")
assert_contains "$toolchain_error" 'bootstrap-toolchain.sh'

fake_prefix="$test_root/prefix"
fake_system32="$fake_prefix/drive_c/windows/system32"
fake_build_root="$test_root/build"
fake_bin="$fake_build_root/bin/Debug"
fake_run_root="$test_root/run"
fake_wine_log="$test_root/fake-wine.log"
mkdir -p "$fake_system32" "$fake_bin"

printf 'WINE REGISTRY Version 2\n#arch=win64\n' >"$fake_prefix/system.reg"
printf '%s\n' \
    '"d3d11"="native"' \
    '"d3d12"="native"' \
    '"d3d12core"="native"' \
    '"dxgi"="native"' >"$fake_prefix/user.reg"

touch \
    "$fake_system32/d3d11.dll" \
    "$fake_system32/d3d12.dll" \
    "$fake_system32/d3d12core.dll" \
    "$fake_system32/dxgi.dll" \
    "$fake_system32/msvcp140.dll" \
    "$fake_system32/vcruntime140.dll" \
    "$fake_system32/vcruntime140_1.dll"

touch \
    "$fake_bin/NvFlexDemoDebugD3D_win64.exe" \
    "$fake_bin/NvFlexRev.dll" \
    "$fake_bin/NvFlexExtDebugD3D_win64.dll" \
    "$fake_bin/NvFlexDebugD3D_x64.dll" \
    "$fake_bin/SDL2.dll" \
    "$fake_bin/nvToolsExt64_1.dll" \
    "$fake_bin/amd_ags_x64.dll"

prefix_output=$(
    NVFLEX_WINEPREFIX="$fake_prefix" \
        "$repo_root/Tools/wine/check-prefix.sh"
)
assert_contains "$prefix_output" 'Wine prefix is ready'

dx11_output=$(
    NVFLEX_BUILD_ROOT="$fake_build_root" \
    NVFLEX_WINEPREFIX="$fake_prefix" \
    NVFLEX_RUN_ROOT="$fake_run_root" \
        "$repo_root/Tools/wine/run-demo.sh" \
        --dry-run --config Debug --rhi dx11 --dev 1
)
assert_contains "$dx11_output" '--dev=1'
assert_contains "$dx11_output" '--windowed=1280x720'
assert_contains "$dx11_output" '--vsync=0'
assert_not_contains "$dx11_output" '--d3d12'

dx12_output=$(
    NVFLEX_BUILD_ROOT="$fake_build_root" \
    NVFLEX_WINEPREFIX="$fake_prefix" \
    NVFLEX_RUN_ROOT="$fake_run_root" \
        "$repo_root/Tools/wine/run-demo.sh" \
        --dry-run --config Debug --rhi dx12 --dev 1
)
assert_contains "$dx12_output" '--d3d12'
assert_contains "$dx12_output" '--dev=1'

if NVFLEX_BUILD_ROOT="$fake_build_root" \
    NVFLEX_WINEPREFIX="$fake_prefix" \
        "$repo_root/Tools/wine/run-demo.sh" \
        --dry-run --rhi metal >"$test_root/invalid-rhi.out" 2>&1
then
    fail 'invalid RHI unexpectedly passed validation'
fi
invalid_rhi_output=$(<"$test_root/invalid-rhi.out")
assert_contains "$invalid_rhi_output" 'Unsupported RHI'

: >"$fake_wine_log"
FAKE_WINE_MODE=timeout \
FAKE_WINE_LOG="$fake_wine_log" \
NVFLEX_BUILD_ROOT="$fake_build_root" \
NVFLEX_WINEPREFIX="$fake_prefix" \
NVFLEX_RUN_ROOT="$fake_run_root" \
NVFLEX_WINE_BIN="$repo_root/test/fakes/fake-wine.sh" \
    "$repo_root/Tools/wine/run-demo.sh" \
    --config Debug --rhi d3d11 --dev 1 --smoke-seconds 1
smoke_log=$(<"$fake_wine_log")
assert_contains "$smoke_log" 'NvFlexDemoDebugD3D_win64.exe'

if FAKE_WINE_MODE=fail \
    FAKE_WINE_EXIT_CODE=7 \
    NVFLEX_BUILD_ROOT="$fake_build_root" \
    NVFLEX_WINEPREFIX="$fake_prefix" \
    NVFLEX_RUN_ROOT="$fake_run_root" \
    NVFLEX_WINE_BIN="$repo_root/test/fakes/fake-wine.sh" \
        "$repo_root/Tools/wine/run-demo.sh" \
        --config Debug --rhi d3d12 --dev 1 --smoke-seconds 2 \
        >"$test_root/early-failure.out" 2>&1
then
    fail 'early Wine failure unexpectedly passed the smoke test'
fi
early_failure_output=$(<"$test_root/early-failure.out")
assert_contains "$early_failure_output" 'exited before the smoke interval'
assert_contains "$early_failure_output" 'status 7'

python3 - "$repo_root/.vscode/launch.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    launch = json.load(stream)

wine_configs = [
    entry for entry in launch["configurations"]
    if entry["name"].startswith("Wine Debug:")
]
assert len(wine_configs) == 2
assert {entry["type"] for entry in wine_configs} == {"cppdbg"}
assert {entry["launchCompleteCommand"] for entry in wine_configs} == {"None"}
assert all(entry["symbolLoadInfo"]["loadAll"] is False for entry in wine_configs)
PY

printf 'FleX Wine workflow contract tests passed.\n'
