#!/bin/bash
# Extract public key from AWS KMS for cosign verification
# This needs to be run once with AWS credentials that have access to the KMS key

set -euo pipefail

KMS_KEY_ARN="arn:aws:kms:us-east-1:947708912703:key/b3b51003-1cac-4a49-b4d9-e6fdcfb268f3"

# Print to stderr so it doesn't interfere with stdout redirect
echo "============================================================" >&2
echo "KMS Public Key Extraction - PLATSRE-1652" >&2
echo "============================================================" >&2
echo "KMS Key ARN: ${KMS_KEY_ARN}" >&2
echo "" >&2

# Step 1: Check for cosign
echo "[1/4] Checking for cosign binary..." >&2
if ! command -v cosign &> /dev/null; then
    echo "✗ Error: cosign is not installed" >&2
    echo "" >&2
    echo "Install options:" >&2
    echo "  macOS:   brew install cosign" >&2
    echo "  Linux:   https://github.com/sigstore/cosign/releases" >&2
    echo "  Manual:  https://docs.sigstore.dev/cosign/installation/" >&2
    exit 1
fi
echo "✓ cosign found: $(command -v cosign)" >&2
echo "  Version: $(cosign version 2>&1 | head -1 || echo 'unknown')" >&2
echo "" >&2

# Step 2: Check AWS credentials
echo "[2/4] Checking AWS credentials..." >&2
if ! aws sts get-caller-identity &> /dev/null; then
    echo "✗ Error: No AWS credentials configured or credentials expired" >&2
    echo "" >&2
    echo "Current AWS config:" >&2
    aws configure list 2>&1 | head -5 >&2 || true
    echo "" >&2
    echo "Troubleshooting:" >&2
    echo "  1. Check AWS_PROFILE environment variable: echo \$AWS_PROFILE" >&2
    echo "  2. Run: aws sts get-caller-identity" >&2
    echo "  3. Ensure you have credentials for account 947708912703" >&2
    echo "  4. Or use: aws sso login --profile <profile-name>" >&2
    exit 1
fi

CALLER_IDENTITY=$(aws sts get-caller-identity 2>&1)
ACCOUNT=$(echo "$CALLER_IDENTITY" | grep -o '"Account": "[^"]*"' | cut -d'"' -f4)
USER_ARN=$(echo "$CALLER_IDENTITY" | grep -o '"Arn": "[^"]*"' | cut -d'"' -f4)

echo "✓ AWS credentials found" >&2
echo "  Account: ${ACCOUNT}" >&2
echo "  Identity: ${USER_ARN}" >&2
echo "" >&2

# Step 3: Check if we have access to the KMS key
echo "[3/4] Checking KMS key access..." >&2
echo "  Target Account: 947708912703" >&2
echo "  Your Account:   ${ACCOUNT}" >&2
echo "" >&2

if [ "$ACCOUNT" != "947708912703" ]; then
    echo "⚠ Warning: You are in account ${ACCOUNT}, not the KMS key's account (947708912703)" >&2
    echo "  This may require cross-account access permissions" >&2
    echo "" >&2
fi

echo "  Testing KMS access (this may take a few seconds)..." >&2

# Test KMS access with better error handling
if ! KMS_TEST=$(aws kms get-public-key --key-id "${KMS_KEY_ARN}" --region us-east-1 2>&1); then
    echo "✗ Error: Cannot access KMS key" >&2
    echo "" >&2
    echo "KMS Error Details:" >&2
    echo "$KMS_TEST" | grep -i "error" >&2 || echo "$KMS_TEST" >&2
    echo "" >&2
    echo "Common causes:" >&2
    echo "  1. No kms:GetPublicKey permission on this key" >&2
    echo "  2. Key is in different account (947708912703)" >&2
    echo "  3. Cross-account access not configured" >&2
    echo "" >&2
    echo "Solutions:" >&2
    echo "  • Ask Platform SRE team for the public key directly" >&2
    echo "  • Request cross-account access to account 947708912703" >&2
    echo "  • Extract from verifier image (see docs/get-public-key.md)" >&2
    exit 1
fi

echo "✓ KMS key access confirmed" >&2
echo "" >&2

# Step 4: Extract public key using cosign
echo "[4/4] Extracting public key with cosign..." >&2

if ! PUBLIC_KEY=$(cosign public-key --key "awskms:///${KMS_KEY_ARN}" 2>&1); then
    echo "✗ Error: cosign failed to extract public key" >&2
    echo "" >&2
    echo "Cosign Error:" >&2
    echo "$PUBLIC_KEY" >&2
    exit 1
fi

# Validate the key format
if ! echo "$PUBLIC_KEY" | grep -q "BEGIN PUBLIC KEY"; then
    echo "✗ Error: Output doesn't look like a PEM-encoded public key" >&2
    echo "" >&2
    echo "Unexpected output:" >&2
    echo "$PUBLIC_KEY" >&2
    exit 1
fi

# Output the key to stdout (this goes to the file if redirected)
echo "$PUBLIC_KEY"

# Success message to stderr
echo "" >&2
echo "============================================================" >&2
echo "✓ Public key extracted successfully!" >&2
echo "============================================================" >&2
echo "" >&2
echo "Next steps:" >&2
echo "  1. View the key: cat /tmp/cosign-public-key.pem" >&2
echo "  2. Copy to clipboard: cat /tmp/cosign-public-key.pem | pbcopy" >&2
echo "  3. Paste into Harness template variable 'cosign_public_key'" >&2
echo "" >&2
echo "The key should start with: -----BEGIN PUBLIC KEY-----" >&2
echo "See docs/test-execution-checklist.md for next steps" >&2
