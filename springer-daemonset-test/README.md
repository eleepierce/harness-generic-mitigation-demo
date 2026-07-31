# Springer DaemonSet log-capture test

Tests the one piece of this whole effort that had only ever been asserted as a risk,
never verified: **does a DaemonSet-based OTel Collector reliably capture stdout from a
short-lived, run-to-completion Kubernetes pod** (a Harness CD mitigation container that
lives for ~3-5 seconds), or does it miss logs to a startup/shutdown timing race the way
the real, open `PLATOBS-8147` bug ("Missing logs in Springer at pod startup") suggests
is a real failure class?

This splits into two genuinely separate questions, tested independently:

## 1. Can this cluster reach Springer's real OTEL gateway? — Was blocked, now resolved

Per `observability:springer-onboarding`, a standalone EKS cluster in an isolated CND
sandbox account (this one) needs a VPC Interface Endpoint against Springer's PrivateLink
service. Attempted it for real (`infra/springer-otel-vpc-endpoint.tf`, dev env,
`com.amazonaws.vpce.us-east-1.vpce-svc-069b9766e20a56035`):

```
Error: creating EC2 VPC Endpoint: InvalidServiceName: The Vpc Endpoint Service
'com.amazonaws.vpce.us-east-1.vpce-svc-069b9766e20a56035' does not exist
```

Confirmed this isn't a typo or wrong region — `aws ec2 describe-vpc-endpoint-services`
for that exact service name fails the same way. The service is invisible to this
account, which is standard AWS PrivateLink behavior for a service with an
`AllowedPrincipals` list that doesn't include us yet — exactly what the onboarding doc
warned: *"contact #help-observability to request."* Same friction shape as the IAC-445
delegate-permission saga: self-service works right up to a gate another team controls.
The security group (`sg-01e482bdf16f52985`) and endpoint resource are left in
`infra/springer-otel-vpc-endpoint.tf` ready to go — once access is granted, `terraform
apply` in `infra/` should complete the connection with no further changes.

**Not resolved by this test at the time. Needs a `#help-observability` request before this
account can ship anything to real Springer.**

**Update 2026-07-31 (later same day): resolved.** Filed the request as `telemetry-gateway-iac`
PR #337 (adds `547641909728`/`cnd-eleepierce-sandbox` to `allowed_account_ids` in
`platform/dev/us-east-1/config.tf`), reviewed and merged same-day in `#help-observability`,
applied and confirmed by the reviewer directly ("all applied successfully"). `terraform apply`
in `infra/` then completed the VPC Interface Endpoint with no further changes needed
(`vpce-0f015c495a2dea9b9`, `state=available`). Real TCP connect confirmed from inside this
cluster: `otelgw-gp0.us-east-1.dev.platform.twilioinfra.com (192.168.89.25:443) open`. See
§3 below for the full end-to-end proof — logs actually landing in ClickHouse, not just a
network-level connection.

## 2. Does DaemonSet filelog capture actually work for ephemeral pods? — Yes, verified 4/4

Decoupled the mechanism from the blocked connectivity by hand-installing the standard
`open-telemetry/opentelemetry-collector` Helm chart in `daemonset` mode with the
`logsCollection` preset (the same `filelog`-receiver-tailing-`/var/log/pods` pattern IPD
describes for the real OTK path), exporting to `debug` (verbosity `detailed`) instead of
a real OTLP backend — so the result reads directly off `kubectl logs`, no external
dependency needed to answer this specific question. Config: `otel-collector-values.yaml`.

```bash
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
helm install otelcol open-telemetry/opentelemetry-collector \
  --namespace otel-collector-test --values otel-collector-values.yaml --wait
```

**Method:** ran the real demo pipeline (`rungenericmitigationdemo`) four times — a real
Harness CD pod, `harnesscd-mitigation-*`, scheduled fresh, running `check.sh` for
3-5 seconds, then torn down — and checked the collector pods' own output for the
mitigation container's actual stdout lines.

**Result: 4/4 captured, not sampled or best-effort.** Full log excerpt from run
`Q_QTJed6TBqYQEOmYE7vmw` (pod `harnesscd-mitigation-rnqdxwt2`), including the container's
very first stdout line:

```
Timestamp: 2026-07-31 15:04:50.727615223 +0000 UTC
Body: Str(... "out":"Testing TCP reachability to harness-poc-connectivity-test...:3306...\n" ...)
Attributes: log.iostream: Str(stdout)  log.file.path: Str(/var/log/pods/default_harnesscd-mitigation-rnqdxwt2_.../step-runmitigationcontainer/0.log)

Timestamp: 2026-07-31 15:04:50.737337707 +0000 UTC
Body: Str(... "out":"REACHABLE: successfully opened TCP connection to ...:3306\n" ...)
```

