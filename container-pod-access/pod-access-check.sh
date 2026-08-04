#!/usr/bin/env bash
set -euo pipefail

if [[ -z "${TARGET_POD:-}" ]]; then
  echo "Error: Required environment variable not set"
  echo "Required: TARGET_POD"
  exit 1
fi

TARGET_NAMESPACE="${TARGET_NAMESPACE:-default}"
TARGET_FILE="${TARGET_FILE:-/tmp/proof.txt}"

echo "Testing pod-level access: exec into ${TARGET_NAMESPACE}/${TARGET_POD} and retrieve ${TARGET_FILE}..."

if OUTPUT=$(kubectl exec -n "${TARGET_NAMESPACE}" "${TARGET_POD}" -- cat "${TARGET_FILE}" 2>&1); then
  echo "POD_ACCESS_OK: successfully retrieved file content from ${TARGET_NAMESPACE}/${TARGET_POD}:${TARGET_FILE}"
  echo "--- retrieved content ---"
  echo "${OUTPUT}"
  echo "--- end retrieved content ---"
else
  echo "POD_ACCESS_FAILED: could not retrieve ${TARGET_FILE} from ${TARGET_NAMESPACE}/${TARGET_POD}"
  echo "${OUTPUT}"
  exit 1
fi
