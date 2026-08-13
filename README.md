# Harness Generic Mitigation Demo

POC for PLATSRE-1537 - Harness as a mitigation invocation front door. 

**Full write-up:** [Harness Generic Mitigation for CND POC](https://docs.google.com/document/d/1rZVuQRlsCdRgplfoHaljRKBsqKHatkQCDSffJmJSWNE/edit)

## Layout

- `container/` — mitigation script + Dockerfile
- `container-pod-access/` — pod-level access test (kubectl exec into a separate pod, retrieve a file — answers "can this reach inside a pod, not just a DB/host")
- `docs/` — documentation (cosign verification setup, plans)
- `harness/` — template, pipeline, connector YAML
- `infra/` — Terraform (Aurora test target, ECR auth refresher, Springer VPC endpoint)
- `scripts/` — helper scripts (KMS public key extraction)
- `springer-daemonset-test/` — Springer log-delivery test

## Image Verification

Template v1.1.0+ includes Cosign signature verification using AWS KMS. All mitigation images must be signed before execution.

- **Signing**: Handled by `generic-mitigation-scripts` build pipeline
- **Verification**: Two-step process (signature + branch attestation)
- **Trust anchor**: KMS key `arn:aws:kms:us-east-1:947708912703:key/b3b51003-...`

See [`docs/cosign-verification.md`](docs/cosign-verification.md) for setup instructions and details.
