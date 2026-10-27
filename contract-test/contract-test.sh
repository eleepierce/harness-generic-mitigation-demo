#!/bin/bash
# Contract test for a mitigation image (PLATSRE-1296, point 3 "gate" layer).
#
# Question it answers: "after a base-image or tool bump, does this image still behave like a
# mitigation?" It runs the image on the same ECS Fargate path the launcher uses, under the same
# per-mitigation task role, against a fixture target, and asserts the CONTRACT, not the mitigation's
# business logic:
#
#   C1  pass fixture  -> container exits 0
#   C2  pass fixture  -> the invocation marker line is emitted (service.name + mitigation.invoked)
#   C3  pass fixture  -> the script's own success token is present (exit 0 alone could be a no-op)
#   C4  fail fixture  -> container exits non-zero (a bad-config run must not look like a pass)
#   C5  fail fixture  -> the marker is STILL emitted (it is written before the check script runs)
#   C6  fail fixture  -> the success token is absent
#   C7  the task role has no attached or inline policies (the mitigation needs no AWS permissions)
#   C8  the wrapper decoded MITIGATION_ENV_JSON_B64 (implied by C1 reaching the fixture; asserted via C3)
#
# Optional per-mitigation extras (see the *_extra / *_note functions below):
#   X1-X3  an "extra" failing case (e.g. connectivity-check pointed at a closed port) must exit
#          non-zero, still emit the marker, and show the script's own failure line, not the success token
#   P1     an extra token that must appear on the pass run (connectivity-check: SQL_SKIPPED)
#   S1-S3  connectivity-check SQL path against a real MariaDB (needs fixtures.sh up):
#          S1 right credential -> exit 0 + SQL_OK + marker; S2 wrong credential -> non-zero +
#          SQL_FAILED, never SQL_OK; S3 the password never appears in either log
#   K1-K4  pod-access-check pass case against the harness-poc EKS cluster (needs fixtures.sh up):
#          K1-K3 exec into the one permitted pod -> exit 0 + marker + POD_ACCESS_OK + the retrieved file;
#          K4 exec into a pod the ServiceAccount may NOT touch -> non-zero + a Forbidden error + POD_ACCESS_FAILED
#   SKIP   an assertion that cannot be run honestly (fixtures not up, no secret) is reported SKIP with
#          the reason, never silently dropped. SKIPs do not fail the run unless STRICT=1.
#
# Fixtures: fixtures.sh up|down. Without them the S*/K* assertions SKIP and everything else runs as before.
# pod-access-check runs under a shim: the container is started with `/bin/sh -c` that writes a kubeconfig
# from $KUBECONFIG_B64 and then execs the image's own mitigation-entrypoint.sh + pod-access-check.sh. That is
# what a Harness step does for a real run (it supplies the kubeconfig); the wrapper and script under test are
# the image's own, unmodified.
#
# Usage:  contract-test.sh [name[:tag] ...]      default: redis-check zk-check es-check at TAG (v2.2.0)
#         e.g. contract-test.sh connectivity-check:v2.3.0 pod-access-check:v2.2.0
# Needs:  aws CLI with a profile for the sandbox account, jq. Runs every case in parallel.
#         Per mitigation: ECR repo harness-poc/<name>, task role harness-poc-mitigation-<name>
#         (EMPTY), log group /ecs/harness-poc-mitigation/<name>.
# Exit:   0 if every assertion that ran held, 1 otherwise.
set -u

export AWS_PROFILE="${AWS_PROFILE:-cnd-eleepierce-sandbox:Standard_Administrator}" AWS_REGION=us-east-1 AWS_PAGER=""
ACCT=547641909728
HOST=$ACCT.dkr.ecr.us-east-1.amazonaws.com
CLUSTER=harness-poc-mitigation
SUBNETS=subnet-0e03fe41c740515df,subnet-0a53a43b9278b1b7b
SG=sg-04ac82eeae54cd226
EXEC_ROLE=arn:aws:iam::$ACCT:role/harness-poc-mitigation-exec
DEFAULT_TAG="${TAG:-v2.2.0}"
WORK=$(mktemp -d "${TMPDIR:-/tmp}/contract-test.XXXXXX")
DIR=$(cd "$(dirname "$0")" && pwd)

