# Harness Generic Mitigation Demo

POC for PLATSRE-1537 - Harness as a mitigation invocation front door. 

**Full write-up:** [Harness Generic Mitigation for CND POC](https://docs.google.com/document/d/1rZVuQRlsCdRgplfoHaljRKBsqKHatkQCDSffJmJSWNE/edit)

## Layout

- `container/` — mitigation script + Dockerfile
- `container-pod-access/` — pod-level access test (kubectl exec into a separate pod, retrieve a file — answers "can this reach inside a pod, not just a DB/host")
- `harness/` — template, pipeline, connector YAML
- `infra/` — Terraform (Aurora test target, ECR auth refresher, Springer VPC endpoint)
- `springer-daemonset-test/` — Springer log-delivery test

## Pod-level access (added 08-04, answers Robert's review-meeting question)

Everything above proves reaching a database. This proves reaching *inside* a
separate, already-running pod — e.g. to pull a file or (with a different
in-container command) take a memory dump, not just open a socket to a host.

Real execution: `harnesspocpodaccesstest`, `a-bBUmTQSMOsogBvJurXkQ`, `Status:
Success` — a Harness-orchestrated container ran `kubectl exec` against a
separate target pod and retrieved real file content:

```
POD_ACCESS_OK: successfully retrieved file content from default/pod-access-target:/tmp/proof.txt
--- retrieved content ---
CONFIDENTIAL: proof-of-access test file, retrieved via Harness pod-access mechanism
--- end retrieved content ---
```

**Requires explicit RBAC** — a `Role` granting `pods/exec` (+ `pods/get`,
`pods/log`) and a `RoleBinding` to the namespace's default service account.
Not on by default; someone has to grant it per-namespace.

**Real gotcha hit along the way:** pushing a new image to a new ECR repo
(`harness-poc/pod-access-check`) failed with `ecr:BatchGetImage: DENIED` — the
token-refresher Lambda's IAM role was scoped to the *original* repo only (ECR
tokens are principal-scoped, see the durable-auth section in the one-pager).
Fixed by widening `infra/ecr-token-refresher.tf`'s resource ARN to
`harness-poc/*` instead of one hardcoded repo name.
