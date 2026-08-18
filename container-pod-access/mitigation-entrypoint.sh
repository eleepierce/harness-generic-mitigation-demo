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

exec "$@"
