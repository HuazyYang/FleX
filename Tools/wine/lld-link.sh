#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

repo_root=$(nvflex_repo_root)
nvflex_activate_msvc_environment "$repo_root"

linker=$(nvflex_find_command "${NVFLEX_LLD_LINK:-}" lld-link-19 lld-link) ||
{
    printf 'lld-link was not found; install lld-19 or set NVFLEX_LLD_LINK.\n' >&2
    exit 1
}
exec "$linker" "$@"
