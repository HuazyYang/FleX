#!/usr/bin/env bash

nvflex_repo_root()
{
    local script_dir
    script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
    cd "$script_dir/../.." && pwd -P
}

nvflex_toolchain_root()
{
    local repo_root=$1
    printf '%s\n' "${NVFLEX_TOOLCHAIN_ROOT:-$repo_root/.toolchains}"
}

nvflex_wineprefix()
{
    if [[ -n "${NVFLEX_WINEPREFIX:-}" ]]
    then
        printf '%s\n' "$NVFLEX_WINEPREFIX"
    elif [[ -n "${HOME:-}" ]]
    then
        printf '%s/.wineprefixes/dev-x64\n' "$HOME"
    else
        printf 'Unable to determine the Wine prefix; set NVFLEX_WINEPREFIX.\n' >&2
        return 1
    fi
}

nvflex_vs_root()
{
    local prefix
    prefix=$(nvflex_wineprefix)
    printf '%s\n' "${NVFLEX_MSVC_ROOT:-$prefix/drive_c/Program Files/Microsoft Visual Studio/2022/BuildTools}"
}

nvflex_windows_sdk_root()
{
    local prefix
    prefix=$(nvflex_wineprefix)
    printf '%s\n' "${NVFLEX_WINDOWS_SDK_ROOT:-$prefix/drive_c/Program Files (x86)/Windows Kits/10}"
}

nvflex_activate_msvc_environment()
{
    local repo_root=$1
    local vs_root sdk_root msvc_dir sdk_include sdk_version sdk_lib
    : "$repo_root"
    vs_root=$(nvflex_vs_root)
    sdk_root=$(nvflex_windows_sdk_root)

    msvc_dir=$(find "$vs_root/VC/Tools/MSVC" -maxdepth 1 -mindepth 1 \
        -type d -name '14.44.*' -print 2>/dev/null | sort -V | tail -1)
    sdk_include=$(find "$sdk_root/Include" -maxdepth 1 -mindepth 1 \
        -type d -name '10.0.26100.*' -print 2>/dev/null | sort -V | tail -1)
    if [[ -z "$msvc_dir" || -z "$sdk_include" ]]
    then
        printf 'Missing MSVC 14.44 or Windows SDK 10.0.26100 in %s\n' \
            "$(nvflex_wineprefix)" >&2
        return 1
    fi

    sdk_version=${sdk_include##*/}
    sdk_lib="$sdk_root/Lib/$sdk_version"
    export INCLUDE="$msvc_dir/include;$sdk_include/shared;$sdk_include/ucrt;$sdk_include/um;$sdk_include/winrt"
    export LIB="$msvc_dir/lib/x64;$sdk_lib/ucrt/x64;$sdk_lib/um/x64"
    export LIBPATH="$LIB"
    export TARGET_TRIPLE=x86_64-windows-msvc
}

nvflex_find_command()
{
    local requested_name=$1
    shift
    local candidate

    if [[ -n "$requested_name" ]] && command -v "$requested_name" >/dev/null 2>&1
    then
        command -v "$requested_name"
        return
    fi

    for candidate in "$@"
    do
        if command -v "$candidate" >/dev/null 2>&1
        then
            command -v "$candidate"
            return
        fi
    done
    return 1
}

nvflex_require_file()
{
    local file_path=$1
    local description=$2
    if [[ ! -f "$file_path" ]]
    then
        printf 'Missing %s: %s\n' "$description" "$file_path" >&2
        return 1
    fi
}

nvflex_print_command()
{
    printf 'Command:'
    printf ' %q' "$@"
    printf '\n'
}
