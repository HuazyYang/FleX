#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

if [[ $# -lt 1 ]]
then
    printf 'Usage: wine-shader-tool.sh ShaderTool.exe [arguments...]\n' >&2
    exit 2
fi

wineprefix=$(nvflex_wineprefix)
wine_bin=${NVFLEX_WINE_BIN:-wine}
winepath_bin=${NVFLEX_WINEPATH_BIN:-winepath}
shader_tool=$1
shift
nvflex_require_file "$shader_tool" 'cross-built ShaderTool.exe'

to_windows_path()
{
    WINEPREFIX="$wineprefix" "$winepath_bin" -w "$1"
}

convert_option_list()
{
    local option_list=$1
    local components=()
    local converted=()
    local component
    IFS=';' read -r -a components <<<"$option_list"
    for component in "${components[@]}"
    do
        case "$component" in
            /*/*) converted+=("$(to_windows_path "$component")") ;;
            *) converted+=("$component") ;;
        esac
    done
    local joined
    printf -v joined '%s;' "${converted[@]}"
    printf '%s\n' "${joined%;}"
}

converted_arguments=()
for argument in "$@"
do
    case "$argument" in
        --fxc=*)
            converted_arguments+=("--fxc=$(to_windows_path "${argument#*=}")")
            ;;
        --depfile=*)
            converted_arguments+=("--depfile=$(to_windows_path "${argument#*=}")")
            ;;
        --options=*)
            converted_arguments+=("--options=$(convert_option_list "${argument#*=}")")
            ;;
        *)
            converted_arguments+=("$argument")
            ;;
    esac
done

exec env WINEPREFIX="$wineprefix" WINEARCH=win64 WINEDEBUG=-all \
    "$wine_bin" "$shader_tool" "${converted_arguments[@]}"