# Fixtures (optional): MYSQL_HOST / MYSQL_PASSWORD from the state file, and a fresh short-lived kubeconfig.
MYSQL_HOST=""; MYSQL_PASSWORD=""; KUBECONFIG_B64=""
FIXTURE_STATE="${CONTRACT_FIXTURE_DIR:-${TMPDIR:-/tmp}/rgm-contract-fixtures}/fixtures.env"
if [ -f "$FIXTURE_STATE" ]; then
  # shellcheck disable=SC1090
  . "$FIXTURE_STATE"
  KUBECONFIG_B64=$("$DIR/fixtures.sh" kubeconfig-b64 2>/dev/null) || { KUBECONFIG_B64=""; echo "WARN: fixtures are up but a kubeconfig could not be minted; K1-K4 will SKIP"; }
fi

# Fixture targets. Fargate cannot resolve cluster-local names, so these are pod IPs.
# An empty fixture_pass means "no honest passing fixture exists in the sandbox": the pass case is
# SKIPPED (not faked) and its assertions are reported as SKIP.
fixture_pass() { # name -> env json for a reachable target
  case "$1" in
    redis-check) echo '{"REDIS_HOST":"192.168.98.89","REDIS_PORT":"6379"}';;
    zk-check)    echo '{"ZK_HOST":"192.168.123.249","ZK_PORT":"2181"}';;
    es-check)    echo '{"ES_HOST":"192.168.81.61","ES_PORT":"9200"}';;
    # connectivity-check is a TCP reachability check; any open sandbox port is a valid target. Using the
    # redis fixture's port deliberately WITHOUT DB_USER/DB_PASSWORD, so the script takes its
    # connectivity-only branch (SQL_SKIPPED). The SQL branch needs a MySQL and a credential: not run.
    connectivity-check) echo '{"TARGET_HOST":"192.168.98.89","TARGET_PORT":"6379"}';;
    # pod-access-check does `kubectl exec`. The pass case needs a kubeconfig whose ServiceAccount may exec
    # into the target (fixtures.sh up); without it there is no honest passing fixture and the case SKIPs.
    pod-access-check) [ -n "$KUBECONFIG_B64" ] && echo '{"TARGET_POD":"pod-access-target"}' || echo '';;
  esac
}
# Extra cases that exist only when fixtures are up. Same naming as pass/fail/extra.
fixture_sql() {    # right credential
  echo "{\"TARGET_HOST\":\"$MYSQL_HOST\",\"TARGET_PORT\":\"3306\",\"DB_USER\":\"root\",\"DB_PASSWORD\":\"$MYSQL_PASSWORD\"}"
}
fixture_sqlbad() { # wrong credential: TCP is reachable, so the script must get past REACHABLE and fail in SQL
  echo "{\"TARGET_HOST\":\"$MYSQL_HOST\",\"TARGET_PORT\":\"3306\",\"DB_USER\":\"root\",\"DB_PASSWORD\":\"wrong-$(printf '%s' "$MYSQL_PASSWORD" | rev)\"}"
}
fixture_deny() {   # a pod that exists but the fixture ServiceAccount has no RBAC on
  echo '{"TARGET_POD":"pod-access-target-2"}'
}
fixture_for() { # name kind
  case $2 in
    pass) fixture_pass "$1";; extra) fixture_extra "$1";; sql) fixture_sql;; sqlbad) fixture_sqlbad;; deny) fixture_deny;;
    *) fixture_fail;;
  esac
}
# Which cases run for a mitigation. sql/sqlbad/deny exist only when their fixtures are up.
kinds_for() {
  local k="pass fail extra"
  case "$1" in
    connectivity-check) [ -n "$MYSQL_HOST" ] && k="$k sql sqlbad";;
    pod-access-check)   [ -n "$KUBECONFIG_B64" ] && k="$k deny";;
  esac
  echo "$k"
}
# The fail fixture is deliberately "required config missing": it fails fast and deterministically
# (a closed port can hang on a connect timeout instead of failing).
fixture_fail() { echo '{}'; }
# Optional second failing case that reaches deeper into the script than the missing-config guard.
fixture_extra() {
  case "$1" in
    # target set but nothing listening: must hit the script's UNREACHABLE branch (5s timeout inside the script)
    connectivity-check) echo '{"TARGET_HOST":"192.168.98.89","TARGET_PORT":"1"}';;
    # TARGET_POD set but no Kubernetes API reachable/configured: reaches kubectl, which proves the
    # binary is present and runnable, and must end in POD_ACCESS_FAILED, never POD_ACCESS_OK.
    pod-access-check) echo '{"TARGET_POD":"rgm-test-nonexistent-pod"}';;
  esac
}
extra_token() { case "$1" in connectivity-check) echo 'UNREACHABLE: could not open TCP';; pod-access-check) echo 'POD_ACCESS_FAILED';; esac; }
pass_extra_token() { case "$1" in connectivity-check) echo 'SQL_SKIPPED';; esac; }
ok_token() {
  case "$1" in
    redis-check) echo REDIS_CHECK_OK;; zk-check) echo ZK_CHECK_OK;; es-check) echo ES_CHECK_OK;;
    # NB "UNREACHABLE: ..." contains "REACHABLE:", so match the full success phrase
    connectivity-check) echo 'REACHABLE: successfully opened TCP';;
    pod-access-check) echo POD_ACCESS_OK;;
  esac
}
# marker service.name. Default is generic-mitigation-<name>; connectivity-check builds from container/
# whose script is check.sh and the Dockerfile sets no MITIGATION_SERVICE_NAME, so the image emits
# generic-mitigation-check (still matches the fleet query ServiceName LIKE 'generic-mitigation%').
svc_name() { case "$1" in connectivity-check) echo generic-mitigation-check;; *) echo "generic-mitigation-$1";; esac; }
pass_skip_reason() {
  case "$1" in
    pod-access-check) echo "kubectl exec needs a kubeconfig for the harness-poc cluster; run fixtures.sh up";;
    *) echo "no honest pass fixture in the sandbox";;
  esac
}
# Assertions that exist but cannot run in this environment, printed as SKIP lines with the reason.
skip_notes() {
  case "$1" in
    connectivity-check) [ -z "$MYSQL_HOST" ] && echo "S1-S3 SQL path (SQL_OK / SQL_FAILED with DB_USER+DB_PASSWORD)|needs a reachable MariaDB and a credential; run fixtures.sh up";;
    pod-access-check)   [ -z "$KUBECONFIG_B64" ] && echo "K4 exec into a pod the ServiceAccount may not touch|needs fixtures.sh up";;
  esac
}

