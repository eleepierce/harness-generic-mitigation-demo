# Harness Generic Mitigation Demo

POC for PLATSRE-1537 - Harness as a mitigation invocation front door. 

**Full write-up:** [Harness Generic Mitigation for CND POC](https://docs.google.com/document/d/1rZVuQRlsCdRgplfoHaljRKBsqKHatkQCDSffJmJSWNE/edit)

## Layout

- `container/` — base mitigation container: shared `mitigation-entrypoint.sh` wrapper (decodes `MITIGATION_ENV_JSON` into real env vars) + Dockerfile
- `container-redis-check/` — Redis reachability + real SET/GET round-trip check
- `container-es-check/` — Elasticsearch reachability check
- `container-zk-check/` — Zookeeper reachability check
- `container-pod-access/` — pod-level access test (kubectl exec into a separate pod, retrieve a file — answers "can this reach inside a pod, not just a DB/host")
- `harness/` — templates, pipelines, connector YAML
- `infra/` — Terraform (Aurora test target, ECR auth refresher, Springer VPC endpoint)
- `scripts/` — helper scripts (KMS public-key extraction, local verification)
- `springer-daemonset-test/` — Springer log-delivery test

## Image Verification

Template v2.0.0 includes Cosign signature verification using AWS KMS. All mitigation images are cryptographically verified before execution.

- **Signing**: handled by the `generic-mitigation-scripts` build pipeline
- **Verification**: two steps — cosign signature check, then branch attestation (enforces `main` outside `dev`)
- **Trust anchor**: KMS key `arn:aws:kms:us-east-1:947708912703:key/b3b51003-...`

See the verify steps in [`harness/run-generic-mitigation-template.yaml`](harness/run-generic-mitigation-template.yaml). Extract the pinned public key with [`scripts/extract-kms-public-key.sh`](scripts/extract-kms-public-key.sh) and test verification locally with [`scripts/verify-image-locally.sh`](scripts/verify-image-locally.sh).
