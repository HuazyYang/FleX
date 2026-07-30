#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

port=
rhi=
dev_mode=1
while [[ $# -gt 0 ]]
do
    case "$1" in
        --port) port=${2:?--port requires a value}; shift 2 ;;
        --rhi) rhi=${2:?--rhi requires a value}; shift 2 ;;
        --dev) dev_mode=${2:?--dev requires a value}; shift 2 ;;
        -h|--help)
            printf 'Usage: debug-server.sh --port PORT --rhi d3d11|d3d12 [--dev 0|1]\n'
            exit 0
            ;;
        *) printf 'Unknown argument: %s\n' "$1" >&2; exit 2 ;;
    esac
done

[[ "$port" =~ ^[0-9]+$ ]] ||
{
    printf 'A numeric --port is required.\n' >&2
    exit 2
}
case "$rhi" in d3d11|d3d12) ;; *)
    printf 'Unsupported RHI: %s\n' "$rhi" >&2
    exit 2
esac
case "$dev_mode" in 0|1) ;; *)
    printf 'Unsupported --dev value: %s\n' "$dev_mode" >&2
    exit 2
esac

repo_root=$(nvflex_repo_root)
build_root=${NVFLEX_BUILD_ROOT:-"$repo_root/build/wine-clang"}
run_root=${NVFLEX_RUN_ROOT:-"$repo_root/.run"}
wineprefix=$(nvflex_wineprefix)
executable="$build_root/bin/Debug/NvFlexDemoDebugD3D_win64.exe"
runtime_working_dir="$repo_root/bin/win64"

NVFLEX_WINEPREFIX="$wineprefix" "$script_dir/check-prefix.sh" >/dev/null
nvflex_require_file "$executable" 'Debug FleX demo executable'
mkdir -p "$run_root/logs/$rhi" "$run_root/cache/dxvk" "$run_root/cache/vkd3d"

demo_arguments=("--dev=$dev_mode" "--windowed=1280x720" "--vsync=0")
debug_environment=(
    "WINEPREFIX=$wineprefix"
    "WINEARCH=win64"
    "WINEDEBUG=${NVFLEX_WINEDEBUG:--all}"
    "DXVK_LOG_LEVEL=${DXVK_LOG_LEVEL:-info}"
    "DXVK_LOG_PATH=$run_root/logs/$rhi"
)
if [[ "$rhi" == d3d11 ]]
then
    debug_environment+=("DXVK_STATE_CACHE_PATH=$run_root/cache/dxvk")
else
    demo_arguments+=("--d3d12")
    debug_environment+=(
        "VKD3D_DEBUG=${VKD3D_DEBUG:-info}"
        "VKD3D_LOG_FILE=$run_root/logs/d3d12/vkd3d-proton-debug.log"
        "VKD3D_SHADER_CACHE_PATH=$run_root/cache/vkd3d"
    )
fi

cd "$runtime_working_dir"
exec env "${debug_environment[@]}" \
    winedbg --gdb --no-start --port "$port" \
    "$executable" "${demo_arguments[@]}"
