#!/usr/bin/env bash
# Prototype: given N separate Harness pipeline identifiers (the real shape of
# CND cellularization - each cell has its own statically-defined pipeline,
# confirmed 2026-08-05 - not one pipeline with a loop strategy), trigger all
# of them and aggregate a single pass/fail report. Answers the actual
# remaining mechanism question from the cellularization research: "given N
# pipeline IDs, how do you run one mitigation across all of them and know
# the combined result," independent of the still-open org-level question of
# how those N pipeline IDs get discovered/enumerated for a given domain.
#
# Written for /bin/bash 3.2 (macOS default) - deliberately avoids associative
# arrays (declare -A, Bash 4+ only) in favor of parallel indexed arrays.
set -euo pipefail

PROJECT="reliability_engineering"
ORG="cloudnativeplatform"
PIPELINES=("$@")

if [[ ${#PIPELINES[@]} -eq 0 ]]; then
  echo "Usage: $0 <pipeline-id-1> <pipeline-id-2> ..."
  exit 1
fi

EXEC_IDS=()

echo "=== Triggering ${#PIPELINES[@]} pipelines ==="
for p in "${PIPELINES[@]}"; do
  TRIGGER_JSON=$(harness execute pipeline "$p" --project "$PROJECT" --org "$ORG" --format json)
  EXEC_ID=$(echo "$TRIGGER_JSON" | python3 -c "import json,sys; print(json.load(sys.stdin)['uuid'])")
  EXEC_IDS+=("$EXEC_ID")
  echo "  $p -> execution $EXEC_ID"
done

echo ""
echo "=== Polling until all reach a terminal state ==="
FINAL_STATUS=()
for _ in "${PIPELINES[@]}"; do FINAL_STATUS+=(""); done

DONE_COUNT=0
TOTAL=${#PIPELINES[@]}
while [[ $DONE_COUNT -lt $TOTAL ]]; do
  DONE_COUNT=0
  for i in "${!PIPELINES[@]}"; do
    if [[ -n "${FINAL_STATUS[$i]}" ]]; then
      DONE_COUNT=$((DONE_COUNT + 1))
      continue
    fi
    p="${PIPELINES[$i]}"
    eid="${EXEC_IDS[$i]}"
    status=$(harness get execution "$p/$eid" --project "$PROJECT" --org "$ORG" --format json 2>/dev/null \
      | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pipelineExecutionSummary',{}).get('status',''))" 2>/dev/null || echo "")
    case "$status" in
      Success|Failed|Errored|Aborted|Expired)
        FINAL_STATUS[$i]="$status"
        DONE_COUNT=$((DONE_COUNT + 1))
        ;;
    esac
  done
  [[ $DONE_COUNT -lt $TOTAL ]] && sleep 5
done

echo ""
echo "=== Aggregate result ==="
OVERALL_OK=true
for i in "${!PIPELINES[@]}"; do
  p="${PIPELINES[$i]}"
  s="${FINAL_STATUS[$i]}"
  eid="${EXEC_IDS[$i]}"
  printf "  %-30s %-10s execution=%s\n" "$p" "$s" "$eid"
  [[ "$s" == "Success" ]] || OVERALL_OK=false
done

echo ""
if $OVERALL_OK; then
  echo "FAN_OUT_OK: all ${TOTAL} pipelines succeeded"
  exit 0
else
  echo "FAN_OUT_PARTIAL_OR_FAILED: not all pipelines succeeded"
  exit 1
fi