# run_case <name> <tag> <pass|fail>  -> writes $WORK/<name>.<kind>.{exit,log}
run_case() {
  local name=$1 tag=$2 kind=$3 role fam lg env b64 digest td task st tid
  role=arn:aws:iam::$ACCT:role/harness-poc-mitigation-$name
  fam=harness-poc-contract-$name-$kind
  lg=/ecs/harness-poc-mitigation/$name
  env=$(fixture_for "$name" "$kind")
  if [ -z "$env" ]; then echo "SKIP" > "$WORK/$name.$kind.exit"; : > "$WORK/$name.$kind.log"; return; fi
  b64=$(printf '%s' "$env" | base64 | tr -d '\n')
  # run the digest, as the launcher does, so the test exercises the same bytes a verify step would pass
  digest=$(aws ecr describe-images --repository-name "harness-poc/$name" --image-ids imageTag="$tag" \
           --query 'imageDetails[0].imageDigest' --output text 2>/dev/null)
  case "$digest" in sha256:*) ;; *) echo "no such image $name:$tag" > "$WORK/$name.$kind.log"; echo "-" > "$WORK/$name.$kind.exit"; return;; esac
  # pod-access-check pass/deny run under the kubeconfig shim (see header); everything else runs the image as built
  local kc="" cmd=""
  if [ "$name" = pod-access-check ] && { [ "$kind" = pass ] || [ "$kind" = deny ]; }; then
    kc=$KUBECONFIG_B64
    cmd='printf %s "$KUBECONFIG_B64" | base64 -d > /tmp/kubeconfig && export KUBECONFIG=/tmp/kubeconfig && exec /usr/local/bin/mitigation-entrypoint.sh /usr/local/bin/pod-access-check.sh'
  fi
  jq -n --arg fam "$fam" --arg exec "$EXEC_ROLE" --arg role "$role" --arg img "$HOST/harness-poc/$name@$digest" \
        --arg b64 "$b64" --arg lg "$lg" --arg kind "$kind" --arg kc "$kc" --arg cmd "$cmd" '
    {family:$fam, networkMode:"awsvpc", requiresCompatibilities:["FARGATE"], cpu:"512", memory:"1024",
     executionRoleArn:$exec, taskRoleArn:$role,
     containerDefinitions:[({name:"mitigation", image:$img, essential:true,
       environment:([{name:"MITIGATION_ENV_JSON_B64", value:$b64}, {name:"MITIGATION_ENVIRONMENT", value:"contract-test"},
                     {name:"MITIGATION_TARGET_ROLE", value:"contract-fixture"}]
                    + (if $kc != "" then [{name:"KUBECONFIG_B64", value:$kc}] else [] end)),
       logConfiguration:{logDriver:"awslogs", options:{"awslogs-group":$lg, "awslogs-region":"us-east-1", "awslogs-stream-prefix":("contract-" + $kind)}}}
      + (if $cmd != "" then {entryPoint:["/bin/sh","-c"], command:[$cmd]} else {} end))]}' > "$WORK/$name.$kind.td.json"
  td=$(aws ecs register-task-definition --cli-input-json "file://$WORK/$name.$kind.td.json" \
       --query 'taskDefinition.taskDefinitionArn' --output text 2>&1) || { echo "$td" > "$WORK/$name.$kind.log"; echo "-" > "$WORK/$name.$kind.exit"; return; }
  task=$(aws ecs run-task --cluster $CLUSTER --task-definition "$td" --launch-type FARGATE --count 1 \
         --network-configuration "awsvpcConfiguration={subnets=[$SUBNETS],securityGroups=[$SG],assignPublicIp=DISABLED}" \
         --query 'tasks[0].taskArn' --output text 2>&1)
  case "$task" in arn:*) ;; *) echo "run-task failed: $task" > "$WORK/$name.$kind.log"; echo "-" > "$WORK/$name.$kind.exit"; aws ecs deregister-task-definition --task-definition "$td" >/dev/null 2>&1; return;; esac
  for _ in $(seq 1 36); do
    st=$(aws ecs describe-tasks --cluster $CLUSTER --tasks "$task" --query 'tasks[0].lastStatus' --output text 2>/dev/null)
    [ "$st" = STOPPED ] && break; sleep 10
  done
  aws ecs describe-tasks --cluster $CLUSTER --tasks "$task" \
    --query "tasks[0].containers[?name=='mitigation'].exitCode | [0]" --output text > "$WORK/$name.$kind.exit" 2>/dev/null
  tid=$(basename "$task")
  sleep 8   # CloudWatch delivery
  aws logs get-log-events --log-group-name "$lg" --log-stream-name "contract-$kind/mitigation/$tid" --start-from-head \
    --query 'events[].message' --output text > "$WORK/$name.$kind.log" 2>&1
  aws ecs deregister-task-definition --task-definition "$td" >/dev/null 2>&1
}

