#!/bin/sh
# Shared entrypoint wrapper - decodes MITIGATION_ENV_JSON (a JSON object) into real
# exported environment variables, then execs the container's actual check script
# unchanged. This is what makes run-generic-mitigation-template.yaml (v2.0.0+)
# genuinely mitigation-agnostic - the template only ever sets one opaque env var
# (MITIGATION_ENV_JSON); each mitigation type's own real variable names (TARGET_HOST,
# REDIS_HOST, ZK_HOST, TARGET_POD, ...) live inside that JSON, decided per-pipeline,
# not baked into the shared template. Identical copy in every container-*/ directory
# since each container builds from its own directory as Docker build context (no
# shared build-context convention existed in this repo before, so duplicating this
# ~10-line file is simpler than introducing one).
#
# Usage in a Dockerfile: ENTRYPOINT ["/usr/local/bin/mitigation-entrypoint.sh", "/usr/local/bin/<real-check-script>"]
set -eu

# MITIGATION_ENV_JSON_B64 is the same JSON, base64-encoded, and takes precedence.
# It exists because the ECS execution path (org.run_ecs_container_stepgroup) passes env
# vars as a single comma-separated KEY=VALUE string, which its CLI splits on commas
# before splitting each pair on the FIRST "=" only (cli/pipelineutils/runecscontainer.go,
# strings.SplitN(env, "=", 2)). Raw JSON contains commas, so it either hard-errors in the
# CSV reader or silently truncates at the first comma - the silent case being the
# dangerous one. Base64 has no commas, and because the split is on the first "=" only,
# its "=" padding survives intact (verified). So on ECS, pass MITIGATION_ENV_JSON_B64;
# on Kubernetes, where env vars are structured and this problem doesn't exist, either
# works and MITIGATION_ENV_JSON stays the simpler choice.
if [ -n "${MITIGATION_ENV_JSON_B64:-}" ]; then
  MITIGATION_ENV_JSON="$(printf '%s' "$MITIGATION_ENV_JSON_B64" | base64 -d)"
  export MITIGATION_ENV_JSON
fi

if [ -n "${MITIGATION_ENV_JSON:-}" ]; then
  eval "$(echo "$MITIGATION_ENV_JSON" | jq -r 'to_entries | map("export \(.key)=\(.value|@sh)") | .[]')"
fi

# Secrets can't ride inside MITIGATION_ENV_JSON - <+secrets.getValue(...)> only resolves
# correctly as a template variable's whole value, not embedded as a JSON substring
# (confirmed empirically: it silently becomes the literal string "null" otherwise). So a
# secret is resolved separately into MITIGATION_SECRET_VALUE and only referenced here via
# this placeholder, substituted into whichever real env var(s) named it.
if [ -n "${MITIGATION_SECRET_VALUE:-}" ]; then
  for var in $(env | grep '=__MITIGATION_SECRET__$' | cut -d= -f1); do
    export "$var=$MITIGATION_SECRET_VALUE"
  done
fi

# --- Invocation marker -------------------------------------------------------
# One structured JSON line, emitted before the real check script runs so it exists
# even if that script then fails. Purpose: fleet-wide "when was a generic mitigation
# invoked" tracking in Springer, across platforms, off a single field.
#
# For logs ingested through the CloudWatch pipeline (the paved CND path: ECS awslogs
# driver -> CloudWatch -> Firehose -> telemetry gateway), the gateway's
# transform/promote_service_name processor lifts a `service.name` field out of a
# structured JSON body into the resource attributes, overriding whatever the log
# group name would otherwise imply. Precedence is: JSON body > log-group-name regex
# > unknown_service. That puts it in ClickHouse's *indexed* ServiceName column, so
#   WHERE ServiceName LIKE 'generic-mitigation%'
# finds every invocation with no collector-side config and no per-account plumbing
# beyond the telemetry-gateway-iac allowlist. This deliberately mirrors how ABBA's
# own filelog/ssm receiver hardcodes service.name=ssm for the SSM path, so both
# platforms are reachable from the same field rather than two bespoke ones.
#
# On paths that are NOT CloudWatch-ingested (OTK container tailing, AL23 filelog)
# the promotion does not happen -- there service.name has to come from an annotation,
# env var or pod label instead. The line is still emitted and still greppable in the
# log body there, it just isn't promoted to a resource attribute.
#
# Non-fatal by construction: an observability nicety must never be able to stop the
# actual mitigation from running, hence the `|| true`.
# Strip the .sh extension so the derived service name reads as a name
# ("generic-mitigation-redis-check") rather than a filename
# ("generic-mitigation-redis-check.sh"). MITIGATION_SERVICE_NAME overrides the
# whole thing where the image name and script name differ (container/ builds
# connectivity-check but runs check.sh, for instance).
_mitigation_script_name="${MITIGATION_SCRIPT_NAME:-$(basename "${1:-unknown}" .sh)}"
_mitigation_service_name="${MITIGATION_SERVICE_NAME:-generic-mitigation-${_mitigation_script_name}}"

# com.twilio.role identifies WHAT THE MITIGATION RAN AGAINST, and deliberately reuses
# the attribute name the SSM/ABBA path already carries, so one query shape works on
# both platforms:
#
#   ABBA:    ResourceAttributes['com.twilio.role']   (e.g. "crontroller-tx")
#   Harness: LogAttributes['com.twilio.role']
#
# On ABBA this comes for free: the SSM document runs ON the target host, so the
# host-level collector's resource detection stamps the target's own identity
# (com.twilio.role from the platform:role tag, plus host.id/host.name/realm/env)
# onto every line. That is the same role `owl generic-mitigation-ssm --role` targets.
#
# Harness has no equivalent, because the mitigation container runs BESIDE the target
# -- on a shared cluster or a Fargate task -- so its host attributes describe the
# executor, not the target. The target identity therefore has to be passed in
# explicitly or it does not exist anywhere in the telemetry. Hence this variable.
#
# It lands in log attributes rather than resource attributes on the CloudWatch path,
# since service.name is the only field the gateway promotes out of a JSON body. That
# is fine for the intended use (counting invocations, filtering by target) and is not
# worth spending service.name on -- service.name identifies which mitigation ran.
jq -n -c \
  --arg service_name "$_mitigation_service_name" \
  --arg script "$_mitigation_script_name" \
  --arg ticket "${MITIGATION_TICKET_ID:-}" \
  --arg environment "${MITIGATION_ENVIRONMENT:-}" \
  --arg role "${MITIGATION_TARGET_ROLE:-}" \
  '{"service.name": $service_name, "mitigation.invoked": true, "mitigation.script": $script}
   + (if $ticket == "" then {} else {"mitigation.ticket": $ticket} end)
   + (if $environment == "" then {} else {"mitigation.environment": $environment} end)
   + (if $role == "" then {} else {"com.twilio.role": $role} end)' \
  || true

exec "$@"
