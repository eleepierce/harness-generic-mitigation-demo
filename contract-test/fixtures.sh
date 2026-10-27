#!/usr/bin/env bash
# Throwaway fixtures that let contract-test.sh run the two assertions that otherwise SKIP:
#   - connectivity-check SQL path : a MariaDB on Fargate (private IP, random root password)
#   - pod-access-check pass case  : a ServiceAccount on the harness-poc EKS cluster that can exec into
#                                   exactly ONE pod (pod-access-target); the test mints a short-lived
#                                   token for it on every run
# Usage:  fixtures.sh up | down | status | kubeconfig-b64
# State:  $STATE_DIR (outside the repo; holds the generated DB password, mode 700). contract-test.sh
#         reads it if present and SKIPs the dependent assertions if not.
# Needs:  aws CLI (sandbox profile), kubectl, jq, openssl.
set -euo pipefail

export AWS_PROFILE="${AWS_PROFILE:-cnd-eleepierce-sandbox:Standard_Administrator}" AWS_REGION=us-east-1 AWS_PAGER=""
ACCT=547641909728
CLUSTER=harness-poc-mitigation
EKS=harness-poc
SUBNETS=subnet-0e03fe41c740515df,subnet-0a53a43b9278b1b7b
SG=sg-04ac82eeae54cd226
EXEC_ROLE=arn:aws:iam::$ACCT:role/harness-poc-mitigation-exec
LG=/ecs/harness-poc-mitigation/fixtures
FAMILY=harness-poc-contract-fixture-mariadb
SA=rgm-contract-test
NS=default
TARGET_POD=pod-access-target
STATE_DIR="${CONTRACT_FIXTURE_DIR:-${TMPDIR:-/tmp}/rgm-contract-fixtures}"
STATE="$STATE_DIR/fixtures.env"
ADMIN_KC="$STATE_DIR/admin.kubeconfig"

kc() { KUBECONFIG="$ADMIN_KC" kubectl "$@"; }

rbac() { cat <<EOF
apiVersion: v1
kind: ServiceAccount
metadata: {name: $SA, namespace: $NS, labels: {app: rgm-contract-test}}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: Role
metadata: {name: $SA, namespace: $NS, labels: {app: rgm-contract-test}}
rules:
- {apiGroups: [""], resources: [pods],      resourceNames: [$TARGET_POD], verbs: [get]}
- {apiGroups: [""], resources: [pods/exec], resourceNames: [$TARGET_POD], verbs: [create]}
---
apiVersion: rbac.authorization.k8s.io/v1
kind: RoleBinding
metadata: {name: $SA, namespace: $NS, labels: {app: rgm-contract-test}}
roleRef: {apiGroup: rbac.authorization.k8s.io, kind: Role, name: $SA}
subjects: [{kind: ServiceAccount, name: $SA, namespace: $NS}]
EOF
}

