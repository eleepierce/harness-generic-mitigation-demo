#!/bin/bash
# Quick local verification test - validates cosign works against a signed image
# This doesn't test the Harness pipeline, just the cosign commands

set -euo pipefail

IMAGE="${1:-}"
PUBLIC_KEY_FILE="${2:-/tmp/cosign-public-key.pem}"

if [ -z "$IMAGE" ]; then
    echo "Usage: $0 <image> [public-key-file]"
    echo ""
    echo "Example:"
    echo "  $0 registry.twilio.com/generic-mitigation-scripts/admin-verifier:latest"
    echo ""
    echo "This script simulates what the Harness verification steps do:"
    echo "  1. Verify image signature"
    echo "  2. Verify and extract branch attestation"
    exit 1
fi

if [ ! -f "$PUBLIC_KEY_FILE" ]; then
    echo "Error: Public key file not found: $PUBLIC_KEY_FILE"
    echo ""
    echo "Extract it first:"
    echo "  ./scripts/extract-kms-public-key.sh > $PUBLIC_KEY_FILE"
    exit 1
fi

if ! command -v cosign &> /dev/null; then
    echo "Error: cosign not installed"
    echo "Install from: https://github.com/sigstore/cosign/releases"
    exit 1
fi

if ! command -v jq &> /dev/null; then
    echo "Error: jq not installed"
    echo "Install: brew install jq (macOS) or apt-get install jq (Linux)"
    exit 1
fi

echo "=================================================="
echo "Testing Cosign Verification Locally"
echo "=================================================="
echo "Image: $IMAGE"
echo "Public Key: $PUBLIC_KEY_FILE"
echo ""

# Step 1: Verify signature
echo "[1/2] Verifying image signature..."
if cosign verify --insecure-ignore-tlog --key "$PUBLIC_KEY_FILE" "$IMAGE"; then
    echo "✅ Signature verification: PASS"
else
    echo "❌ Signature verification: FAIL"
    echo "This image is either unsigned or signed by a different key"
    exit 1
fi

echo ""

# Step 2: Verify attestation and extract branch
echo "[2/2] Verifying branch attestation..."
if ! ATTESTATION_OUTPUT=$(cosign verify-attestation --insecure-ignore-tlog --type custom --key "$PUBLIC_KEY_FILE" "$IMAGE" 2>&1); then
    echo "❌ Attestation verification: FAIL"
    echo "$ATTESTATION_OUTPUT"
    exit 1
fi

# Extract branch
BRANCH=$(echo "$ATTESTATION_OUTPUT" | jq -r '.payload' | base64 -d | jq -r '.predicate.Data.branch')

echo "✅ Attestation verification: PASS"
echo "   Branch: $BRANCH"

echo ""
echo "=================================================="
echo "Local Verification Summary"
echo "=================================================="
echo "Image:      $IMAGE"
echo "Signature:  ✅ Valid"
echo "Attestation: ✅ Valid"
echo "Branch:     $BRANCH"
echo ""

if [ "$BRANCH" = "main" ]; then
    echo "✅ This image would PASS in production (main branch)"
else
    echo "⚠️  This image would FAIL in production (non-main branch: $BRANCH)"
    echo "   It can only run in dev environment"
fi

echo ""
echo "Next step: Test in Harness pipeline"
echo "See docs/testing-verification.md for Harness testing guide"
