#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ZK_HOST:-}" ]]; then
  echo "Error: Required environment variable not set"
  echo "Required: ZK_HOST"
  exit 1
fi

ZK_PORT="${ZK_PORT:-2181}"
TEST_PATH="${TEST_PATH:-/harness-poc-zk-check}"
ZK_SERVER="${ZK_HOST}:${ZK_PORT}"

echo "Testing Zookeeper reachability + real command execution: ${ZK_SERVER}..."

TEST_VALUE="harness-poc-$(date +%s 2>/dev/null || echo static)-${HOSTNAME:-unknown}"

zkCli.sh -server "${ZK_SERVER}" delete "${TEST_PATH}" >/dev/null 2>&1 || true

CREATE_OUTPUT=$(zkCli.sh -server "${ZK_SERVER}" create "${TEST_PATH}" "${TEST_VALUE}" 2>&1)
if ! echo "${CREATE_OUTPUT}" | grep -q "Created ${TEST_PATH}"; then
  echo "${CREATE_OUTPUT}"
  echo "ZK_CHECK_FAILED: create did not confirm"
  exit 1
fi
echo "create ${TEST_PATH} ${TEST_VALUE} -> confirmed"

GET_OUTPUT=$(zkCli.sh -server "${ZK_SERVER}" get "${TEST_PATH}" 2>&1)

zkCli.sh -server "${ZK_SERVER}" delete "${TEST_PATH}" >/dev/null 2>&1 || true

if echo "${GET_OUTPUT}" | grep -qF "${TEST_VALUE}"; then
  echo "get ${TEST_PATH} -> ${TEST_VALUE}"
  echo "ZK_CHECK_OK: real create/get znode round-trip against ${ZK_SERVER} succeeded"
else
  echo "${GET_OUTPUT}"
  echo "ZK_CHECK_FAILED: readback did not contain expected value ${TEST_VALUE}"
  exit 1
fi
