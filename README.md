# Harness Generic Mitigation Demo

POC for PLATSRE-1537 - Harness as a mitigation invocation front door. 

**Full write-up:** [Harness Generic Mitigation for CND POC](https://docs.google.com/document/d/1rZVuQRlsCdRgplfoHaljRKBsqKHatkQCDSffJmJSWNE/edit)

## Layout

- `container/` — mitigation script + Dockerfile
- `container-pod-access/` — pod-level access test (kubectl exec into a separate pod, retrieve a file — answers "can this reach inside a pod, not just a DB/host")
- `harness/` — template, pipeline, connector YAML
- `infra/` — Terraform (Aurora test target, ECR auth refresher, Springer VPC endpoint)
- `springer-daemonset-test/` — Springer log-delivery test
