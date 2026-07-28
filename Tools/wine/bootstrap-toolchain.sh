#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

msvc_wine_repository=https://github.com/mstorsjo/msvc-wine.git
windows_sdk_version=10.0.26100

show_help()
{
    cat <<EOF
Usage: bootstrap-toolchain.sh [--check] [--install --accept-msvc-license]

Validate or provision the Windows x64 cross-build toolchain used by FleX.
Native compilation uses system LLVM 19. MSVC 14.44 and Windows SDK
$windows_sdk_version are installed in the selected Wine prefix.

--install requires explicit --accept-msvc-license. It does not install host
packages; install CMake, Ninja, LLVM 19, Wine, winbind, Git, Python 3, curl,
tar, unzip, and msitools through the host package manager first.
EOF
}

mode=check
accept_msvc_license=false
while [[ $# -gt 0 ]]
do
    case "$1" in
        --check)
            mode=check
            shift
            ;;
        --install)
            mode=install
            shift
            ;;
        --accept-msvc-license)
            accept_msvc_license=true
            shift
            ;;
        -h|--help)
            show_help
            exit 0
            ;;
        *)
            printf 'Unknown argument: %s\n' "$1" >&2
            show_help >&2
            exit 2
            ;;
    esac
done

repo_root=$(nvflex_repo_root)
toolchain_root=$(nvflex_toolchain_root "$repo_root")
wineprefix=$(nvflex_wineprefix)
msvc_root=$(nvflex_vs_root)
windows_sdk_root=$(nvflex_windows_sdk_root)
msvc_wine_root=${NVFLEX_MSVC_WINE_ROOT:-"$toolchain_root/msvc-wine"}
msvc_layout_root="$toolchain_root/msvc-layout"
download_root="$toolchain_root/downloads"

required_commands=(
    cmake ninja clang-19 lld-link-19 llvm-lib-19 llvm-rc-19 llvm-mt-19
    wine winepath winedbg gdb git python3 curl tar unzip
)

check_commands()
{
    local missing=false
    local command_name
    for command_name in "${required_commands[@]}"
    do
        if ! command -v "$command_name" >/dev/null 2>&1
        then
            printf 'Missing host command: %s\n' "$command_name" >&2
            missing=true
        fi
    done

    if [[ "$mode" == install ]] && ! command -v msiextract >/dev/null 2>&1
    then
        printf 'Missing host command required for installation: msiextract\n' >&2
        missing=true
    fi

    $missing && return 1
    return 0
}

check_toolchain_files()
{
    local missing=false
    local msvc_dir sdk_include fxc_path
    msvc_dir=$(find "$msvc_root/VC/Tools/MSVC" -maxdepth 1 -mindepth 1 \
        -type d -name '14.44.*' -print -quit 2>/dev/null || true)
    sdk_include=$(find "$windows_sdk_root/Include" -maxdepth 1 -mindepth 1 \
        -type d -name '10.0.26100.*' -print -quit 2>/dev/null || true)
    fxc_path=$(find "$windows_sdk_root/bin" \
        -path '*/x64/fxc.exe' -type f -print -quit 2>/dev/null || true)

    if [[ -z "$msvc_dir" ]]
    then
        printf 'Missing MSVC 14.44 x64 tools below: %s\n' "$msvc_root" >&2
        missing=true
    fi
    if [[ -z "$sdk_include" ]]
    then
        printf 'Missing Windows SDK 10.0.26100 below: %s\n' "$windows_sdk_root" >&2
        missing=true
    fi
    if [[ -z "$fxc_path" ]]
    then
        printf 'Missing Windows SDK x64 fxc.exe below: %s\n' "$windows_sdk_root" >&2
        missing=true
    fi

    $missing && return 1
    return 0
}

install_toolchain()
{
    if ! $accept_msvc_license
    then
        printf '%s\n' \
            '--install requires --accept-msvc-license after reviewing Microsoft licensing.' >&2
        exit 2
    fi

    mkdir -p "$toolchain_root" "$download_root"
    if [[ ! -d "$msvc_wine_root/.git" ]]
    then
        git clone "$msvc_wine_repository" "$msvc_wine_root"
    fi

    if check_toolchain_files >/dev/null 2>&1
    then
        return
    fi

    python3 "$msvc_wine_root/vsdownload.py" \
        --cache "$download_root/msvc-cache" \
        --major 17 \
        --sdk-version "$windows_sdk_version" \
        --architecture x64 \
        --with-default no \
        --with-workload no \
        --with-msvc yes \
        --with-sdk yes \
        --with-asan no \
        --with-atl no \
        --with-dia no \
        --with-msbuild no \
        --with-devcmd no \
        --accept-license \
        --dest "$msvc_layout_root"

    WINEPREFIX="$wineprefix" WINEARCH=win64 \
        "$msvc_wine_root/install.sh" "$msvc_layout_root"

    mkdir -p "$msvc_root" "$windows_sdk_root"
    cp -a "$msvc_layout_root/VC" "$msvc_root/"
    for package_directory in Common7 MSBuild
    do
        if [[ -d "$msvc_layout_root/$package_directory" ]]
        then
            cp -a "$msvc_layout_root/$package_directory" "$msvc_root/"
        fi
    done
    cp -a "$msvc_layout_root/Windows Kits/10/." "$windows_sdk_root/"
}

check_commands
if [[ "$mode" == install ]]
then
    install_toolchain
fi
check_toolchain_files

printf 'FleX Windows clang-cl toolchain is ready: %s\n' "$wineprefix"
