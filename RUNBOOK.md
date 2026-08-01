# Full End-to-End Runbook

Every command needed to reproduce this POC from an authenticated shell, in order. This
is the literal script — for the narrative pitch (what to say while running it), see
`README.md`'s "Demo script" section. Every command below has actually been run for real
at least once; nothing here is a guess.

**Assumes already provisioned** (one-time setup from earlier sessions, not redone here):
EKS cluster `harness-poc` (via `eksctl`), the Harness delegate `harness-poc-delegate`
(Helm-installed onto that cluster), and the base Harness connectors (`harnesspoceks`,
`harnesspocdockerecr`, `harnesspocawssecretsmanager`). Recreating those from zero isn't
covered here — this runbook picks up from "environment exists" through "demo complete."

**Working directory for everything below:** `~/IdeaProjects/harness-generic-mitigation-demo`

---

## 0. Prerequisites

- `twilio-sso`, `aws` CLI, `docker`, `kubectl`, `terraform` (>=1.3), `harness` CLI — all installed
- `harness` CLI already authenticated (`harness auth status` should resolve account/org/project)
- Org `cloudnativeplatform` / project `reliability_engineering` for all `harness` commands below

---

## 1. Authenticate to AWS

Every AWS-touching step below needs this in the same shell session (credentials expire
in ~1hr, so re-run if a later step gets an auth error):

```bash
eval "$(twilio-sso cnd-eleepierce-sandbox admin 2>/dev/null | grep '^export')"
aws eks update-kubeconfig --name harness-poc --region us-east-1
```

---

## 2. Apply the Terraform infrastructure

One directory, three independent pieces (Aurora test target, ECR token refresher,
Springer VPC endpoint) — all in local state, not Terraform Cloud or Harness IACM:

```bash
cd ~/IdeaProjects/harness-generic-mitigation-demo/infra
terraform init
terraform plan    # sanity-check: should show 0 to add/change/destroy if already applied
terraform apply -auto-approve
```

Grab two outputs you'll need later:

```bash
terraform output -raw cluster_endpoint       # Aurora endpoint, e.g. harness-poc-connectivity-test.cluster-....rds.amazonaws.com
terraform output -raw master_user_secret_arn # Secrets Manager ARN for the DB master password
```

---

## 3. Build and push the mitigation container

```bash
cd ~/IdeaProjects/harness-generic-mitigation-demo
aws ecr get-login-password --region us-east-1 | docker login --username AWS --password-stdin 547641909728.dkr.ecr.us-east-1.amazonaws.com
docker build --platform linux/amd64 -t 547641909728.dkr.ecr.us-east-1.amazonaws.com/harness-poc/connectivity-check:v1.0.4 container/
docker push 547641909728.dkr.ecr.us-east-1.amazonaws.com/harness-poc/connectivity-check:v1.0.4
```

(`v1.0.4` is current/stable. `v1.0.1`–`v1.0.3` are debug iterations left in ECR, not used.)

---

## 4. Create the Harness secret for the DB password

Pulls the real password from the RDS-managed secret (never hardcode it):

```bash
cd ~/IdeaProjects/harness-generic-mitigation-demo/infra
SECRET_ARN=$(terraform output -raw master_user_secret_arn)
DB_PASS=$(aws secretsmanager get-secret-value --secret-id "$SECRET_ARN" --region us-east-1 --query SecretString --output text | python3 -c "import json,sys; print(json.load(sys.stdin)['password'])")

cd ~/IdeaProjects/harness-generic-mitigation-demo
harness create secret harnessPocDbPasswordV2 --org cloudnativeplatform --project reliability_engineering --set value="$DB_PASS"
```

**Important — a single `--set value=...` flag, by itself.** Combining `--set name=...`
and `--set value=...` in one `create secret` call previously corrupted the stored value
(see README architecture note on the 4th Harness bug). If this secret already exists from
a prior run, use `harness update secret harnessPocDbPasswordV2 --set value="$DB_PASS"`
instead of `create`.

Unset the password from your shell once done, out of caution:

```bash
unset DB_PASS
```

---

## 5. Apply the Harness template and pipeline

