#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TARGET_HOST:-}" ]] || [[ -z "${TARGET_PORT:-}" ]]; then
  echo "Error: Required environment variables not set"
  echo "Required: TARGET_HOST, TARGET_PORT"
  exit 1
fi

echo "Testing TCP reachability to ${TARGET_HOST}:${TARGET_PORT}..."
if timeout 5 bash -c "cat < /dev/null > /dev/tcp/${TARGET_HOST}/${TARGET_PORT}" 2>/dev/null; then
  echo "REACHABLE: successfully opened TCP connection to ${TARGET_HOST}:${TARGET_PORT}"
else
  echo "UNREACHABLE: could not open TCP connection to ${TARGET_HOST}:${TARGET_PORT}"
  exit 1
fi
