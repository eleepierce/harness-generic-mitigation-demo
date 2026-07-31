# Harness Generic Mitigation Demo

POC materials for PLATSRE-1537 (Mitigation Invocation Normalization) supporting the
"Harness as front door" proposal. Proves two things end to end: (1) a Harness delegate
can reach a private-VPC database (the risk Robert Acosta flagged in the 07-27 sync),
and (2) a containerized "blessed" mitigation script can be invoked with one CLI command,
targeting a resource specified at runtime, with a full audit trail in Harness.

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
same idea as the real Buildkite → Cosign → registry pipeline).

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
# docker build --platform linux/amd64 -t 547641909728.dkr.ecr.us-east-1.amazonaws.com/harness-poc/connectivity-check:v1.0.0 container/
# docker push 547641909728.dkr.ecr.us-east-1.amazonaws.com/harness-poc/connectivity-check:v1.0.0

# THE live demo command — one command, runtime-supplied target:
harness execute pipeline rungenericmitigationdemo \
  --org cloudnativeplatform --project reliability_engineering \
  --input target_host=harness-poc-connectivity-test.cluster-cc7gy6moir8k.us-east-1.rds.amazonaws.com \
  --input target_port=3306 \
  --follow

# Show the execution record (use the ExecutionId printed above, or omit the id
# and check the Harness UI link it prints)
harness get execution rungenericmitigationdemo/<execution-id> \
  --org cloudnativeplatform --project reliability_engineering
```

**Optional — prove it's genuinely parameterized, not hardcoded:** re-run with an
unreachable target to show the failure path is real too:

```bash
harness execute pipeline rungenericmitigationdemo \
  --org cloudnativeplatform --project reliability_engineering \
  --input target_host=example.com \
  --input target_port=9999 \
  --follow
# Expect: Status Failed, log shows "UNREACHABLE: could not open TCP connection to example.com:9999"
```

Known-good sample output from a real run (execution `rBeyDbACR2eT89VF-Xn6VA`):

```
Status:       Success
Stages:       1 total, 1 success, 0 failed

✓ mitigation (18s)
  ✓ Execution (16s)
    ✓ mitigation (13s)
      ✓ Initialize (7s)
      ✓ Run Mitigation Container (3s)

Testing TCP reachability to harness-poc-connectivity-test.cluster-cc7gy6moir8k.us-east-1.rds.amazonaws.com:3306...
REACHABLE: successfully opened TCP connection to harness-poc-connectivity-test.cluster-cc7gy6moir8k.us-east-1.rds.amazonaws.com:3306
```

---

## What was created or adjusted this session

**Harness (org `cloudnativeplatform` / project `reliability_engineering`):**

| Object | Identifier | Notes |
|---|---|---|
| Delegate | `harness-poc-delegate` | Helm-installed, running in EKS cluster `harness-poc` |
| Connector (K8sCluster) | `harnesspoceks` | `InheritFromDelegate` — no separate cluster credentials |
| Connector (Aws) | `harnesspocaws` | `InheritFromDelegate` — used for ECR image pull auth |
| Template (Stage) | `rungenericmitigation` | v1.0.3 marked stable — `harness/run-generic-mitigation-template.yaml` |
| Pipeline | `rungenericmitigationdemo` | The container+template demo — `harness/run-generic-mitigation-demo-pipeline.yaml` |
| Pipeline | `harnesspocvpcconnectivitytest` | Earlier, simpler proof (inline shell, no container) that first confirmed private-VPC DB reachability |

**AWS (account `cnd-eleepierce-sandbox`, 547641909728, us-east-1):**

| Resource | Identifier | Notes |
|---|---|---|
| EKS cluster | `harness-poc` | Created via eksctl, `harness-db-devop-poc/infra/eks-cluster.yaml` |
| Aurora MySQL cluster | `harness-poc-connectivity-test` | `infra/aurora-test-target.tf` — hand-written, deliberately NOT using the `terraform-twilio-aws-aurora` module (it requires a live Datadog API key + PagerDuty service with no opt-out) |
| ECR repo + image | `harness-poc/connectivity-check:v1.0.0` | The blessed mitigation container |

**This repo:**

- `container/check.sh`, `container/Dockerfile` — the mitigation script itself
- `harness/*.yaml` — template, pipeline, and connector definitions, as actually applied
- `infra/aurora-test-target.tf` — the standalone Aurora Terraform (local state only)

---

## Caveats worth knowing before presenting

- The Aurora cluster's Terraform state is **local only** — not Terraform Cloud, not
  Harness IACM. Matches the "throwaway POC, not load-bearing" framing from the 07-27
  sync; run `terraform destroy` in `infra/` when this is no longer needed rather than
  leaving it running.
- **Springer/ClickHouse log routing for Kubernetes-orchestrated containers is a real,
  unresolved gap** — unlike the private-VPC-DB risk (which this repo's pipelines
  actually resolved), this one is still open. The mechanism exists on OTK via an OTel
  Collector DaemonSet, but it's opt-in per workload, still pilot-stage even for the team
  that owns it, and untested for short-lived containers specifically. Don't present this
  as solved.
- Standing this delegate up was itself a multi-day process (permission requests, manual
  eksctl + Helm, token regeneration) — exactly the kind of friction Robert wants
  Backstage templates to eliminate before wider rollout. Worth naming directly if asked
  "how hard is this to set up."
