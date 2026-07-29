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

if ! timeout -k 1 5 setsid tini -s -- /bin/sh -c 'exit 0'; then
    echo "ERROR: Studio supervised-command smoke check failed" >&2
    exit 1
fi

echo "Studio runtime prerequisites verified: timeout setsid mktemp tini dd tail"
