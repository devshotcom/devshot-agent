#!/bin/sh

devshot_credentials_file="${DEVSHOT_CREDENTIALS_FILE:-/opt/devshot/credentials.env}"
if [ -f "$devshot_credentials_file" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$devshot_credentials_file"
  set +a
fi
