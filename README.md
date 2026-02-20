# Namespace-Scoped Egress Access Control with Istio Ambient

Control which namespaces can reach which external databases using an egress gateway and per-ServiceEntry AuthorizationPolicies in Istio ambient mode.

## What you'll build

Two application namespaces each need access to a dedicated PostgreSQL database. Cross-access is denied at L4 by the mesh, not by the application.

```
                          ┌──────────────────────────────────────┐
                          │           istio-egress               │
                          │                                      │
                          │  ┌────────────────────────────────┐  │
                          │  │        egress gateway          │  │
┌──────────────┐          │  │                                │  │          ┌──────────────┐
│  rds-demo-1  │          │  │  ┌──────────────────────────┐  │  │          │              │
│              │─────────▶│  │ AuthzPolicy ──▶ SE: pg1     │───────────────▶│  Postgres 1  │
│  (ambient)   │   ALLOW  │  │  └──────────────────────────┘  │  │          │  (external)  │
└──────────────┘          │  │                                │  │          └──────────────┘
       │                  │  │  ┌──────────────────────────┐  │  │
       └ ── ── ── ── ── ─ ──X   │ AuthzPolicy ──▶ SE: pg2  │  │  │
                  DENY    │  │  └──────────────────────────┘  │  │
                          │  │                                │  │
       ┌ ── ── ── ── ── ─ ──X   ┌──────────────────────────┐  │  │
                  DENY    │  │  │ AuthzPolicy ──▶ SE: pg1  │  │  │
┌──────────────┐          │  │  └──────────────────────────┘  │  │          ┌──────────────┐
│  rds-demo-2  │          │  │                                │  │          │              │
│              │────────────▶│  ┌─────────────────────────┐  │─────────────▶│  Postgres 2  │
│  (ambient)   │   ALLOW  │  │  │ AuthzPolicy ──▶ SE: pg2  │  │  │          │  (external)  │
└──────────────┘          │  │  └──────────────────────────┘  │  │          └──────────────┘
                          │  └────────────────────────────────┘  │
                          └──────────────────────────────────────┘

    AuthorizationPolicies target individual ServiceEntries to enforce
                  per-destination access control.
```

## Prerequisites

- A Kubernetes cluster with **Istio in ambient mode** installed
- Gateway API CRDs installed (`kubectl apply -f https://github.com/kubernetes-sigs/gateway-api/releases/download/v1.4.0/standard-install.yaml`)
- Two external databases reachable from the cluster (this workshop uses in-cluster PostgreSQL behind LoadBalancers as stand-ins)

---

## Step 1: Create the namespaces

Four namespaces are needed. The client namespaces are enrolled in ambient mode; the `db` namespace is **not**, so the databases sit outside the mesh like any external service.

```yaml
apiVersion: v1
kind: Namespace
metadata:
  name: db
---
apiVersion: v1
kind: Namespace
metadata:
  name: rds-demo-1
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: Namespace
metadata:
  name: rds-demo-2
  labels:
    istio.io/dataplane-mode: ambient
---
apiVersion: v1
kind: Namespace
metadata:
  name: istio-egress
  labels:
    istio.io/dataplane-mode: ambient
```

```bash
kubectl apply -f 01-namespaces.yaml
```

## Step 2: Deploy the databases

Deploy two PostgreSQL instances behind LoadBalancers in the `db` namespace. These simulate external databases (like RDS) that are outside the mesh.

```bash
kubectl apply -f 02-postgres.yaml
```

Wait for the LoadBalancer IPs:

```bash
kubectl get svc -n db -w
```

Once both services have `EXTERNAL-IP` values, note them down:

```bash
export PG1_IP=$(kubectl get svc -n db postgres-1 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
export PG2_IP=$(kubectl get svc -n db postgres-2 -o jsonpath='{.status.loadBalancer.ingress[0].ip}')
echo "Postgres 1: $PG1_IP    Postgres 2: $PG2_IP"
```

## Step 3: Create the egress gateway

Deploy a waypoint in `istio-egress` to act as the egress gateway. All external traffic with a ServiceEntry binding flows through it.

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: waypoint
  namespace: istio-egress
spec:
  gatewayClassName: istio-waypoint
  listeners:
    - name: mesh
      port: 15008
      protocol: HBONE
      allowedRoutes:
        namespaces:
          from: All
```

```bash
kubectl apply -f 03-egress-waypoint.yaml
kubectl -n istio-egress rollout status deployment/waypoint
```

## Step 4: Create ServiceEntries

Each ServiceEntry registers an external database with the mesh and binds it to the egress gateway using the `istio.io/use-waypoint` label.

We use nip.io hostnames (`<IP>.nip.io`) so the ServiceEntry hosts are distinct from any in-cluster service DNS names.

```yaml
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: postgres-1
  namespace: istio-egress
  labels:
    istio.io/use-waypoint: waypoint          # <-- binds to the egress gateway
