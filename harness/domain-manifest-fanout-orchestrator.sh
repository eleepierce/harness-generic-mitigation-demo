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
# a prototype of the WIRING, not a reimplementation of DO's real orchestrator.
#
# Deliberately no rollback on ring failure: the mitigations in scope here are stateless
# reachability/restart-style checks, not stateful deployments, so "revert" has no
# well-defined meaning for them. If a genuinely stateful mitigation type is ever added,
# this would need real revert semantics (per Pradeep Chokka's stated leaf contract:
# "deployed, no-op, or failed", with the orchestrator triggering rollback on failure)
# before riding a real fan-out - this is a considered scope decision, not an oversight.
#
# Every cell in the toy manifest is mapped to the SAME already-proven real target
# (harness-poc's Aurora test cluster) rather than N fabricated per-cell targets - the
# manifest's cell/region identity is carried through as labeling/reporting context only.
# What's actually under test: ring ordering (ascending, sourced from a REAL manifest via
# expand-domain-manifest.sh, not a hardcoded list), parallel-within-ring,
# serial-across-rings, stopping (not silently continuing) on a ring's failure, and -
# as of this update - threading environment/ticket_id through to EVERY per-cell
# invocation so cosign branch-attestation and the ticket format check (both added to
# rungenericmitigation after this orchestrator was first proven on 2026-08-11) actually
# activate correctly per-ring rather than being silently bypassed.
#
# Written for /bin/bash 3.2 (macOS default) - no associative arrays, same constraint as
# fan-out-orchestrator.sh.
set -euo pipefail

PROJECT="reliability_engineering"
ORG="cloudnativeplatform"
PIPELINE_ID="rungenericmitigationdemo"

usage() {
  cat >&2 <<EOF
Usage: $0 <manifest-file> <environment> <target_host> <target_port> [ticket_id] \\
       [image] [docker_connector] [k8s_connector] [db_user] [db_password_secret] \\
       [image_fully_qualified] [verifier_image] [verifier_connector]

target_host/target_port: the real mitigation target every cell invocation runs against
  in this prototype (see header comment - there's no real per-cell target to resolve
  from the reference manifest, so all cells share the one already-proven target).

ticket_id: optional, applied uniformly to every cell in the run (it's audit metadata for
  the incident driving this mitigation, not a per-target value) - matches SSM: never
  required, in any environment, format-checked only if provided.

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
TICKET_ID="${5:-}"
IMAGE="${6:-547641909728.dkr.ecr.us-east-1.amazonaws.com/harness-poc/connectivity-check:v2.0.0}"
DOCKER_CONNECTOR="${7:-harnesspocdockerecr}"
K8S_CONNECTOR="${8:-harnesspoceks}"
DB_USER="${9:-admin}"
DB_PASSWORD_SECRET="${10:-harnessPocDbPasswordV2}"
IMAGE_FULLY_QUALIFIED="${11:-018537234677.dkr.ecr.us-east-1.amazonaws.com/github.com/twilio-internal/generic-mitigation-scripts/admin-verifier:1.4.2}"
VERIFIER_IMAGE="${12:-github.com/twilio-internal/generic-mitigation-scripts/admin-verifier:1.4.2}"
VERIFIER_CONNECTOR="${13:-otkEcrBroker}"

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

  local env_json
  env_json=$(printf '{"TARGET_HOST":"%s","TARGET_PORT":"%s","DB_USER":"%s","DB_PASSWORD":"__MITIGATION_SECRET__"}' \
    "$TARGET_HOST" "$TARGET_PORT" "$DB_USER")

  for i in "${!cell_names[@]}"; do
    local label="ring${ring}/${cell_names[$i]}/${cell_regions[$i]}"
    local trigger_json
    trigger_json=$(harness execute pipeline "$PIPELINE_ID" --project "$PROJECT" --org "$ORG" \
      --input "image=${IMAGE}" \
      --input "image_fully_qualified=${IMAGE_FULLY_QUALIFIED}" \
      --input "docker_connector=${DOCKER_CONNECTOR}" \
      --input "k8s_connector=${K8S_CONNECTOR}" \
      --input "env_json=${env_json}" \
      --input "secret_identifier=${DB_PASSWORD_SECRET}" \
      --input "verifier_image=${VERIFIER_IMAGE}" \
      --input "verifier_connector=${VERIFIER_CONNECTOR}" \
      --input "environment=${ENVIRONMENT}" \
      --input "ticket_id=${TICKET_ID}" \
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
