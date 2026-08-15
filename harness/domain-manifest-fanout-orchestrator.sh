#!/usr/bin/env bash
# Domain-manifest-driven fan-out, superseding fan-out-orchestrator.sh's premise (that
# script trigger a flat, manually-enumerated list of statically-defined per-cell
# pipelines - confirmed wrong 2026-08-11: Asaf Erlich/Ryan Bezdicek, Deployment
# Orchestration, "we would treat a generic mitigation as any other deployment into a
# domain" - one pipeline per SERVICE, cells are just parameterized invocations of it,
# ring-ordered).
#
# This script proves that corrected model against CND (domain-manifest-example.yaml,
# the real Foundation repo's own manifest) ahead of DO's OTK backport landing - see
# ssm_divergence_effort.md's "Update 2026-08-11" sections for the full context. It is
# a prototype of the WIRING, not a reimplementation of DO's real orchestrator: there is
# no real rollback here (these are stateless reachability mitigations, nothing to
# revert), and every cell in the toy manifest is mapped to the SAME already-proven real
# target (harness-poc's Aurora test cluster) rather than N fabricated per-cell targets -
# the manifest's cell/region identity is carried through as labeling/reporting context
# only. What's actually under test: ring ordering (ascending, sourced from a REAL
# manifest via expand-domain-manifest.sh, not a hardcoded list), parallel-within-ring,
# serial-across-rings, and stopping (not silently continuing) on a ring's failure -
# mirroring Pradeep Chokka's stated contract: "the orchestrator owns the sequencing and
# gating... the leaf does the actual work... deployed, no-op, or failed."
#
# Written for /bin/bash 3.2 (macOS default) - no associative arrays, same constraint as
# fan-out-orchestrator.sh.
set -euo pipefail

PROJECT="reliability_engineering"
ORG="cloudnativeplatform"
PIPELINE_ID="rungenericmitigationdemo"

usage() {
  cat >&2 <<EOF
Usage: $0 <manifest-file> <environment> <target_host> <target_port> \\
       [image] [docker_connector] [k8s_connector] [db_user] [db_password_secret]

target_host/target_port: the real mitigation target every cell invocation runs against
  in this prototype (see header comment - there's no real per-cell target to resolve
  from the reference manifest, so all cells share the one already-proven target).

Defaults for the optional trailing args match the values already proven working
elsewhere in this repo's README/prior executions - override if yours differ.
EOF
  exit 1
}

[[ $# -ge 4 ]] || usage

MANIFEST_FILE="$1"
ENVIRONMENT="$2"
TARGET_HOST="$3"
TARGET_PORT="$4"
IMAGE="${5:-547641909728.dkr.ecr.us-east-1.amazonaws.com/harness-poc/connectivity-check:v1.0.4}"
DOCKER_CONNECTOR="${6:-harnesspocdockerecr}"
K8S_CONNECTOR="${7:-harnesspoceks}"
DB_USER="${8:-admin}"
DB_PASSWORD_SECRET="${9:-harnessPocDbPasswordV2}"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPAND_SCRIPT="${SCRIPT_DIR}/expand-domain-manifest.sh"

# --- Expand once, up front. Pure topology math - no reason to re-derive per ring. ---
EXPANDED="$("$EXPAND_SCRIPT" "$MANIFEST_FILE" "$ENVIRONMENT")"
[[ -n "$EXPANDED" ]] || { echo "No cells expanded for environment '${ENVIRONMENT}' - nothing to do." >&2; exit 1; }

RINGS=($(echo "$EXPANDED" | cut -f1 | sort -un))
echo "=== Expanded ${ENVIRONMENT}: ${#RINGS[@]} ring(s): ${RINGS[*]} ==="

trigger_and_poll_ring() {
  local ring="$1"
  local ring_lines
  ring_lines="$(echo "$EXPANDED" | awk -F'\t' -v r="$ring" '$1 == r')"

  local cell_names=() cell_regions=() exec_ids=() final_status=()
  while IFS=$'\t' read -r _ cname cregion; do
    cell_names+=("$cname")
    cell_regions+=("$cregion")
  done <<< "$ring_lines"

  local n=${#cell_names[@]}
  echo ""
  echo "=== Ring ${ring}: triggering ${n} cell(s) in parallel ==="

  for i in "${!cell_names[@]}"; do
    local label="ring${ring}/${cell_names[$i]}/${cell_regions[$i]}"
    local trigger_json
    trigger_json=$(harness execute pipeline "$PIPELINE_ID" --project "$PROJECT" --org "$ORG" \
      --input "image=${IMAGE}" \
      --input "target_host=${TARGET_HOST}" \
      --input "target_port=${TARGET_PORT}" \
      --input "docker_connector=${DOCKER_CONNECTOR}" \
      --input "k8s_connector=${K8S_CONNECTOR}" \
      --input "db_user=${DB_USER}" \
      --input "db_password_secret=${DB_PASSWORD_SECRET}" \
      --format json)
    local eid
    eid=$(echo "$trigger_json" | python3 -c "import json,sys; print(json.load(sys.stdin)['uuid'])")
    exec_ids+=("$eid")
    final_status+=("")
    echo "  ${label} -> execution ${eid}"
  done

  echo "--- polling ring ${ring} until all cells reach a terminal state ---"
  local done_count=0
  while [[ $done_count -lt $n ]]; do
    done_count=0
    for i in "${!exec_ids[@]}"; do
      if [[ -n "${final_status[$i]}" ]]; then
        done_count=$((done_count + 1))
        continue
      fi
      local status
      status=$(harness get execution "${PIPELINE_ID}/${exec_ids[$i]}" --project "$PROJECT" --org "$ORG" --format json 2>/dev/null \
        | python3 -c "import json,sys; d=json.load(sys.stdin); print(d.get('pipelineExecutionSummary',{}).get('status',''))" 2>/dev/null || echo "")
      case "$status" in
        Success|Failed|Errored|Aborted|Expired)
          final_status[$i]="$status"
          done_count=$((done_count + 1))
          ;;
      esac
    done
    [[ $done_count -lt $n ]] && sleep 5
  done

  local ring_ok=true
  for i in "${!cell_names[@]}"; do
    local label="ring${ring}/${cell_names[$i]}/${cell_regions[$i]}"
    printf "  %-30s %-10s execution=%s\n" "$label" "${final_status[$i]}" "${exec_ids[$i]}"
    [[ "${final_status[$i]}" == "Success" ]] || ring_ok=false
  done

  $ring_ok
}

for ring in "${RINGS[@]}"; do
  if ! trigger_and_poll_ring "$ring"; then
    echo ""
    echo "RING_FAILED: ring ${ring} did not fully succeed - stopping before the next ring."
    echo "(No rollback attempted: these are stateless reachability checks, nothing to revert."
    echo " A real deploy-shaped mitigation riding DO's orchestrator would roll back here instead.)"
    exit 1
  fi
  echo "=== Ring ${ring}: all cells succeeded, proceeding ==="
done

echo ""
echo "FAN_OUT_OK: all rings, all cells succeeded, in order (${RINGS[*]})"
