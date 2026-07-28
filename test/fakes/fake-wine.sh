#!/usr/bin/env bash

set -euo pipefail

if [[ -n "${FAKE_WINE_LOG:-}" ]]
then
    printf '%q ' "$@" >>"$FAKE_WINE_LOG"
    printf '\n' >>"$FAKE_WINE_LOG"
fi

case "${FAKE_WINE_MODE:-timeout}" in
    timeout)
        trap 'exit 0' TERM INT
        while :
        do
            sleep 1
        done
        ;;
    fail)
        exit "${FAKE_WINE_EXIT_CODE:-7}"
        ;;
    *)
        printf 'Unsupported FAKE_WINE_MODE: %s\n' "$FAKE_WINE_MODE" >&2
        exit 2
        ;;
esac