```bash
cd ~/IdeaProjects/harness-generic-mitigation-demo
harness create template rungenericmitigation --org cloudnativeplatform --project reliability_engineering -f harness/run-generic-mitigation-template.yaml
harness update template_version:set-stable rungenericmitigation/1.0.8 --org cloudnativeplatform --project reliability_engineering
harness update pipeline rungenericmitigationdemo --org cloudnativeplatform --project reliability_engineering -f harness/run-generic-mitigation-demo-pipeline.yaml
```

(`harness create template` errors if `versionLabel` in the YAML already exists as a
version — bump it first if you've edited the template and want a new version.)

---

## 6. Run the demo

```bash
cd ~/IdeaProjects/harness-generic-mitigation-demo
harness execute pipeline rungenericmitigationdemo \
  --org cloudnativeplatform --project reliability_engineering \
  --input image=547641909728.dkr.ecr.us-east-1.amazonaws.com/harness-poc/connectivity-check:v1.0.4 \
  --input target_host=harness-poc-connectivity-test.cluster-cc7gy6moir8k.us-east-1.rds.amazonaws.com \
  --input target_port=3306 \
  --input docker_connector=harnesspocdockerecr \
  --input k8s_connector=harnesspoceks \
  --input db_user=admin \
  --input db_password_secret=harnessPocDbPasswordV2 \
  --follow
```

**Note the ExecutionId it prints**, then confirm the *real* status (`--follow`'s
scrolling text has a known cosmetic bug — see README — it can show `<<< failed` on a
run that actually succeeds):

```bash
harness get execution rungenericmitigationdemo/<execution-id> --org cloudnativeplatform --project reliability_engineering
harness get execution_log rungenericmitigationdemo/<execution-id>   # full container output, incl. the SQL results
```

Expected: `Status: Success`, and the log shows `REACHABLE:...` followed by `mysql_version`,
`SHOW DATABASES` output, an inserted/selected test row, and `SQL_OK: successfully executed
real SQL...`.

---

## 7. Optional — prove it's genuinely parameterized (failure path)

```bash
harness execute pipeline rungenericmitigationdemo \
  --org cloudnativeplatform --project reliability_engineering \
  --input image=547641909728.dkr.ecr.us-east-1.amazonaws.com/harness-poc/connectivity-check:v1.0.4 \
  --input target_host=example.com \
  --input target_port=9999 \
  --input docker_connector=harnesspocdockerecr \
  --input k8s_connector=harnesspoceks \
  --input db_user=admin \
  --input db_password_secret=harnessPocDbPasswordV2 \
  --follow
```

Expected: `Status: Failed`, log shows `UNREACHABLE: could not open TCP connection to
example.com:9999`. (SQL is never attempted — the TCP check fails and exits first — so
the `db_user`/`db_password_secret` values here are irrelevant placeholders, just needed
to satisfy the template's required inputs.)

---

## 8. Optional — verify Springer log delivery for real

Confirms the mitigation pod's logs actually land in ClickHouse, not just get printed to
`kubectl logs`. Requires the hand-installed OTel Collector DaemonSet from
`springer-daemonset-test/` to already be running:

```bash
kubectl get pods -n otel-collector-test   # both agent pods should be Running 1/1
```

Then, in Grafana Explore (or via the Grafana MCP `query_clickhouse` tool), against
datasource `twilio-clickhouse-otel-logs-dev-us-east-1`:

```sql
SELECT Timestamp, Body, ResourceAttributes['k8s.pod.name'] AS pod_name FROM otel_logs
WHERE $__timeFilter(Timestamp) AND $__timeFilter(TimestampTime)
  AND Body LIKE '%REACHABLE: successfully opened TCP connection to harness-poc-connectivity-test%'
ORDER BY Timestamp DESC
```

(Both `Timestamp` and `TimestampTime` need bounding or the query gets rejected — see
README.) Expect one row per demo run, each with a `pod_name` starting `harnesscd-mitigation-`.

---

## 9. Cleanup, if tearing the whole POC down

```bash
cd ~/IdeaProjects/harness-generic-mitigation-demo/infra
terraform destroy    # removes Aurora cluster, ECR refresher, Springer VPC endpoint

helm uninstall otelcol -n otel-collector-test
kubectl delete namespace otel-collector-test
```

Harness objects (template, pipeline, secret, connectors, delegate) aren't Terraform-managed
— delete manually in the Harness UI/CLI if the whole POC is being retired, not just the AWS side.
