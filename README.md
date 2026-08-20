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

## Invocation tracking

`mitigation-entrypoint.sh` emits one structured JSON line before the real check script runs:

```json
{"service.name":"generic-mitigation-redis-check","mitigation.invoked":true,"mitigation.script":"redis-check","mitigation.ticket":"PROJECT-123","mitigation.environment":"prod"}
```

This exists so "when was a generic mitigation invoked, on any platform" is answerable from a
single field. For logs ingested through the **CloudWatch pipeline** — the paved CND path (ECS
`awslogs` driver → CloudWatch → Firehose → telemetry gateway) — the gateway's
`transform/promote_service_name` processor lifts `service.name` out of a structured JSON body
into the resource attributes, overriding what the log group name would otherwise imply
(precedence: JSON body > log-group regex > `unknown_service`). That lands it in ClickHouse's
**indexed** `ServiceName` column:

```sql
WHERE ServiceName = 'ssm' OR ServiceName LIKE 'generic-mitigation%'
```

`ssm` is there because ABBA's own `filelog/ssm` receiver hardcodes `service.name=ssm` — so both
platforms are reachable from the same field instead of two bespoke ones.

Caveats, deliberately not papered over:

- The `service.name` promotion is **CloudWatch-ingestion-only**. On OTK container tailing and
  AL23 filelog, `service.name` must come from an annotation, env var or pod label instead; the
  line is still emitted and still greppable in the log body, just not promoted.
- CND **EKS** cells have no automatic stdout capture at all (verified on a live cell: no
  collection DaemonSet, and no filelog/fluent-bit app in `k8s-platform-services-deploy`'s
  `config/apps/`). The ECS path gets this for free; an EKS path needs fluent-bit/Container
  Insights into CloudWatch, or the `alloy` DaemonSet chart, neither of which is deployed today.
- Firehose buffers, so logs land in ~5–10 min — fine for tracking, not for real-time alerting.
- Emission is non-fatal (`|| true`): an observability nicety must never stop a mitigation.

## Layout

- `container/` — base mitigation container: shared `mitigation-entrypoint.sh` wrapper (decodes `MITIGATION_ENV_JSON` into real env vars, emits the invocation marker) + Dockerfile
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
