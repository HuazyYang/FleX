#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

resource_compiler=$(nvflex_find_command "${NVFLEX_LLVM_RC:-}" llvm-rc-19 llvm-rc) ||
{
    printf 'llvm-rc was not found; install llvm-19 or set NVFLEX_LLVM_RC.\n' >&2
    exit 1
}
exec "$resource_compiler" "$@"
