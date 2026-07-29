#!/bin/sh
# Fail closed when a guest image cannot safely execute Studio tools. The
# console wraps every ordinary command in a Tini-owned process group so timed
# commands and detached descendants are reaped instead of poisoning the single
# guest console lane. Publishing an image without any of these binaries makes
# every run_command/command_task/preview probe fail before user code executes.
set -eu

missing=""
for binary in timeout setsid mktemp tini dd tail; do
    if ! command -v "$binary" >/dev/null 2>&1; then
        missing="${missing} ${binary}"
    fi
done

if [ -n "$missing" ]; then
    echo "ERROR: Studio runtime is missing supervised-command prerequisites:${missing}" >&2
    exit 1
fi

timeout_version=$(LC_ALL=C timeout --version 2>/dev/null) || timeout_version=""
case "$timeout_version" in
    "timeout (GNU coreutils) "*) ;;
    *)
        echo "ERROR: Studio runtime requires GNU coreutils timeout; BusyBox timeout leaves orphan watchdog processes" >&2
        exit 1
        ;;
esac

if ! timeout -k 1 5 setsid tini -s -- /bin/sh -c 'exit 0'; then
    echo "ERROR: Studio supervised-command smoke check failed" >&2
    exit 1
fi

echo "Studio runtime prerequisites verified: GNU timeout, setsid, mktemp, tini, dd, tail"