spec:
  hosts:
    - <PG1_IP>.nip.io                        # e.g. 35.193.36.62.nip.io
  location: MESH_EXTERNAL
  ports:
    - number: 5432
      name: tcp-postgres
      protocol: TCP
  resolution: DNS
---
apiVersion: networking.istio.io/v1
kind: ServiceEntry
metadata:
  name: postgres-2
  namespace: istio-egress
  labels:
    istio.io/use-waypoint: waypoint
spec:
  hosts:
    - <PG2_IP>.nip.io                        # e.g. 104.154.205.187.nip.io
  location: MESH_EXTERNAL
  ports:
    - number: 5432
      name: tcp-postgres
      protocol: TCP
  resolution: DNS
```

Apply with the IPs substituted:

```bash
envsubst '${PG1_IP} ${PG2_IP}' < 04-serviceentries.yaml | kubectl apply -f -
```

Verify the ServiceEntries are created:

```bash
kubectl get serviceentry -n istio-egress
```

## Step 5: Apply AuthorizationPolicies

Each AuthorizationPolicy targets a specific **ServiceEntry** using `targetRefs`. This scopes the policy to traffic destined for that particular external service.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-postgres-1-from-demo-1
  namespace: istio-egress
spec:
  targetRefs:
    - kind: ServiceEntry
      group: networking.istio.io
      name: postgres-1
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces: ["rds-demo-1"]
      to:
        - operation:
            ports: ["5432"]
---
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: allow-postgres-2-from-demo-2
  namespace: istio-egress
spec:
  targetRefs:
    - kind: ServiceEntry
      group: networking.istio.io
      name: postgres-2
  action: ALLOW
  rules:
    - from:
        - source:
            namespaces: ["rds-demo-2"]
      to:
        - operation:
            ports: ["5432"]
```

```bash
kubectl apply -f 05-authz-policies.yaml
```

Because these are ALLOW policies with no other rules, all traffic that **doesn't** match is implicitly denied:

| Source | Destination | Verdict |
|---|---|---|
| rds-demo-1 | postgres-1 | **ALLOW** |
| rds-demo-1 | postgres-2 | **DENY** |
| rds-demo-2 | postgres-2 | **ALLOW** |
| rds-demo-2 | postgres-1 | **DENY** |

## Step 6: Deploy test clients

Deploy a client pod in each namespace to run connectivity tests from:

```bash
kubectl apply -f 06-client-pods.yaml
kubectl -n rds-demo-1 wait pod/client --for=condition=Ready --timeout=60s
kubectl -n rds-demo-2 wait pod/client --for=condition=Ready --timeout=60s
```

## Step 7: Verify

### Allowed paths (should succeed)

```bash
# rds-demo-1 -> postgres-1: ALLOWED
kubectl exec -n rds-demo-1 client -- pg_isready -h $PG1_IP.nip.io -p 5432 -t 3

# rds-demo-2 -> postgres-2: ALLOWED
kubectl exec -n rds-demo-2 client -- pg_isready -h $PG2_IP.nip.io -p 5432 -t 3
```

Expected output: `<host>:5432 - accepting connections`

### Denied paths (should fail)

```bash
# rds-demo-1 -> postgres-2: DENIED
kubectl exec -n rds-demo-1 client -- pg_isready -h $PG2_IP.nip.io -p 5432 -t 3

# rds-demo-2 -> postgres-1: DENIED
kubectl exec -n rds-demo-2 client -- pg_isready -h $PG1_IP.nip.io -p 5432 -t 3
```

Expected output: `<host>:5432 - no response`

### Automated test

Run all four checks at once:

```bash
./run-test.sh test
```

### Inspect egress gateway access logs

Enable access logs on the egress gateway:

```bash
kubectl apply -f 07-telemetry.yaml
```

Watch the logs while running tests:

```bash
kubectl logs -n istio-egress deployment/waypoint -f
```

Allowed connections show `upstream_host` with the real database IP. Denied connections show `rbac_access_denied_matched_policy[none]` in `connection_termination_details`.

---

## How it works

1. Client pods in ambient namespaces have their traffic captured by **ztunnel**
2. Ztunnel sees the destination matches a ServiceEntry with `istio.io/use-waypoint: waypoint`, so it routes through the egress gateway
3. The egress gateway evaluates AuthorizationPolicies that target the specific ServiceEntry for that destination
4. If the policy allows (source namespace matches), it forwards traffic to the real database IP
5. If no ALLOW rule matches, the connection is reset

The key is the `targetRefs` field on the AuthorizationPolicy. By targeting `kind: ServiceEntry` instead of `kind: Gateway`, each policy only applies to traffic destined for that specific external service.

## Cleanup

```bash
./run-test.sh teardown
```

Or manually:

```bash
kubectl delete -f 07-telemetry.yaml
kubectl delete -f 06-client-pods.yaml
kubectl delete -f 05-authz-policies.yaml
kubectl delete serviceentry postgres-1 postgres-2 -n istio-egress
kubectl delete -f 03-egress-waypoint.yaml
kubectl delete -f 02-postgres.yaml
kubectl delete -f 01-namespaces.yaml
```
