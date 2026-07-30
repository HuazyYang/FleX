#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

windows_sdk_root=$(nvflex_windows_sdk_root)
wineprefix=$(nvflex_wineprefix)
wine_bin=${NVFLEX_WINE_BIN:-wine}
winepath_bin=${NVFLEX_WINEPATH_BIN:-winepath}

if [[ -n "${NVFLEX_FXC_EXECUTABLE:-}" ]]
then
    fxc_executable=$NVFLEX_FXC_EXECUTABLE
else
    fxc_executable=$(find "$windows_sdk_root/bin" \
        -path '*/x64/fxc.exe' -type f -print -quit 2>/dev/null || true)
fi

nvflex_require_file "$fxc_executable" 'Windows SDK fxc.exe'
nvflex_require_file "$wineprefix/system.reg" 'Wine system registry'

converted_arguments=()
convert_next_path=false
for argument in "$@"
do
    if $convert_next_path
    then
        converted_arguments+=("$(WINEPREFIX="$wineprefix" "$winepath_bin" -w "$argument")")
        convert_next_path=false
        continue
    fi

    case "$argument" in
        -Fh|-Fo|-Fd|-I)
            converted_arguments+=("$argument")
            convert_next_path=true
            ;;
        /*/*)
            converted_arguments+=("$(WINEPREFIX="$wineprefix" "$winepath_bin" -w "$argument")")
            ;;
        *)
            converted_arguments+=("$argument")
            ;;
    esac
done

exec env WINEPREFIX="$wineprefix" WINEARCH=win64 WINEDEBUG=-all \
    "$wine_bin" "$fxc_executable" "${converted_arguments[@]}"
