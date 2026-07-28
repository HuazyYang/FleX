#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

repo_root=$(nvflex_repo_root)
nvflex_activate_msvc_environment "$repo_root"

clang_cl=$(nvflex_find_command "${NVFLEX_CLANG_CL:-}" clang-cl-19 clang-19 clang-cl) ||
{
    printf 'Clang 19 was not found; install it or set NVFLEX_CLANG_CL.\n' >&2
    exit 1
}

exec "$clang_cl" \
    --driver-mode=cl \
    --target=x86_64-pc-windows-msvc \
    -fms-compatibility-version=19.44 \
    -fuse-ld=lld \
    "$@"