up() {
  umask 077; mkdir -p "$STATE_DIR"; chmod 700 "$STATE_DIR"
  [ -f "$STATE" ] && { echo "fixtures already up ($STATE); run 'down' first"; exit 1; }

  aws logs describe-log-groups --log-group-name-prefix "$LG" --query "logGroups[?logGroupName=='$LG'].logGroupName" --output text | grep -q . \
    || { aws logs create-log-group --log-group-name "$LG"; aws logs put-retention-policy --log-group-name "$LG" --retention-in-days 1; }

  echo "[mariadb] starting"
  local pw td task ip
  pw=$(openssl rand -hex 16)
  jq -n --arg fam "$FAMILY" --arg exec "$EXEC_ROLE" --arg pw "$pw" --arg lg "$LG" '
    {family:$fam, networkMode:"awsvpc", requiresCompatibilities:["FARGATE"], cpu:"512", memory:"1024", executionRoleArn:$exec,
     containerDefinitions:[{name:"mariadb", image:"public.ecr.aws/docker/library/mariadb:10.11", essential:true,
       environment:[{name:"MARIADB_ROOT_PASSWORD", value:$pw}],
       logConfiguration:{logDriver:"awslogs", options:{"awslogs-group":$lg, "awslogs-region":"us-east-1", "awslogs-stream-prefix":"mariadb"}}}]}' \
     > "$STATE_DIR/mariadb.td.json"
  td=$(aws ecs register-task-definition --cli-input-json "file://$STATE_DIR/mariadb.td.json" --query 'taskDefinition.taskDefinitionArn' --output text)
  task=$(aws ecs run-task --cluster $CLUSTER --task-definition "$td" --launch-type FARGATE --count 1 \
         --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=DISABLED}" \
         --query 'tasks[0].taskArn' --output text)
  # record state first so 'down' can clean up even if the wait below fails
  { echo "MYSQL_TASK=$task"; echo "MYSQL_TD=$td"; echo "MYSQL_PASSWORD=$pw"; } > "$STATE"
  for _ in $(seq 1 30); do
    [ "$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$task" --query 'tasks[0].lastStatus' --output text)" = RUNNING ] && break; sleep 10
  done
  ip=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$task" \
       --query "tasks[0].attachments[0].details[?name=='privateIPv4Address'].value | [0]" --output text)
  [ -n "$ip" ] && [ "$ip" != None ] || { echo "no private IP for $task"; exit 1; }
  echo "MYSQL_HOST=$ip" >> "$STATE"
  # the init server logs 'port: 0'; the real one logs 'port: 3306'
  local tid; tid=$(basename "$task")
  for _ in $(seq 1 30); do
    aws logs get-log-events --log-group-name "$LG" --log-stream-name "mariadb/mariadb/$tid" --query 'events[].message' --output text 2>/dev/null \
      | grep -q 'ready for connections.*port: 3306' && { echo "[mariadb] ready at $ip:3306"; break; }; sleep 10
  done

  echo "[k8s] RBAC for $NS/$SA -> exec into $NS/$TARGET_POD only"
  aws eks update-kubeconfig --name $EKS --kubeconfig "$ADMIN_KC" >/dev/null
  rbac | kc apply -f - >/dev/null
  kc get pod "$TARGET_POD" -n "$NS" >/dev/null || { echo "target pod $NS/$TARGET_POD not found"; exit 1; }
  echo "[done] state in $STATE_DIR"
}

down() {
  if [ -f "$STATE" ]; then
    # shellcheck disable=SC1090
    . "$STATE"
    [ -n "${MYSQL_TASK:-}" ] && aws ecs stop-task --cluster $CLUSTER --task "$MYSQL_TASK" --reason "contract-test fixtures down" >/dev/null 2>&1 || true
    [ -n "${MYSQL_TD:-}" ] && aws ecs deregister-task-definition --task-definition "$MYSQL_TD" >/dev/null 2>&1 || true
  fi
  if [ -f "$ADMIN_KC" ]; then rbac | kc delete -f - --ignore-not-found >/dev/null 2>&1 || true; fi
  rm -rf "$STATE_DIR"
  echo "[down] fixtures removed"
}

status() {
  [ -f "$STATE" ] || { echo "fixtures: down"; return; }
  # shellcheck disable=SC1090
  . "$STATE"
  echo "fixtures: up  mariadb=${MYSQL_HOST:-?}  task=$(basename "${MYSQL_TASK:-?}")"
  kc get sa,role,rolebinding -n "$NS" -l app=rgm-contract-test --no-headers 2>/dev/null | awk '{print "  k8s: "$1}'
}

# A fresh 20-minute token on every call, wrapped in a minimal kubeconfig, base64 on one line.
kubeconfig_b64() {
  [ -f "$ADMIN_KC" ] || { echo "fixtures are not up" >&2; exit 1; }
  local server ca token
  read -r server ca < <(aws eks describe-cluster --name $EKS --query 'cluster.[endpoint,certificateAuthority.data]' --output text)
  token=$(kc create token "$SA" -n "$NS" --duration=20m)
  jq -n --arg s "$server" --arg ca "$ca" --arg t "$token" --arg ns "$NS" '
    {apiVersion:"v1", kind:"Config", "current-context":"c",
     clusters:[{name:"harness-poc", cluster:{server:$s, "certificate-authority-data":$ca}}],
     users:[{name:"rgm", user:{token:$t}}],
     contexts:[{name:"c", context:{cluster:"harness-poc", user:"rgm", namespace:$ns}}]}' | base64 | tr -d '\n'
}

case "${1:-}" in
  up) up;; down) down;; status) status;; kubeconfig-b64) kubeconfig_b64;;
  *) echo "usage: $0 up|down|status|kubeconfig-b64" >&2; exit 2;;
esac
