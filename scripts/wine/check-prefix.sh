#!/usr/bin/env bash

set -euo pipefail

script_dir=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)
# shellcheck source=common.sh
source "$script_dir/common.sh"

if [[ "${1:-}" == "--help" ]]
then
    printf 'Usage: check-prefix.sh\n'
    exit 0
fi
if [[ $# -ne 0 ]]
then
    printf 'Unknown argument: %s\n' "$1" >&2
    exit 2
fi

wineprefix=$(nvflex_wineprefix)
system_registry="$wineprefix/system.reg"
user_registry="$wineprefix/user.reg"
system32="$wineprefix/drive_c/windows/system32"

nvflex_require_file "$system_registry" 'Wine system registry'
nvflex_require_file "$user_registry" 'Wine user registry'
rg -q '^#arch=win64$' "$system_registry" ||
{
    printf 'Wine prefix is not 64-bit: %s\n' "$wineprefix" >&2
    exit 1
}

for override_name in d3d11 d3d12 d3d12core dxgi
do
    rg -q "\"$override_name\"=\"native\"" "$user_registry" ||
    {
        printf 'Missing native DLL override for %s in %s\n' \
            "$override_name" "$user_registry" >&2
        exit 1
    }
    nvflex_require_file "$system32/$override_name.dll" "$override_name runtime"
done

for runtime_name in msvcp140 vcruntime140 vcruntime140_1
do
    nvflex_require_file "$system32/$runtime_name.dll" "$runtime_name runtime"
done

printf 'Wine prefix is ready: %s\n' "$wineprefix"
