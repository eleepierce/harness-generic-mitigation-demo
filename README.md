# Harness Generic Mitigation Demo

POC for Harness as a mitigation invocation front door. 

**Full write-up:** [Harness Generic Mitigation for CND POC](https://docs.google.com/document/d/1rZVuQRlsCdRgplfoHaljRKBsqKHatkQCDSffJmJSWNE/edit)

## Ticket format check

`run-generic-mitigation` v2.1.0 adds a `Ticket Format Check` step that runs on the delegate
before the mitigation step group. It takes two new stage variables:

- `environment` (required, `dev`/`stage`/`prod`) — sourced from the domain manifest by the
  fan-out orchestrator. Unrelated to `ticket_id` below.
- `ticket_id` (optional, every environment) — a linked incident ID, e.g. `PROJECT-123`
  (Jira), `inc-12345` (FireHydrant), or `pd-1234567` (PagerDuty).

`ticket_id` is never required, in any environment — matching the real `generic_mitigation_ssm`
tool, where it's audit metadata rather than a gate. If a value is provided, it must match one
of those three ID schemes or the run fails before the mitigation container executes; no live
existence check against Jira/FireHydrant/PagerDuty is performed, again matching SSM (format
validation only).

## Layout

- `container/` — base mitigation container: shared `mitigation-entrypoint.sh` wrapper (decodes `MITIGATION_ENV_JSON` into real env vars) + Dockerfile
- `container-redis-check/` — Redis reachability + real SET/GET round-trip check
- `container-es-check/` — Elasticsearch reachability check
- `container-zk-check/` — Zookeeper reachability check
- `container-pod-access/` — pod-level access test (kubectl exec into a separate pod, retrieve a file — answers "can this reach inside a pod, not just a DB/host")
- `harness/` — templates, pipelines, connector YAML
- `infra/` — Terraform (Aurora test target, ECR auth refresher, Springer VPC endpoint)
- `springer-daemonset-test/` — Springer log-delivery test

## Image Verification

Template v2.1.0 includes Cosign signature verification using AWS KMS. All mitigation images are cryptographically verified before execution.

- **Signing**: handled by the `generic-mitigation-scripts` build pipeline
- **Verification**: two steps — cosign signature check, then branch attestation (enforces `main` outside `dev`)
- **Trust anchor**: KMS key `arn:aws:kms:us-east-1:947708912703:key/b3b51003-...`

See the verify steps in [`harness/run-generic-mitigation-template.yaml`](harness/run-generic-mitigation-template.yaml).
