#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

show_help()
{
    cat <<'EOF'
Usage: run-demo.sh [options] [-- extra-demo-arguments]

Options:
  --config Debug|Release       Build configuration (default: Debug)
  --rhi d3d11|dx11|d3d12|dx12 Rendering backend (default: d3d11)
  --dev 0|1                    Vendor or reconstructed FleX (default: 1)
  --smoke-seconds N            Pass if the demo remains alive for N seconds
  --dry-run                    Validate and print without launching
EOF
}

configuration=Debug
rhi=d3d11
dev_mode=1
smoke_seconds=
dry_run=false
extra_arguments=()

while [[ $# -gt 0 ]]
do
    case "$1" in
        --config) configuration=${2:?--config requires a value}; shift 2 ;;
        --config=*) configuration=${1#*=}; shift ;;
        --rhi) rhi=${2:?--rhi requires a value}; shift 2 ;;
        --rhi=*) rhi=${1#*=}; shift ;;
        --dev) dev_mode=${2:?--dev requires a value}; shift 2 ;;
        --dev=*) dev_mode=${1#*=}; shift ;;
        --smoke-seconds) smoke_seconds=${2:?--smoke-seconds requires a value}; shift 2 ;;
        --smoke-seconds=*) smoke_seconds=${1#*=}; shift ;;
        --dry-run) dry_run=true; shift ;;
        --) shift; extra_arguments=("$@"); break ;;
        -h|--help) show_help; exit 0 ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; show_help >&2; exit 2 ;;
    esac
done

case "$configuration" in Debug|Release) ;; *)
    printf 'Unsupported configuration: %s\n' "$configuration" >&2
    exit 2
esac
case "$rhi" in
    d3d11|dx11) rhi=d3d11 ;;
    d3d12|dx12) rhi=d3d12 ;;
    *) printf 'Unsupported RHI: %s\n' "$rhi" >&2; exit 2 ;;
esac
case "$dev_mode" in 0|1) ;; *)
    printf 'Unsupported --dev value: %s\n' "$dev_mode" >&2
    exit 2
esac
if [[ -n "$smoke_seconds" && ! "$smoke_seconds" =~ ^[1-9][0-9]*$ ]]
then
    printf -- '--smoke-seconds must be a positive integer.\n' >&2
    exit 2
fi

repo_root=$(nvflex_repo_root)
build_root=${NVFLEX_BUILD_ROOT:-"$repo_root/build/wine-clang"}
run_root=${NVFLEX_RUN_ROOT:-"$repo_root/.run"}
wineprefix=$(nvflex_wineprefix)
wine_bin=${NVFLEX_WINE_BIN:-wine}
executable="$build_root/bin/$configuration/NvFlexDemo${configuration}D3D_win64.exe"
binary_dir=$(dirname "$executable")
runtime_working_dir="$repo_root/bin/win64"

NVFLEX_WINEPREFIX="$wineprefix" "$script_dir/check-prefix.sh" >/dev/null
nvflex_require_file "$executable" 'FleX demo executable'

runtime_files=(
    "NvFlexRev.dll"
    "NvFlexExt${configuration}D3D_win64.dll"
    "NvFlex${configuration}D3D_x64.dll"
    "SDL2.dll"
    "nvToolsExt64_1.dll"
    "amd_ags_x64.dll"
)
for runtime_file in "${runtime_files[@]}"
do
    nvflex_require_file "$binary_dir/$runtime_file" 'packaged runtime'
done

mkdir -p "$run_root/logs/$rhi" "$run_root/cache/dxvk" "$run_root/cache/vkd3d"

environment_arguments=(
    "WINEPREFIX=$wineprefix"
    "WINEARCH=win64"
    "WINEDEBUG=${NVFLEX_WINEDEBUG:--all}"
    "DXVK_LOG_LEVEL=${DXVK_LOG_LEVEL:-info}"
    "DXVK_LOG_PATH=$run_root/logs/$rhi"
)
demo_arguments=(
    "--dev=$dev_mode"
    "--windowed=1280x720"
    "--vsync=0"
)
if [[ "$rhi" == d3d11 ]]
then
    environment_arguments+=("DXVK_STATE_CACHE_PATH=$run_root/cache/dxvk")
else
    demo_arguments+=("--d3d12")
    environment_arguments+=(
        "VKD3D_DEBUG=${VKD3D_DEBUG:-info}"
        "VKD3D_LOG_FILE=$run_root/logs/d3d12/vkd3d-proton.log"
        "VKD3D_SHADER_CACHE_PATH=$run_root/cache/vkd3d"
    )
fi

command_arguments=("$wine_bin" "$executable" "${demo_arguments[@]}" "${extra_arguments[@]}")
printf 'Working directory: %s\n' "$runtime_working_dir"
printf 'WINEPREFIX=%s\n' "$wineprefix"
nvflex_print_command env "${environment_arguments[@]}" "${command_arguments[@]}"
$dry_run && exit 0

cd "$runtime_working_dir"
if [[ -z "$smoke_seconds" ]]
then
    exec env "${environment_arguments[@]}" "${command_arguments[@]}"
fi

env "${environment_arguments[@]}" "${command_arguments[@]}" &
demo_pid=$!
sleep "$smoke_seconds"
if ! kill -0 "$demo_pid" 2>/dev/null
then
    set +e
    wait "$demo_pid"
    demo_status=$?
    set -e
    printf 'FleX demo exited before the smoke interval with status %d.\n' \
        "$demo_status" >&2
    exit "$demo_status"
fi

kill -TERM "$demo_pid"
set +e
wait "$demo_pid"
set -e
printf 'FleX %s smoke test passed after %s seconds; process %d terminated.\n' \
    "$rhi" "$smoke_seconds" "$demo_pid"
