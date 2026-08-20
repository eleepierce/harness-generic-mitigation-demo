# Harness Generic Mitigation Demo

POC for PLATSRE-1537 - Harness as a mitigation invocation front door. 

**Full write-up:** [Harness Generic Mitigation for CND POC](https://docs.google.com/document/d/1rZVuQRlsCdRgplfoHaljRKBsqKHatkQCDSffJmJSWNE/edit)

## Layout

## Prod gate

`run-generic-mitigation` v2.1.0 adds a `Prod Ticket Gate` step that runs on the delegate
before the mitigation step group. It takes two new stage variables:

- `environment` (required, `dev`/`stage`/`prod`) — sourced from the domain manifest by the
  fan-out orchestrator.
- `ticket_id` (optional) — a linked incident/Jira key, e.g. `PROJECT-123`.

For `environment=prod` a `ticket_id` matching the Jira issue-key pattern (`PROJECT-123`) is
required, or the run fails before the mitigation container executes. If the delegate has
`JIRA_BASE_URL` + `JIRA_TOKEN` set, the ticket is additionally verified to exist via the Jira
API (definitive 404/401/403 blocks; transport errors fall back to pattern-only). `dev`/`stage`
runs need no ticket — matching SSM's dev-vs-prod distinction.

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
