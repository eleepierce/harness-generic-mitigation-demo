#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${REDIS_HOST:-}" ]]; then
  echo "Error: Required environment variable not set"
  echo "Required: REDIS_HOST"
  exit 1
fi

REDIS_PORT="${REDIS_PORT:-6379}"
TEST_KEY="${TEST_KEY:-harness-poc-redis-check}"

echo "Testing Redis reachability + real command execution: ${REDIS_HOST}:${REDIS_PORT}..."

PING_RESULT=$(redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" PING)
echo "PING -> ${PING_RESULT}"
if [[ "${PING_RESULT}" != "PONG" ]]; then
  echo "REDIS_CHECK_FAILED: no PONG from PING"
  exit 1
fi

TEST_VALUE="harness-poc-$(date +%s 2>/dev/null || echo static)-${HOSTNAME:-unknown}"
redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" SET "${TEST_KEY}" "${TEST_VALUE}" > /dev/null
READBACK=$(redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" GET "${TEST_KEY}")
redis-cli -h "${REDIS_HOST}" -p "${REDIS_PORT}" DEL "${TEST_KEY}" > /dev/null

echo "SET ${TEST_KEY} = ${TEST_VALUE}"
echo "GET ${TEST_KEY} = ${READBACK}"

if [[ "${READBACK}" == "${TEST_VALUE}" ]]; then
  echo "REDIS_CHECK_OK: real SET/GET round-trip against ${REDIS_HOST}:${REDIS_PORT} succeeded"
else
  echo "REDIS_CHECK_FAILED: readback mismatch (expected ${TEST_VALUE}, got ${READBACK})"
  exit 1
fi