Both lines observed/exported by the collector within **~50-60ms** of being written —
well before the step finished (~1s later) or the pod was torn down. Resource attributes
(`k8s.pod.name`, `k8s.namespace.name`, `k8s.container.name`, `k8s.pod.uid`) were attached
automatically by the filelog receiver's k8s metadata parsing, with zero extra config —
exactly the join keys ClickHouse queries would need. Three more back-to-back runs
(`9xX7D54cRfGi0A452zMtGQ`, `lIpMTOg5RB6JDKBlIlRTjA`, `l_tXtUgERtKkbHr-tLtuug`) each
produced the same capture, confirmed by count (`grep -c "REACHABLE: successfully"` across
both collector pods = 4, matching 4 pipeline runs exactly — zero drops).

**What this does and doesn't prove:** the specific fear — that a pod living only a few
seconds might come and go faster than a node-level tailer notices the log file — did not
reproduce, at this pod lifetime (3-5s), on this chart's default poll/batch settings, in
4/4 tries. It does not prove the *real* OTK-managed DaemonSet (twilhelm-provisioned,
different config, possibly different node density/load) behaves identically, and it
doesn't test sub-second-lived pods or a busier/more contended node. But the core
mechanism — filelog tailing a K8s node's pod logs, for a run-to-completion pod — works,
with margin (50ms vs. a multi-second pod lifetime), not marginally.

**Cleanup:** `helm uninstall otelcol -n otel-collector-test && kubectl delete namespace
otel-collector-test` when no longer needed. Left running for now since it's cheap
(100m/128Mi per node × 2 nodes) and may be worth pointing someone else at directly.

## 3. Does it actually land in Springer/ClickHouse, not just get captured locally? — Yes, verified 4/4

Now that §1 is resolved, re-ran the same test as §2 for real: added an `otlp/springer`
exporter (`endpoint: otelgw-gp0.us-east-1.dev.platform.twilioinfra.com:443`) alongside
`debug` in the same DaemonSet (`otel-collector-values.yaml`). Verified via `helm template`
first that both exporters were actually wired into the `logs` pipeline before applying —
the chart does **not** auto-attach a newly-added exporter to existing pipelines; it has to
be listed explicitly under `service.pipelines.logs.exporters`, or it's defined but unused.

```bash
helm upgrade otelcol open-telemetry/opentelemetry-collector \
  --namespace otel-collector-test --values otel-collector-values.yaml --wait
```

**Method:** ran `rungenericmitigationdemo` four more times (same pipeline, same inputs as
§2) — executions `JJbrMAADQiWUisfT9OchJQ`, `S2sOZ7LjTyiCdih5SW9PrA`, `dnIJTKBAROy1BViVQw0gpg`,
`0FaM0klOQRWCnZXit7LEww`, each confirmed `Status: Success` via `harness get execution`
(not just the CLI's `--follow` log streamer, which has the known cosmetic "failed"-on-
still-running bug noted below). Then queried ClickHouse directly — Grafana MCP, datasource
`twilio-clickhouse-otel-logs-dev-us-east-1` (uid `effjhhw4uby80b`) — for the same log line,
independent of anything the collector or `kubectl logs` reported locally.

**Result: 4/4 landed in real ClickHouse**, not sampled, not just locally captured:

```sql
SELECT Timestamp, Body, ResourceAttributes['k8s.pod.name'] AS pod_name FROM otel_logs
WHERE $__timeFilter(Timestamp) AND $__timeFilter(TimestampTime)
  AND Body LIKE '%REACHABLE: successfully opened TCP connection to harness-poc-connectivity-test%'
ORDER BY Timestamp ASC
```

| Timestamp | pod_name |
|---|---|
| 2026-07-31T17:29:18.189893177Z | harnesscd-mitigation-kz2h79wn |
| 2026-07-31T17:30:02.866212244Z | harnesscd-mitigation-kpc8lmyc |
| 2026-07-31T17:30:47.101979829Z | harnesscd-mitigation-yly4sh5m |
| 2026-07-31T17:31:36.50800769Z | harnesscd-mitigation-762k2tg5 |

Exactly 4 rows, exactly matching the 4 execution timestamps, `k8s.pod.name` auto-populated
per row — proof of end-to-end delivery queried independently of the collector's own local
output, not just a stronger assertion of it. Querying gotcha worth keeping: a plain
`WHERE $__timeFilter(Timestamp)` gets rejected by the Grafana ClickHouse proxy (`otel_logs`
partitions on `toDate(TimestampTime)`, and a `Timestamp`-only filter opens every partition —
tens of thousands of S3 requests regardless of how narrow the range is); both `Timestamp`
and `TimestampTime` need bounding for the query to be accepted.

**What this resolves:** the Springer-routing risk that stood since the original POC
(mechanism verified 07-31 morning, real delivery blocked on access) is now fully closed —
both halves proven empirically, not asserted. **What it doesn't change:** still only tested
on a hand-installed vanilla collector, not the official OTK-managed twilhelm DaemonSet, and
still only at 3-5s pod lifetimes on this account's own single-tenant cluster, not a busier
or shared production node. Those remain the honest boundaries of what's actually been shown.
