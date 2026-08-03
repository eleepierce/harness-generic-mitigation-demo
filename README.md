# Harness Generic Mitigation Demo

POC for PLATSRE-1537 — Harness as a mitigation invocation front door. Real, working, verified end to end, not a design sketch.

**Full write-up:** [Harness Front Door — POC Validation Findings](https://docs.google.com/document/d/1rZVuQRlsCdRgplfoHaljRKBsqKHatkQCDSffJmJSWNE/edit)
**Commands to reproduce:** [RUNBOOK.md](RUNBOOK.md)

## Proven

- Harness delegate reaches a private-VPC database — real SQL, not just TCP
- Real Springer/ClickHouse log delivery from short-lived (3-5s) pods
- Genuinely parameterized template — image, target, connectors, DB creds all runtime inputs
- Durable registry auth, zero manually-rotated credentials

## 4 real Harness bugs hit (details + workarounds in the doc above)

1. `--follow` mislabels running steps as failed (cosmetic)
2. `Aws` connector validates image before resolving variables — use `DockerRegistry` instead
3. `harness create secret -f` drops custom fields on `Reference` secrets
4. `Secret`-type stage variables don't resolve in custom-image `envVariables` — pass the secret's name as a string, resolve with `secrets.getValue()` in the template

## Layout

- `container/` — mitigation script + Dockerfile
- `harness/` — template, pipeline, connector YAML
- `infra/` — Terraform (Aurora test target, ECR auth refresher, Springer VPC endpoint)
- `springer-daemonset-test/` — Springer log-delivery test
