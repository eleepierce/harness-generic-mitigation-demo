#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${ES_HOST:-}" ]]; then
  echo "Error: Required environment variable not set"
  echo "Required: ES_HOST"
  exit 1
fi

ES_PORT="${ES_PORT:-9200}"
TEST_INDEX="${TEST_INDEX:-harness-poc-es-check}"
TEST_ID="${TEST_ID:-1}"
BASE_URL="http://${ES_HOST}:${ES_PORT}"

echo "Testing Elasticsearch reachability + real command execution: ${BASE_URL}..."

PING_RESULT=$(curl -sf -o /dev/null -w "%{http_code}" "${BASE_URL}/" || echo "FAILED")
echo "GET / -> HTTP ${PING_RESULT}"
if [[ "${PING_RESULT}" != "200" ]]; then
  echo "ES_CHECK_FAILED: cluster root endpoint unreachable"
  exit 1
fi

TEST_VALUE="harness-poc-$(date +%s 2>/dev/null || echo static)-${HOSTNAME:-unknown}"

INDEX_RESULT=$(curl -sf -X PUT "${BASE_URL}/${TEST_INDEX}/_doc/${TEST_ID}?refresh=true" \
  -H "Content-Type: application/json" \
  -d "{\"proof\":\"${TEST_VALUE}\"}")
echo "PUT ${TEST_INDEX}/_doc/${TEST_ID} -> ${INDEX_RESULT}"

READBACK=$(curl -sf "${BASE_URL}/${TEST_INDEX}/_doc/${TEST_ID}" | grep -o "\"proof\":\"[^\"]*\"" | cut -d'"' -f4)
echo "GET ${TEST_INDEX}/_doc/${TEST_ID} -> proof=${READBACK}"

curl -sf -X DELETE "${BASE_URL}/${TEST_INDEX}" > /dev/null || true

if [[ "${READBACK}" == "${TEST_VALUE}" ]]; then
  echo "ES_CHECK_OK: real index/get document round-trip against ${BASE_URL} succeeded"
else
  echo "ES_CHECK_FAILED: readback mismatch (expected ${TEST_VALUE}, got ${READBACK})"
  exit 1
fi