PASS=0; FAILN=0; SKIPN=0
skip() { SKIPN=$((SKIPN+1)); printf '  SKIP  %s  (%s)\n' "$1" "$2"; }
check() { # label, condition-exit-status, detail
  if [ "$2" -eq 0 ]; then PASS=$((PASS+1)); printf '  PASS  %s\n' "$1"
  else FAILN=$((FAILN+1)); printf '  FAIL  %s  (%s)\n' "$1" "$3"; fi
}

TARGETS=("$@"); [ ${#TARGETS[@]} -eq 0 ] && TARGETS=(redis-check zk-check es-check)
declare -a NAMES TAGS
for t in "${TARGETS[@]}"; do NAMES+=("${t%%:*}"); case "$t" in *:*) TAGS+=("${t#*:}");; *) TAGS+=("$DEFAULT_TAG");; esac; done

echo "contract test: ${TARGETS[*]}   (work dir $WORK)"
for n in "${NAMES[@]}"; do
  aws iam get-role --role-name "harness-poc-mitigation-$n" >/dev/null 2>&1 || echo "WARN: task role harness-poc-mitigation-$n does not exist (create it EMPTY first)"
  [ "$(aws logs describe-log-groups --log-group-name-prefix "/ecs/harness-poc-mitigation/$n" --query "length(logGroups[?logGroupName=='/ecs/harness-poc-mitigation/$n'])" --output text 2>/dev/null)" = 1 ] \
    || echo "WARN: log group /ecs/harness-poc-mitigation/$n does not exist"
done
for i in "${!NAMES[@]}"; do
  for kind in $(kinds_for "${NAMES[$i]}"); do run_case "${NAMES[$i]}" "${TAGS[$i]}" "$kind" & done
done
wait

