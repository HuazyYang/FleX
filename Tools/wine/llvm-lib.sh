#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

librarian=$(nvflex_find_command "${NVFLEX_LLVM_LIB:-}" llvm-lib-19 llvm-lib) ||
{
    printf 'llvm-lib was not found; install llvm-19 or set NVFLEX_LLVM_LIB.\n' >&2
    exit 1
}
exec "$librarian" "$@"
