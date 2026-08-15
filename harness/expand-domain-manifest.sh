#!/usr/bin/env bash
# Pure topology expansion - mirrors `cn-monorepo manifest expand --granularity=cell`
# (the real command, confirmed against twilio-internal/cloud-native-monorepo-foundation's
# docs/cloud-native/ci-cd/domain-manifest.md and Pradeep Chokka's domain-manifest V2 demo,
# both pulled 2026-08-11). That doc's own words: "pure topology math: no infra join, no
# gates" - this script does exactly that and nothing more, which is why it's safe to
# reimplement standalone here rather than needing the real cn-monorepo CLI installed.
#
# Reads a domain-manifest.yaml, emits one line per cell, ordered by ring ascending
# (ties broken by declaration order within the ring - matches "cells in a ring deploy
# together in parallel" from the schema doc):
#   <ring>\t<cell-name>\t<region>
#
# Usage: expand-domain-manifest.sh <manifest-file> <environment>
set -euo pipefail

if ! command -v yq >/dev/null 2>&1; then
  echo "expand-domain-manifest.sh: requires yq (brew install yq)" >&2
  exit 1
fi

MANIFEST_FILE="${1:?Usage: $0 <manifest-file> <environment>}"
ENVIRONMENT="${2:?Usage: $0 <manifest-file> <environment>}"

if [[ ! -f "$MANIFEST_FILE" ]]; then
  echo "expand-domain-manifest.sh: manifest file not found: $MANIFEST_FILE" >&2
  exit 1
fi

RING_COUNT=$(yq eval ".spec.topology.environments.${ENVIRONMENT}.rings | length" "$MANIFEST_FILE")
if [[ "$RING_COUNT" == "null" || "$RING_COUNT" -eq 0 ]]; then
  echo "expand-domain-manifest.sh: no rings found for environment '${ENVIRONMENT}' in ${MANIFEST_FILE}" >&2
  exit 1
fi

# sort_by(.ring) mirrors the schema's own rule: "deploy order is by the ordinal
# (ascending), not list position" - don't trust declaration order in the YAML.
yq eval ".spec.topology.environments.${ENVIRONMENT}.rings | sort_by(.ring)[] as \$r | \$r.cells[] | [\$r.ring, .name, .region] | @tsv" "$MANIFEST_FILE"