for i in "${!NAMES[@]}"; do
  n=${NAMES[$i]}; tag=${TAGS[$i]}; tok=$(ok_token "$n"); svc=$(svc_name "$n")
  echo; echo "== $n:$tag"
  pe=$(cat "$WORK/$n.pass.exit" 2>/dev/null); fe=$(cat "$WORK/$n.fail.exit" 2>/dev/null); xe=$(cat "$WORK/$n.extra.exit" 2>/dev/null)
  pl="$WORK/$n.pass.log"; fl="$WORK/$n.fail.log"; xl="$WORK/$n.extra.log"
  marker() { grep -q "\"service.name\":\"$svc\"" "$1" && grep -q '"mitigation.invoked":true' "$1"; }
  nonzero() { case "$1" in ''|-|0|None|SKIP) return 1;; *) return 0;; esac; }
  if [ "$pe" = SKIP ]; then
    skip "C1-C3 pass fixture (exit 0, marker, $tok)" "$(pass_skip_reason "$n")"
  else
    [ "$pe" = 0 ];                         check "C1 pass fixture exits 0"                 $? "exit=$pe"
    marker "$pl";                          check "C2 pass fixture emits invocation marker" $? "no marker line in log"
    grep -q "$tok" "$pl";                  check "C3 pass fixture emits $tok"              $? "token absent"
    pt=$(pass_extra_token "$n")
    if [ -n "$pt" ]; then grep -q "$pt" "$pl"; check "P1 pass fixture emits $pt" $? "token absent"; fi
  fi
  nonzero "$fe";                           check "C4 fail fixture exits non-zero"          $? "exit=$fe"
  marker "$fl";                            check "C5 fail fixture still emits marker"      $? "no marker line in log"
  ! grep -q "$tok" "$fl";                  check "C6 fail fixture does not emit $tok"      $? "token present on a failing run"
  if [ "$xe" != SKIP ] && [ -n "$xe" ]; then
    xt=$(extra_token "$n")
    nonzero "$xe";                         check "X1 deeper-fail fixture exits non-zero"   $? "exit=$xe"
    marker "$xl";                          check "X2 deeper-fail fixture emits marker"     $? "no marker line in log"
    grep -q "$xt" "$xl" && ! grep -q "$tok" "$xl"; check "X3 deeper-fail shows '$xt', never '$tok'" $? "wrong tokens"
  fi
  if [ "$n" = connectivity-check ] && [ -n "$MYSQL_HOST" ]; then
    se=$(cat "$WORK/$n.sql.exit" 2>/dev/null); sl="$WORK/$n.sql.log"; be=$(cat "$WORK/$n.sqlbad.exit" 2>/dev/null); bl="$WORK/$n.sqlbad.log"
    [ "$se" = 0 ];                         check "S1a right credential exits 0"            $? "exit=$se"
    grep -q 'SQL_OK' "$sl";                check "S1b right credential emits SQL_OK"       $? "SQL_OK absent"
    marker "$sl";                          check "S1c right credential emits marker"       $? "no marker line in log"
    nonzero "$be";                         check "S2a wrong credential exits non-zero"     $? "exit=$be"
    grep -q 'SQL_FAILED' "$bl" && ! grep -q 'SQL_OK' "$bl"; check "S2b wrong credential shows SQL_FAILED, never SQL_OK" $? "wrong tokens"
    ! grep -qF "$MYSQL_PASSWORD" "$sl" "$bl"; check "S3 the DB password never appears in either log" $? "password found in a log"
  fi
  if [ "$n" = pod-access-check ] && [ -n "$KUBECONFIG_B64" ]; then
    de=$(cat "$WORK/$n.deny.exit" 2>/dev/null); dl="$WORK/$n.deny.log"
    grep -q 'proof-of-access' "$pl";       check "K1 pass fixture retrieved the target file" $? "file content absent"
    nonzero "$de";                         check "K4a denied pod exits non-zero"           $? "exit=$de"
    grep -qi 'forbidden' "$dl" && grep -q 'POD_ACCESS_FAILED' "$dl" && ! grep -q 'POD_ACCESS_OK' "$dl"; check "K4b denied pod shows Forbidden + POD_ACCESS_FAILED, never POD_ACCESS_OK" $? "wrong tokens"
    ! grep -q 'eyJ' "$pl" "$dl";           check "K4c no bearer token appears in either log" $? "token-like string in a log"
  fi
  while IFS='|' read -r lbl why; do [ -n "$lbl" ] && skip "$lbl" "$why"; done < <(skip_notes "$n")
  att=$(aws iam list-attached-role-policies --role-name "harness-poc-mitigation-$n" --query 'length(AttachedPolicies)' --output text 2>/dev/null)
  inl=$(aws iam list-role-policies --role-name "harness-poc-mitigation-$n" --query 'length(PolicyNames)' --output text 2>/dev/null)
  [ "$att" = 0 ] && [ "$inl" = 0 ];        check "C7 task role has no policies"            $? "attached=$att inline=$inl"
done

echo; echo "RESULT: $PASS passed, $FAILN failed, $SKIPN skipped (not run)"
[ "$FAILN" -eq 0 ] && { [ "${STRICT:-0}" != 1 ] || [ "$SKIPN" -eq 0 ]; }
