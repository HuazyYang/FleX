#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

manifest_tool=$(nvflex_find_command "${NVFLEX_LLVM_MT:-}" llvm-mt-19 llvm-mt) ||
{
    printf 'llvm-mt was not found; install llvm-19 or set NVFLEX_LLVM_MT.\n' >&2
    exit 1
}
exec "$manifest_tool" "$@"
