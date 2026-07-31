# Harness Generic Mitigation Demo

POC materials for PLATSRE-1537 (Mitigation Invocation Normalization) supporting the
"Harness as front door" proposal. Proves three things end to end: (1) a Harness delegate
can reach a private-VPC database (the risk Robert Acosta flagged in the 07-27 sync),
(2) a containerized "blessed" mitigation script can be invoked with one CLI command,
targeting a resource specified at runtime, with a full audit trail in Harness, and
(3) that container can execute real SQL against the target — not just open a socket to
it — proving the database is genuinely usable from this path, not just reachable.

Everything here is real and was actually run — not a design sketch. Account:
`cnd-eleepierce-sandbox` (547641909728, us-east-1). Harness org
`cloudnativeplatform` / project `reliability_engineering`.

---

## Demo script

**1. The problem.** Segment and CND have no shared front door for mitigations today.
Segment is stuck running `kubectl` directly against prod (they've said they hate this).
CND has ad hoc ECS/Argo patterns. ABBA/SSM works well but is structurally EC2-only —
it cannot cover either of them.

**2. The mitigation script.** Show `container/check.sh` and `container/Dockerfile`.
This follows the exact same authoring conventions as the real `generic-mitigation-scripts`
repo — a Dockerfile, an entrypoint script driven by env vars, nothing SSM-specific about
it. Built and pushed the same way any mitigation image would be (here: ECR for the POC;
same idea as the real Buildkite → Cosign → registry pipeline). It does two things, in
order: checks TCP reachability first (fails fast if the target's unreachable), then — if
DB credentials are supplied — actually runs SQL against it (`SELECT`, `CREATE`/`INSERT`,
cleanup), proving the path is usable for real mitigation work, not just a ping.

**3. Invoke it — one command.** Run the command below live. This is the same shape as
`owl generic-mitigation-ssm <image> --target ... --ticket ...` — one command, target
specified at invoke time.

**4. What just happened.** While it runs (or right after): that one command told a
Harness delegate — running inside a Kubernetes cluster, no direct access granted to
Segment's or CND's infrastructure — to schedule a pod, pull the exact signed image, and
run it against a target supplied at invocation time. No SSH, no direct `kubectl` from a
human.

**5. The result and audit trail.** Show the `Success` status and the log output below.
Mention Harness's own Execution History (linked below) as the orchestration-level audit
trail, the same role AWS's console link + Grafana dashboard link play in the SSM path
today.

**6. Land the point.** This is the same "one command, image + target + ticket, get a
result and a log" experience OWL already gives ABBA — running on a backend that
actually works for Kubernetes-native teams, which SSM structurally cannot.

---

## Commands to run

```bash
# Show the mitigation script (just cat the files, no execution)
cat container/check.sh
cat container/Dockerfile

# (Already built and pushed for this POC — mention rather than re-run live)
# docker build --platform linux/amd64 -t 547641909728.dkr.ecr.us-east-1.amazonaws.com/harness-poc/connectivity-check:v1.0.4 container/
# docker push 547641909728.dkr.ecr.us-east-1.amazonaws.com/harness-poc/connectivity-check:v1.0.4

# THE live demo command — one command, runtime-supplied image, target, connectors, AND
# DB credentials (db_password_secret names a Harness secret; see architecture note below
# on why it's a secret *name*, not a Secret-type variable):
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

# Show the execution record (use the ExecutionId printed above, or omit the id
# and check the Harness UI link it prints)
harness get execution rungenericmitigationdemo/<execution-id> \
  --org cloudnativeplatform --project reliability_engineering
```

**Optional — prove it's genuinely parameterized, not hardcoded:** re-run with an
unreachable target to show the failure path is real too (SQL is never attempted since
the TCP check fails first and exits, so `db_user`/`db_password_secret` still need *some*
valid value to satisfy the template's required inputs, but their content is irrelevant
to this specific failure):

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
# Expect: Status Failed, log shows "UNREACHABLE: could not open TCP connection to example.com:9999"
```

Known-good sample output from a real run (execution `7wsTPpfvQhG3KGQyI8-GVw`, template
v1.0.8, image v1.0.4 — real SQL, not just connectivity):

```
Status:       Success
Stages:       1 total, 1 success, 0 failed

✓ mitigation (20s)
  ✓ Execution
    ✓ mitigation
      ✓ Initialize
      ✓ Run Mitigation Container

Testing TCP reachability to harness-poc-connectivity-test.cluster-cc7gy6moir8k.us-east-1.rds.amazonaws.com:3306...
REACHABLE: successfully opened TCP connection to harness-poc-connectivity-test.cluster-cc7gy6moir8k.us-east-1.rds.amazonaws.com:3306
Running real SQL against harness-poc-connectivity-test.cluster-cc7gy6moir8k.us-east-1.rds.amazonaws.com:3306...
mysql_version
8.0.42
Database
connectivitytest
information_schema
mysql
performance_schema
sys
id	note
1	mitigation script SQL check
SQL_OK: successfully executed real SQL (DDL+DML+query) against harness-poc-connectivity-test.cluster-cc7gy6moir8k.us-east-1.rds.amazonaws.com:3306
```

---

## What was created or adjusted this session

**Harness (org `cloudnativeplatform` / project `reliability_engineering`):**

| Object | Identifier | Notes |
|---|---|---|
| Delegate | `harness-poc-delegate` | Helm-installed, running in EKS cluster `harness-poc` |
| Connector (K8sCluster) | `harnesspoceks` | `InheritFromDelegate` — no separate cluster credentials |
| Connector (DockerRegistry) | `harnesspocdockerecr` | Used for ECR image pull auth in the current (v1.0.4+) template — see architecture note below |
| Connector (AwsSecretManager) | `harnesspocawssecretsmanager` | Reads the auto-refreshed ECR password from AWS Secrets Manager, auth via `AssumeIAMRole` (the delegate's own node IAM role — no stored credential) |
| Secret (Reference) | `ecrTokenFromSecretsManager` | Points `harnesspocdockerecr`'s `passwordRef` at the AWS-managed secret — durable, no manual refresh needed. Created via direct API call, not the CLI (see caveat) |
| Connector (Aws) | `harnesspocaws` | Superseded — was used for image pull in template v1.0.0–1.0.3, replaced because it forced the image to be hardcoded (see note) |
| Secret (SecretText) | `harnessPocDbPasswordV2` | The Aurora master password, for the SQL-execution capability — see architecture note on why it's referenced by name, not passed as a `Secret`-type variable |
| Template (Stage) | `rungenericmitigation` | v1.0.8 marked stable — `harness/run-generic-mitigation-template.yaml`. Adds `docker_connector`/`k8s_connector` as genuine runtime-input variables (v1.0.4 hardcoded both); v1.0.8 adds `db_user`/`db_password_secret` for real SQL execution (see architecture note) |
| Pipeline | `rungenericmitigationdemo` | The container+template demo — `harness/run-generic-mitigation-demo-pipeline.yaml` |
| Pipeline | `harnesspocvpcconnectivitytest` | Earlier, simpler proof (inline shell, no container) that first confirmed private-VPC DB reachability |

**AWS (account `cnd-eleepierce-sandbox`, 547641909728, us-east-1):**

| Resource | Identifier | Notes |
|---|---|---|
| EKS cluster | `harness-poc` | Created via eksctl, `harness-db-devop-poc/infra/eks-cluster.yaml` |
| Aurora MySQL cluster | `harness-poc-connectivity-test` | `infra/aurora-test-target.tf` — hand-written, deliberately NOT using the `terraform-twilio-aws-aurora` module (it requires a live Datadog API key + PagerDuty service with no opt-out) |
| ECR repo + image | `harness-poc/connectivity-check:v1.0.4` | The blessed mitigation container. v1.0.4 adds `mariadb-client` and real SQL execution (see architecture note); v1.0.1–v1.0.3 were debug iterations kept in ECR, not used by the demo |
| Secrets Manager secret | `harness-poc/ecr-docker-password` | Auto-refreshed ECR login password — `infra/ecr-token-refresher.tf` |
| Lambda | `harness-poc-ecr-token-refresher` | Calls `ecr:GetAuthorizationToken` and writes the result to the secret above — `infra/lambda-src/ecr_token_refresher.py` |
| EventBridge rule | `harness-poc-ecr-token-refresh` | Triggers the Lambda every 6h, well inside the token's ~12h expiry |
| IAM role | `harness-poc-ecr-token-refresher` | The Lambda's execution role — also needs real `ecr:BatchGetImage`/`GetDownloadUrlForLayer`/`BatchCheckLayerAvailability` on the repo (see architecture note — ECR tokens are principal-scoped to whoever minted them, not just whoever uses them) |
| IAM inline policy | `harness-poc-ecr-secret-read` on the EKS node role | Scoped `secretsmanager:GetSecretValue`/`DescribeSecret` on both the real secret and Harness's own `*aws_secrets_manager_validation*` self-test pattern |

**This repo:**

- `container/check.sh`, `container/Dockerfile` — the mitigation script itself
- `harness/*.yaml` — template, pipeline, and connector definitions, as actually applied
- `infra/aurora-test-target.tf` — the standalone Aurora Terraform (local state only)
- `infra/ecr-token-refresher.tf`, `infra/lambda-src/` — the durable registry-auth refresher

---

## Architecture note: this is now a genuinely reusable template

Earlier in this repo's history, the mitigation image had to be hardcoded directly into
the template rather than passed as a runtime input, because Harness's `Aws`-type
connector validates the image string against ECR's URL format *before* resolving
`<+variable>` expressions — a templated image field got rejected outright. That meant,
as first built, a second mitigation would have needed its own copy of the template with
a different image baked in, which is NOT the architecture this is supposed to
demonstrate.

**Fixed, verified:** switching the image-pull connector to a plain `DockerRegistry` type
(`harnesspocdockerecr`, pointed at the same ECR registry, auth via a stored token
instead of `InheritFromDelegate`) avoids that early validation entirely. `image` is now
a genuine template variable exactly like `target_host`/`target_port` — confirmed with a
real run (execution `1ePU-unAS5mUyjP3ga4MpQ`, `Status: Success`, pulled the image via
the new connector). This means the actual, current adoption model is: **a team writes
their script/Dockerfile and a thin pipeline; the template is shared and built once** —
not "every mitigation needs its own template," which was true of earlier versions of
this repo but is not the end state.

**Tested and ruled out: a credential-free `DockerRegistry` connector does not work,**
even though the underlying EKS node can already pull the same image via its own IAM
role. `InheritFromDelegate` isn't a valid auth type for `DockerRegistry` (that concept
is specific to cloud-provider connectors with an inherent host identity). `Anonymous`
auth *does* pass connector creation, but fails at actual execution — confirmed via a
real run (`rungenericmitigationanontest`, template v1.0.5, execution
`oI3pEaIZRbWXb4jSOChneQ`): the pod scheduled and kubelet's own pull succeeded (image was
already cached on the node), but Harness's own step-execution runtime (`lite-engine`)
separately calls the registry's manifest API to resolve the container's entrypoint —
and that call uses the declared connector's credentials, not the node's ambient IAM
role. With no real credentials, ECR returns `401 Unauthorized`. So there are two
genuinely separate pull paths (kubelet's, which can ride node IAM; Harness's own, which
cannot), and only crediting the one Harness actually controls makes the step work. A
durable rollout needs the Secrets-Manager-plus-refresher approach — there's no
zero-credential path available here.

(Test artifacts left in place, clearly labeled: connector `harnesspocdockerecranon`,
pipeline `rungenericmitigationanontest` on template v1.0.5 — not stable, not part of
the actual demo, kept only as a record of what was tried.)

## Architecture note: connectors are now genuinely parameterized too

Through v1.0.4, the template's own `connectorRef` fields — `harnesspocdockerecr` on the
`Run` step and `harnesspoceks` on `stepGroupInfra` — were hardcoded identifiers, not
variables, even though `image`/`target_host`/`target_port` were. That meant a second team
couldn't actually instantiate this template against their own cluster/registry without
editing the template itself, contradicting the "shared, built once" claim above.

**Fixed, verified (v1.0.6):** both `connectorRef` fields now read
`<+stage.variables.docker_connector>` / `<+stage.variables.k8s_connector>`, with two new
required template variables to match. This was a real open question, not a formality —
Harness has at least one precedent in this exact repo (the `Aws` connector's early
image-format validation, see below) where a field resolves *before* stage variables are
available, which would have made this a dead end. It doesn't here: confirmed with a real
run on a throwaway test pipeline (execution `w0_NjcBwSKeZYCCeUnL6TA`, template v1.0.6,
`Status: Success`, `REACHABLE`) passing `harnesspocdockerecr`/`harnesspoceks` as inputs
rather than literals, then promoted straight into the real demo pipeline and re-verified
there too (execution `iNyOJSQcRHeDH9eGmwMwmg`, same result). Template v1.0.6 is now
marked stable; the demo pipeline requires `docker_connector`/`k8s_connector` inputs (see
the demo command above).

**What this does and doesn't prove:** a second team's own connectors — their own
`DockerRegistry` and `K8sCluster` connector identifiers — can now be passed into this
same template without touching its YAML. What's still unproven either way: whether *one
shared* delegate/cluster (this account's) can reach into a *different* team's private
VPC, versus each team needing to run its own delegate. Both tests here used this
account's own connectors against this account's own cluster and database — parameterizing
the field is necessary for multi-team reuse but isn't the same claim as proving
cross-account reachability.

## Architecture note: registry auth is now durable, not just working

The static `ecrPocToken` secret from the section above is gone — replaced with a fully
auto-refreshing chain, no manual token rotation anywhere:

1. **`infra/ecr-token-refresher.tf`** provisions a Secrets Manager secret
   (`harness-poc/ecr-docker-password`), a Lambda (`harness-poc-ecr-token-refresher`) that
   calls `ecr:GetAuthorizationToken` and writes the result to that secret, and an
   EventBridge rule firing the Lambda every 6h — safely inside the token's ~12h expiry.
2. **`harnesspocawssecretsmanager`** (an `AwsSecretManager`-type connector) reads that
   secret at execution time, authenticating via `AssumeIAMRole` — the delegate's own
   node IAM role, no stored credential on the Harness side at all.
3. **`ecrTokenFromSecretsManager`** (a `Reference`-type Harness secret, not `Inline`)
   points at that AWS secret by name. `harnesspocdockerecr`'s `passwordRef` now points at
   *this*, not a static value.

Verified end to end with a real run (execution `PfP7pjTIQjSj7XOQVq-uFw`, `Status:
Success`) — the pod pulled the image using the Secrets-Manager-backed password and hit
`REACHABLE`, exactly like every prior successful run, just with nothing to rotate by
hand.

**Three real gotchas hit and fixed while building this, worth knowing if extending it:**

- **ECR authorization tokens are principal-scoped.** Whoever calls
  `GetAuthorizationToken` is who the resulting password authenticates as on the *actual*
  pull — not whoever later uses the password. The Lambda mints the token, so the
  Lambda's own IAM role needs real `ecr:BatchGetImage`/`GetDownloadUrlForLayer`/
  `BatchCheckLayerAvailability` on the repo — granting only `GetAuthorizationToken` looks
  sufficient (the token mints fine) but fails later with a `BatchGetImage` denial that's
  easy to misread as a Harness-side problem.
- **Harness's `AwsSecretManager` connector-level "test" doesn't check your actual
  secret** — it creates a synthetic validation secret with an unpredictable name
  (`harness/aws_secrets_manager_validation<random>` in one attempt, `null/...` in
  another, depending on whether `secretNamePrefix` is set) purely to verify the
  credential mechanism generically. The node/delegate IAM role needs read access to that
  pattern too, not just your real secret — matched here with a
  `*aws_secrets_manager_validation*` wildcard rather than chasing the exact prefix.
- **The `harness` CLI's `create secret -f file.yaml` silently drops custom `spec`
  fields** for this scenario — tried both wrapped (`secret: {...}`) and flat YAML,
  schema confirmed correct against Harness's own Terraform provider source twice, both
  times it created a plain `Inline`/`harnessSecretManager` secret regardless of what the
  file actually said. The fix was going around the CLI entirely: a direct
  `POST /ng/api/v2/secrets` call with the same JSON body worked on the first try. If a
  future secret needs `valueType: Reference`, use the API directly, not `harness create
  secret -f`.

## Architecture note: the container now runs real SQL, not just a connectivity check

`check.sh` does the TCP check first (unchanged), then — if `DB_USER`/`DB_PASSWORD` are
set — connects with the real `mysql` client and runs actual DDL/DML/query (`CREATE
DATABASE`/`TABLE`, `INSERT`, `SELECT`, cleanup), not just a socket open. This proves the
database is genuinely *usable* from this path for real mitigation work, not merely
reachable. `container/Dockerfile` adds `mariadb-client` (Alpine's MySQL-protocol-
compatible client) to support it.

**A fourth real bug in Harness's own product, found getting this working:** a `type:
Secret` stage variable, referenced via `<+stage.variables.x>` inside a Run step's
`envVariables`, does **not** resolve to the real decrypted secret value on a custom-image
step (one with no inline `command`, relying on the container's own `ENTRYPOINT`) — it
silently resolves to some other, unrelated 48-character value instead of erroring.
Confirmed methodically, not guessed:

1. First suspected the secret's stored value itself was corrupted (from an earlier
   `harness create secret --set name=... --set value=...` call, two `--set` flags in one
   invocation with a password containing a literal `|`). Recreated the secret cleanly
   several ways (single `--set`, a fresh identifier, a `--input-file` YAML instead of
   CLI flags) — **the corrupted value was identical every time**, byte-for-byte (same
   length, same first/last characters), *regardless of which secret was referenced*.
   That ruled out the secret's content, the CLI's argument parsing, and any caching —
   none of those should produce an *identical* result across different secret names.
2. Bypassed the `stage.variables` indirection entirely — put
   `<+secrets.getValue("harnessPocDbPasswordV2")>` directly in the template's
   `envVariables` instead of going through a `Secret`-type stage variable. **That worked
   immediately** (correct 28-character password, real SQL executed). This isolated the
   bug specifically to the stage-variable indirection layer for `Secret`-typed variables
   in this step context.

**The fix, keeping the template genuinely parameterized (not hardcoded to one secret):**
pass the secret's *identifier* as a plain `String` variable (`db_password_secret`, e.g.
`harnessPocDbPasswordV2`) instead of a `Secret`-type variable holding the resolved value,
then construct the `getValue()` call directly in the template using that name:
`DB_PASSWORD: <+secrets.getValue(<+stage.variables.db_password_secret>)>`. Verified with a
real run (execution `7wsTPpfvQhG3KGQyI8-GVw`, template v1.0.8, `Status: Success`, full SQL
output). Different teams can still pass their own secret's identifier at runtime — the
parameterization goal survives, just via a name-lookup instead of a typed pass-through.

---

## Caveats worth knowing before presenting

- **`--follow`'s scrolling text can show a `<<< failed ... "running"` or
  `"asyncwaiting"` line on a run that succeeds — this is a confirmed cosmetic bug in
  Harness's own CLI, not a real failure.** Root cause (verified in
  `harness/cli`'s `pkg/logstream/logstream.go`, `WriteEndEvent`): the switch statement
  that labels each node's end-of-stream line has no case for legitimate in-progress
  statuses like `running`/`asyncwaiting`, so they fall into the `default` branch meant
  for genuine failures, which prints `<<< failed` and — since there's no real failure
  message — falls back to printing the raw status string as if it were one. Each node's
  line is only emitted once, from a goroutine that can race ahead of the node's true
  completion, so a premature mislabel never gets corrected on screen. `--follow` also
  prints no explicit "done" banner on success, so a run can appear to end abruptly on
  one of these lines. **The scrolling text is never the ground truth — always confirm
  with `harness get execution <id>`, which reports the real, correct final status.** If
  this comes up live, it's a one-line aside: "that's a known cosmetic bug in the CLI's
  log streamer, not our pipeline."
- The Aurora cluster's Terraform state is **local only** — not Terraform Cloud, not
  Harness IACM. Matches the "throwaway POC, not load-bearing" framing from the 07-27
  sync; run `terraform destroy` in `infra/` when this is no longer needed rather than
  leaving it running.
- **Springer/ClickHouse log routing for Kubernetes-orchestrated containers — fully
  resolved for this account/path, see `springer-daemonset-test/`.** The DaemonSet
  filelog-capture mechanism is empirically verified against short-lived containers
  specifically (4/4 real mitigation pod runs captured in full, ~50ms latency, zero
  drops) — the feared startup-race did not reproduce. The PrivateLink allowlist gate
  (`telemetry-gateway-iac` PR #337) is merged and applied, and a second 4/4 test run
  confirmed the log lines actually land in real ClickHouse (`twilio-clickhouse-otel-
  logs-dev-us-east-1`), queried directly, not just captured locally — see §3 of
  `springer-daemonset-test/README.md`. What's still genuinely open: the *official*
  OTK-managed twilhelm DaemonSet wasn't the one tested (a hand-installed equivalent
  was), and only this account's own single-tenant, low-traffic cluster was exercised —
  not a busier/shared production node. Don't present those two boundaries as solved,
  but the core mechanical + delivery risk is no longer a guess either way.
- Standing this delegate up was itself a multi-day process (permission requests, manual
  eksctl + Helm, token regeneration) — exactly the kind of friction Robert wants
  Backstage templates to eliminate before wider rollout. Worth naming directly if asked
  "how hard is this to set up."
- **`kubectl get pods -n harness-delegate-ng` may show a second pod stuck in
  `ImagePullBackOff`, recurring roughly hourly.** The account-level "latest delegate"
  version is pinned to the internal GAR-mirrored image
  (`us-west1-docker.pkg.dev/gar-setup/...`), and the delegate's `upgrader` CronJob tries
  to auto-upgrade to it every hour regardless of what this cluster can actually reach —
  same 403 as the original delegate install (this cluster isn't OTK-onboarded). Harmless
  — the original pod keeps serving throughout — but delete the stray pod
  (`kubectl delete pod <name> -n harness-delegate-ng`) before a demo so it doesn't raise
  questions if someone checks pod status live.
- **Debug image tags `v1.0.1`–`v1.0.3` are left in ECR**, from tracking down the
  `Secret`-variable bug above (each added one more piece of non-secret-revealing debug
  output to `check.sh`). Not part of the actual demo — `v1.0.4` is the real, current
  image. Same "test artifacts left in place, clearly labeled" convention as the anon-auth
  connector test above. Template versions `1.0.6`/`1.0.7`/`1.0.8-diag` similarly still
  exist but aren't marked stable — `1.0.8` is current.
