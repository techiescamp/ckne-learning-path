# Domain 4: Network Security and Policy (25%)

> **Exam Weight: 25%**: Network policies (L3/L4/L7), node and pod encryption, TLS for Gateway API, pod-level authentication and authorization.

The second of the two heaviest domains. It covers two enforcement layers: the **CNI** (Kubernetes NetworkPolicy and CiliumNetworkPolicy) and the **service mesh** (Istio ambient mTLS and AuthorizationPolicy). Know which layer a task is asking for.

## Index

1. [NetworkPolicy vs CiliumNetworkPolicy](#1-networkpolicy-vs-ciliumnetworkpolicy)
2. [L3 / L4 Policies](#2-l3--l4-policies)
3. [L7 Policies with Cilium](#3-l7-policies-with-cilium)
4. [Node and Pod Encryption with WireGuard](#4-node-and-pod-encryption-with-wireguard)
5. [TLS Certificates for Gateway API](#5-tls-certificates-for-gateway-api)
6. [Pod-level AuthN/AuthZ with Istio Ambient Mesh](#6-pod-level-authnauthz-with-istio-ambient-mesh)
7. [Hands-on Checklist](#7-hands-on-checklist)

---

## 1. NetworkPolicy vs CiliumNetworkPolicy

| | Kubernetes `NetworkPolicy` | `CiliumNetworkPolicy` (CNP) / `CiliumClusterwideNetworkPolicy` (CCNP) |
|--|---------------------------|----------------------------------------------------------------------|
| Scope | Namespaced | Namespaced / cluster-wide |
| Layers | L3/L4 | L3/L4 **and L7** (HTTP, DNS) |
| Selectors | Pod, namespace, ipBlock | Endpoints, entities (`world`, `host`, `kube-apiserver`, `cluster`, ...), CIDR, **FQDN**, services |
| Deny rules | Allow-only | Explicit `ingressDeny` / `egressDeny` (deny wins) |
| Node policies | No | Yes (CCNP with `nodeSelector`) |

**Shared semantics:** a pod is non-isolated until some policy selects it for a direction. Once selected, only traffic that some policy allows gets through, and all policies selecting it are additive.

```bash
kubectl get netpol,cnp -A
kubectl get ccnp
kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
```

---

## 2. L3 / L4 Policies

### Default deny for a namespace

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: default-deny
  namespace: shop
spec:
  podSelector: {}
  policyTypes: ["Ingress", "Egress"]
```

> [!WARNING]
> Default-deny egress also blocks DNS. Pair it with an allow to `kube-dns` on UDP and TCP 53, or every name lookup will time out.

### Allow selected workloads on specific ports (Kubernetes)

```yaml
apiVersion: networking.k8s.io/v1
kind: NetworkPolicy
metadata:
  name: api-from-frontend
  namespace: shop
spec:
  podSelector:
    matchLabels:
      app: api
  policyTypes: ["Ingress"]
  ingress:
  - from:
    - podSelector:
        matchLabels:
          app: frontend
    - namespaceSelector:
        matchLabels:
          kubernetes.io/metadata.name: monitoring
    ports:
    - protocol: TCP
      port: 8080
```

`namespaceSelector` and `podSelector` in the **same** list item mean AND (that label in that namespace). As **separate** items they mean OR.

### The same idea in Cilium, plus DNS and FQDN egress

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-policy
  namespace: shop
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
  egress:
  - toEndpoints:
    - matchLabels:
        k8s:io.kubernetes.pod.namespace: kube-system
        k8s:k8s-app: kube-dns
    toPorts:
    - ports:
      - port: "53"
        protocol: ANY
      rules:
        dns:
        - matchPattern: "*"
  - toFQDNs:
    - matchName: api.partner.example.com
    toPorts:
    - ports:
      - port: "443"
        protocol: TCP
  - toEntities:
    - kube-apiserver
```

`toFQDNs` only works when the DNS rule above is present, because Cilium learns IPs from DNS responses it proxies.

### Explicit deny

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: block-legacy
  namespace: shop
spec:
  endpointSelector: {}
  egress:
  - toEntities:
    - all
  egressDeny:
  - toCIDR:
    - 10.200.0.0/16
```

Like allow policies, a deny policy puts the selected pods into default-deny for that direction, so pair it with an allow (here `toEntities: all`) or everything else is blocked too. Deny rules do not support L7 rules or `toFQDNs`.

Reference: [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) | [Cilium L3 Policy](https://docs.cilium.io/en/stable/security/policy/layer3/)

---

## 3. L7 Policies with Cilium

Adding `rules.http` to a `toPorts` block sends that traffic through Cilium's Envoy proxy. Only matching requests are allowed. Everything else on that port gets **HTTP 403 Access denied** (not a dropped connection).

```yaml
apiVersion: cilium.io/v2
kind: CiliumNetworkPolicy
metadata:
  name: api-l7
  namespace: shop
spec:
  endpointSelector:
    matchLabels:
      app: api
  ingress:
  - fromEndpoints:
    - matchLabels:
        app: frontend
    toPorts:
    - ports:
      - port: "8080"
        protocol: TCP
      rules:
        http:
        - method: GET
          path: "/products(/.*)?"
        - method: POST
          path: "/cart"
          headers:
          - "X-Session: .+"
```

```bash
kubectl -n shop exec deploy/frontend -- curl -s -o /dev/null -w '%{http_code}\n' api:8080/products
kubectl -n shop exec deploy/frontend -- curl -s -o /dev/null -w '%{http_code}\n' api:8080/admin
hubble observe -n shop --protocol http --verdict DROPPED
```

| Result | Meaning |
|--------|---------|
| Timeout | L3/L4 drop: no rule allows the identity or port |
| `403 Access denied` | L4 allowed, L7 rule did not match (method, path or header) |
| Works for one path only | Path regex anchored or too narrow |

Reference: [Cilium Layer 7 Policy](https://docs.cilium.io/en/stable/security/policy/layer7/)

---

## 4. Node and Pod Encryption with WireGuard

Cilium can encrypt all pod-to-pod traffic **between nodes** with WireGuard. Each node gets a key pair, publishes its public key on its `CiliumNode`, and tunnels traffic over `cilium_wg0` (UDP 51871). Same-node traffic does not leave the host and is not encrypted.

```bash
# New install
cilium install --set encryption.enabled=true --set encryption.type=wireguard

# Existing install
cilium upgrade --reuse-values --set encryption.enabled=true --set encryption.type=wireguard
kubectl -n kube-system rollout restart ds/cilium

# Also encrypt node-to-node (host) traffic, not just pod traffic
cilium upgrade --reuse-values --set encryption.nodeEncryption=true
```

### Verify encryption is active

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep Encryption
#   Encryption: Wireguard [cilium_wg0 (Pubkey: ..., Port: 51871, Peers: 2)]

kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status
cilium config view | grep -i -E "enable-wireguard|encrypt"

# Prove it on the wire (from a node): cross-node pod traffic shows up only as UDP 51871
tcpdump -i eth0 -nn udp port 51871 -c 10
# Plaintext inner traffic is only visible on the WireGuard device
tcpdump -i cilium_wg0 -nn -c 10
```

> [!NOTE]
> `Peers` should equal the number of other nodes. A peer count of 0, or traffic to TCP/80 visible in plaintext on `eth0`, means encryption is not in effect for that path. If large requests hang after enabling it, check the MTU. `cilium-dbg debuginfo --output json | jq .encryption` shows the full encryption state.

IPsec (`encryption.type=ipsec`, with a pre-shared key Secret) is the alternative mode. Pod-to-pod mTLS at the mesh layer is covered under Istio below.

Reference: [Cilium WireGuard Encryption](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)

---

## 5. TLS Certificates for Gateway API

### Create the certificate Secret

```bash
# Self-signed for practice
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt -subj "/CN=shop.example.com" \
  -addext "subjectAltName=DNS:shop.example.com"

kubectl -n web create secret tls shop-tls --cert=tls.crt --key=tls.key
```

When a task provides the cert and key files, use them as given.

### Issuing certificates with cert-manager

cert-manager can create and renew the Secret for you. Either request it explicitly with a `Certificate`, or annotate the Gateway and let cert-manager create one Certificate per unique Secret name in `certificateRefs`. The listener needs a `hostname`, `tls.mode: Terminate` and a Secret in the same namespace. Gateway API support must be on (Helm value `config.gatewayAPI.enabled=true`), and the Gateway API CRDs must exist before cert-manager starts, or cert-manager must be restarted.

```yaml
apiVersion: cert-manager.io/v1
kind: ClusterIssuer
metadata:
  name: selfsigned
spec:
  selfSigned: {}
---
# Option A: explicit Certificate → Secret shop-tls
apiVersion: cert-manager.io/v1
kind: Certificate
metadata:
  name: shop-cert
  namespace: web
spec:
  secretName: shop-tls
  dnsNames:
  - shop.example.com
  issuerRef:
    kind: ClusterIssuer
    name: selfsigned
```

```yaml
# Option B: annotate the Gateway; cert-manager fills the Secret named in certificateRefs
metadata:
  name: web-gw
  namespace: web
  annotations:
    cert-manager.io/cluster-issuer: selfsigned
```

```bash
kubectl -n web get certificate,certificaterequest
kubectl -n web describe certificate shop-cert
kubectl -n cert-manager logs deploy/cert-manager
```

### HTTPS listener (TLS termination)

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gw
  namespace: web
spec:
  gatewayClassName: eg
  listeners:
  - name: https
    protocol: HTTPS
    port: 443
    hostname: shop.example.com
    tls:
      mode: Terminate
      certificateRefs:
      - kind: Secret
        name: shop-tls
        # namespace: certs
  - name: http
    protocol: HTTP
    port: 80
    hostname: shop.example.com
---
# Redirect HTTP → HTTPS
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: https-redirect
  namespace: web
spec:
  parentRefs:
  - name: web-gw
    sectionName: http
  rules:
  - filters:
    - type: RequestRedirect
      requestRedirect:
        scheme: https
        statusCode: 301
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: web
spec:
  parentRefs:
  - name: web-gw
    sectionName: https
  hostnames: ["shop.example.com"]
  rules:
  - backendRefs:
    - name: shop
      port: 80
```

### Certificates in another namespace

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: ReferenceGrant
metadata:
  name: allow-web-gateway
  namespace: certs
spec:
  from:
  - group: gateway.networking.k8s.io
    kind: Gateway
    namespace: web
  to:
  - group: ""
    kind: Secret
```

`TLSRoute` with `mode: Passthrough` hands the encrypted stream to the backend untouched. `BackendTLSPolicy` makes the gateway re-encrypt traffic to the backend.

### Verify and troubleshoot

```bash
GW_IP=$(kubectl -n web get gateway web-gw -o jsonpath='{.status.addresses[0].value}')

curl -vk --resolve shop.example.com:443:$GW_IP https://shop.example.com/
curl -v --cacert tls.crt --resolve shop.example.com:443:$GW_IP https://shop.example.com/

openssl s_client -connect $GW_IP:443 -servername shop.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -issuer -dates -ext subjectAltName

kubectl -n web describe gateway web-gw
```

| Condition / symptom | Cause |
|---------------------|-------|
| Listener `ResolvedRefs=False`, `InvalidCertificateRef` | Secret missing, wrong name, or not type `kubernetes.io/tls` |
| Listener `ResolvedRefs=False`, `RefNotPermitted` | Cross-namespace Secret without a ReferenceGrant |
| Wrong cert served | SNI hostname does not match the listener `hostname` (always pass `-servername` / `--resolve`) |
| `certificate has expired` / name mismatch | Check `-dates` and `subjectAltName` from `openssl x509` |

Reference: [Gateway API TLS](https://gateway-api.sigs.k8s.io/guides/tls/)

---

## 6. Pod-level AuthN/AuthZ with Istio Ambient Mesh

### Ambient architecture

| Component | Layer | Role |
|-----------|-------|------|
| **ztunnel** (DaemonSet) | L4 | Transparent mTLS (HBONE) between mesh pods, SPIFFE identity per ServiceAccount, L4 AuthorizationPolicy |
| **waypoint** (Envoy Deployment, per namespace or service) | L7 | HTTP routing, L7 AuthorizationPolicy, retries, telemetry |
| istio-cni | node | Redirects pod traffic into ztunnel without sidecars |

```text
client pod ─► ztunnel(node A) ══mTLS/HBONE══► [waypoint, if L7] ══► ztunnel(node B) ─► server pod
```

### Install and enroll workloads

```bash
istioctl install --set profile=ambient --skip-confirmation
kubectl get pods -n istio-system

# Put a namespace in the mesh (no restarts needed)
kubectl label namespace shop istio.io/dataplane-mode=ambient

# Take one pod out of the mesh
kubectl label pod <pod> istio.io/dataplane-mode=none

# Add a waypoint for L7 features and enroll the namespace to use it
istioctl waypoint apply -n shop --enroll-namespace --wait
istioctl waypoint list -n shop

# Which workloads are in the mesh, and with what protocol?
istioctl ztunnel-config workloads
```

> [!NOTE]
> **Running ambient on Cilium:** install Cilium with `cni.exclusive=false`, and with kube-proxy replacement also `socketLB.hostNamespaceOnly=true`. `bpf.masquerade=true` is not supported with ambient. If you use Cilium default-deny policies, allow ingress from `169.254.7.127/32`, the link-local address Istio SNATs kubelet health probes to.

### Mesh vs non-mesh workloads

| Client | Server | Default (PERMISSIVE) | With `STRICT` |
|--------|--------|----------------------|---------------|
| mesh | mesh | mTLS | mTLS |
| non-mesh | mesh | plaintext accepted | **rejected** |
| mesh | non-mesh | plaintext | plaintext |

```yaml
# Refuse plaintext (non-mesh) clients for every workload in the namespace
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict
  namespace: shop
spec:
  mtls:
    mode: STRICT
```

### L4 AuthorizationPolicy (enforced by ztunnel)

Uses `selector`. Only L4 attributes are available: source principals and namespaces, IPs and ports.

> [!WARNING]
> When a waypoint is in the path, the destination ztunnel sees the **waypoint's** identity, not the original client's. A ztunnel policy must then also allow `cluster.local/ns/<ns>/sa/waypoint`, or enforce the client identity at the waypoint with `targetRefs` instead.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-allow-frontend
  namespace: shop
spec:
  selector:
    matchLabels:
      app: api
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/shop/sa/frontend"]
    to:
    - operation:
        ports: ["8080"]
```

### L7 AuthorizationPolicy (enforced by the waypoint)

Uses `targetRefs` pointing at the Service (or the waypoint Gateway). HTTP attributes such as methods, paths and headers are only available here.

```yaml
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-l7
  namespace: shop
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: api
  action: ALLOW
  rules:
  - from:
    - source:
        principals: ["cluster.local/ns/shop/sa/frontend"]
    to:
    - operation:
        methods: ["GET"]
        paths: ["/products", "/products/*"]
---
# Explicit deny for an endpoint, evaluated before ALLOW
apiVersion: security.istio.io/v1
kind: AuthorizationPolicy
metadata:
  name: api-deny-admin
  namespace: shop
spec:
  targetRefs:
  - kind: Service
    group: ""
    name: api
  action: DENY
  rules:
  - to:
    - operation:
        paths: ["/admin*"]
```

**Evaluation order:** CUSTOM → DENY → ALLOW. If any ALLOW policy targets a workload, requests that match none of its rules are denied.

### Troubleshooting authorization failures

```bash
# Who is the client, as the mesh sees it?
kubectl -n shop get pod <client> -o jsonpath='{.spec.serviceAccountName}'

istioctl ztunnel-config workloads | grep shop
kubectl -n istio-system logs -l app=ztunnel | grep -i -E "policy rejection|denied"
kubectl -n shop logs deploy/waypoint | grep -i rbac
kubectl -n shop get svc api --show-labels
istioctl analyze -n shop
```

| Symptom | Layer / cause |
|---------|---------------|
| `RBAC: access denied` (HTTP 403) | L7 policy at the waypoint denied it |
| `Connection reset` / `recv failure` | L4 policy at ztunnel denied it, or STRICT mTLS rejected a non-mesh client |
| L7 policy has no effect | No waypoint, or the Service is not using it (`istio.io/use-waypoint`) |
| L7 ALLOW via `selector` blocks everything | ztunnel cannot evaluate L7, so the rule is skipped and all traffic is denied (connection reset). Use `targetRefs` |
| L7-only DENY via `selector` does nothing | ztunnel skips the L7 rule. Use `targetRefs` |
| Principal never matches | Wrong ServiceAccount or namespace in `cluster.local/ns/<ns>/sa/<sa>` |
| Non-mesh client still gets through | PeerAuthentication not `STRICT`, or target namespace not labelled ambient |

Reference: [Istio Ambient Mode](https://istio.io/latest/docs/ambient/) | [Istio Authorization Policy](https://istio.io/latest/docs/reference/config/security/authorization-policy/)

---

## 7. Hands-on Checklist

- [ ] Explain when to use a Kubernetes NetworkPolicy vs a CiliumNetworkPolicy
- [ ] Build default-deny for a namespace and re-open only DNS and one app port
- [ ] Allow traffic between selected workloads only, and deny everything else
- [ ] Restrict a pod's egress to one external FQDN
- [ ] Allow only specific HTTP methods/paths with a Cilium L7 rule, and explain the 403 vs timeout difference
- [ ] Enable WireGuard and prove from the agent status and `tcpdump` that cross-node traffic is encrypted
- [ ] Serve HTTPS from a Gateway with a provided certificate, including a cross-namespace Secret
- [ ] Issue a Gateway certificate with cert-manager and confirm the Certificate is Ready
- [ ] Verify the served certificate with `openssl s_client` and `curl --resolve`
- [ ] Enroll a namespace in Istio ambient and confirm ztunnel sees it
- [ ] Block non-mesh workloads from reaching mesh services
- [ ] Write L4 (ztunnel) and L7 (waypoint) AuthorizationPolicies and know which one a task needs
- [ ] Restrict access to a specific application endpoint by path and method
- [ ] Debug a denied request from ztunnel / waypoint logs
