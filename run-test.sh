#!/usr/bin/env bash
# Test: single egress waypoint with ServiceEntry-targeted AuthorizationPolicies.
#
# Deploys two postgres instances behind LoadBalancers (simulating external DBs),
# creates ServiceEntries using nip.io hostnames, and validates that per-ServiceEntry
# AuthorizationPolicies enforce namespace-based access control through a single waypoint.
#
# Expected results:
#   rds-demo-1 -> postgres-1: ALLOWED
#   rds-demo-1 -> postgres-2: DENIED
#   rds-demo-2 -> postgres-2: ALLOWED
#   rds-demo-2 -> postgres-1: DENIED

set -euo pipefail

DIR="$(cd "$(dirname "$0")" && pwd)"
PASS=0
FAIL=0
TIMEOUT=3

green() { printf '\033[0;32m%s\033[0m\n' "$*"; }
red()   { printf '\033[0;31m%s\033[0m\n' "$*"; }
bold()  { printf '\033[1m%s\033[0m\n' "$*"; }

# ---------- helpers ----------

# wait_for_lb <namespace> <service-name> - waits for external IP and prints it
wait_for_lb() {
  local ns="$1" svc="$2"
  local ip=""
  for i in $(seq 1 60); do
    ip=$(kubectl get svc -n "$ns" "$svc" -o jsonpath='{.status.loadBalancer.ingress[0].ip}' 2>/dev/null || true)
    if [[ -n "$ip" && "$ip" != "null" ]]; then
      echo "$ip"
      return 0
    fi
    sleep 5
  done
  red "Timed out waiting for LoadBalancer IP on $ns/$svc"
  return 1
}

# ---------- deploy ----------

deploy() {
  bold "=== Deploying test resources ==="

  kubectl apply -f "$DIR/01-namespaces.yaml"
  kubectl apply -f "$DIR/02-postgres.yaml"
  kubectl apply -f "$DIR/03-egress-waypoint.yaml"

  bold "Waiting for waypoint deployment..."
  kubectl -n istio-egress rollout status deployment/waypoint --timeout=120s

  bold "Waiting for postgres pods..."
  kubectl -n db rollout status deployment/postgres-1 --timeout=120s
  kubectl -n db rollout status deployment/postgres-2 --timeout=120s

  bold "Waiting for postgres-1 LoadBalancer IP..."
  PG1_IP=$(wait_for_lb db postgres-1)
  bold "  postgres-1 LB IP: $PG1_IP"

  bold "Waiting for postgres-2 LoadBalancer IP..."
  PG2_IP=$(wait_for_lb db postgres-2)
  bold "  postgres-2 LB IP: $PG2_IP"

  export PG1_IP PG2_IP
  export POSTGRES1_HOST="${PG1_IP}.nip.io"
  export POSTGRES2_HOST="${PG2_IP}.nip.io"
  bold "ServiceEntry hosts:"
  bold "  postgres-1: $POSTGRES1_HOST"
  bold "  postgres-2: $POSTGRES2_HOST"

  envsubst '${POSTGRES1_HOST} ${POSTGRES2_HOST} ${PG1_IP} ${PG2_IP}' < "$DIR/04-serviceentries.yaml" | kubectl apply -f -
  kubectl apply -f "$DIR/05-authz-policies.yaml"
  kubectl apply -f "$DIR/06-client-pods.yaml"
  kubectl apply -f "$DIR/07-telemetry.yaml"

  bold "Waiting for client pods..."
  kubectl -n rds-demo-1 wait pod/client --for=condition=Ready --timeout=120s
  kubectl -n rds-demo-2 wait pod/client --for=condition=Ready --timeout=120s

  # Persist hosts for the test phase
  echo "$POSTGRES1_HOST" > "$DIR/.pg1_host"
  echo "$POSTGRES2_HOST" > "$DIR/.pg2_host"

  bold "All resources deployed. Waiting 15s for mesh programming..."
  sleep 15
}

# ---------- test helpers ----------

load_hosts() {
  if [[ -z "${POSTGRES1_HOST:-}" ]]; then
    POSTGRES1_HOST=$(cat "$DIR/.pg1_host" 2>/dev/null || true)
    POSTGRES2_HOST=$(cat "$DIR/.pg2_host" 2>/dev/null || true)
  fi
  if [[ -z "$POSTGRES1_HOST" || -z "$POSTGRES2_HOST" ]]; then
    red "Host files not found. Run 'deploy' first."
    exit 1
  fi
}

# test_connect <namespace> <target-host> <expect: allow|deny>
test_connect() {
  local ns="$1" host="$2" expect="$3"
  local label="$ns -> $host"

  # pg_isready does a lightweight postgres protocol check.
  # On ALLOW: returns 0 (accepting connections).
  # On DENY:  connection is reset by the waypoint, returns non-zero.
  if kubectl exec -n "$ns" client -- \
       pg_isready -h "$host" -p 5432 -t "$TIMEOUT" >/dev/null 2>&1; then
    result="allow"
  else
    result="deny"
  fi

  if [[ "$result" == "$expect" ]]; then
    green "  PASS  $label  (expected=$expect, got=$result)"
    PASS=$((PASS + 1))
  else
    red   "  FAIL  $label  (expected=$expect, got=$result)"
    FAIL=$((FAIL + 1))
  fi
}

# ---------- run tests ----------

run_tests() {
  load_hosts

  bold ""
  bold "=== Running connectivity tests ==="
  bold "  postgres-1 host: $POSTGRES1_HOST"
  bold "  postgres-2 host: $POSTGRES2_HOST"
  bold ""

  bold "From rds-demo-1:"
  test_connect rds-demo-1 "$POSTGRES1_HOST" allow
  test_connect rds-demo-1 "$POSTGRES2_HOST" deny

  bold ""
  bold "From rds-demo-2:"
  test_connect rds-demo-2 "$POSTGRES2_HOST" allow
  test_connect rds-demo-2 "$POSTGRES1_HOST" deny

  bold ""
  bold "=== Results: $PASS passed, $FAIL failed ==="
  if [[ "$FAIL" -gt 0 ]]; then
    red "Some tests failed."
    return 1
  else
    green "All tests passed."
    return 0
  fi
}

# ---------- teardown ----------

teardown() {
  bold "=== Tearing down test resources ==="
  kubectl delete -f "$DIR/07-telemetry.yaml" --ignore-not-found
  kubectl delete -f "$DIR/06-client-pods.yaml" --ignore-not-found
  kubectl delete -f "$DIR/05-authz-policies.yaml" --ignore-not-found
  kubectl delete serviceentry postgres-1 postgres-2 -n istio-egress --ignore-not-found
  kubectl delete -f "$DIR/03-egress-waypoint.yaml" --ignore-not-found
  kubectl delete -f "$DIR/02-postgres.yaml" --ignore-not-found
  kubectl delete -f "$DIR/01-namespaces.yaml" --ignore-not-found
  rm -f "$DIR/.pg1_host" "$DIR/.pg2_host"
}

# ---------- main ----------

usage() {
  echo "Usage: $0 [deploy|test|teardown|all]"
  echo "  deploy    - Deploy all test resources"
  echo "  test      - Run connectivity tests (resources must be deployed)"
  echo "  teardown  - Remove all test resources"
  echo "  all       - Deploy, test, and teardown"
  exit 1
}

case "${1:-all}" in
  deploy)   deploy ;;
  test)     run_tests ;;
  teardown) teardown ;;
  all)      deploy && run_tests; rc=$?; teardown; exit $rc ;;
  *)        usage ;;
esac
