# Domain 4: Network Security and Policy (25%)

> **Exam Weight: 25%**: This domain covers network policies at L3, L4 and L7, encryption of node and pod traffic, TLS for the Gateway API, and authentication and authorization between pods.

This is one of the two heaviest domains in the exam. It covers two different layers that can enforce security. The first is the **CNI**, which enforces Kubernetes NetworkPolicy and CiliumNetworkPolicy. The second is the **service mesh**, which uses Istio ambient mTLS and AuthorizationPolicy. Before you start a task, work out which of these two layers it is asking about, because each layer uses different resources and different debugging tools.

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

Kubernetes has a built-in NetworkPolicy resource, and Cilium adds its own policy types on top of it with more features. The table below shows how they differ.

| | Kubernetes `NetworkPolicy` | `CiliumNetworkPolicy` (CNP) / `CiliumClusterwideNetworkPolicy` (CCNP) |
|--|---------------------------|----------------------------------------------------------------------|
| Scope | Namespaced only | Namespaced (CNP) or cluster-wide (CCNP) |
| Layers | L3 and L4 only | L3/L4 **and L7** (HTTP, DNS) |
| Selectors | Pods, namespaces and ipBlock | Endpoints, entities (`world`, `host`, `kube-apiserver`, `cluster`, ...), CIDR ranges, **FQDN** names and services |
| Deny rules | Allow rules only, no deny | Explicit `ingressDeny` / `egressDeny` rules, and a deny always wins over an allow |
| Node policies | Not supported | Supported through a CCNP with `nodeSelector` |

**Shared semantics:** Both policy types follow the same basic model. A pod accepts all traffic in a direction (ingress or egress) until at least one policy selects it for that direction. Once a policy selects it, the pod only accepts traffic that some policy explicitly allows. If several policies select the same pod, their rules add up, so traffic gets through if any one of them allows it.

Use these commands to list the policies in the cluster and to see which policies and endpoints the Cilium agent knows about.

```bash
kubectl get netpol,cnp -A
kubectl get ccnp
kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
```

---

## 2. L3 / L4 Policies

### Default deny for a namespace

This policy selects every pod in the namespace (`podSelector: {}`) and lists both directions, so all ingress and egress traffic is blocked until another policy allows it.

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
> A default-deny egress policy also blocks DNS, because DNS queries are egress traffic to `kube-dns`. Always pair it with a rule that allows egress to `kube-dns` on UDP and TCP port 53. Otherwise, every name lookup in the namespace will time out.

### Allow selected workloads on specific ports (Kubernetes)

This policy allows ingress to the `api` pods on TCP port 8080, either from `frontend` pods in the same namespace or from any pod in the `monitoring` namespace.

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

Be careful with how you group selectors. If `namespaceSelector` and `podSelector` are in the **same** list item, they are combined with AND, which means only pods with that label in that namespace are allowed. If they are **separate** items, as in the example above, they are combined with OR, so a match on either one is enough.

### The same idea in Cilium, plus DNS and FQDN egress

The CiliumNetworkPolicy below gives the `api` pods the same ingress rule. It also limits their egress to three destinations: DNS on `kube-dns`, one external name through `toFQDNs`, and the Kubernetes API server.

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

Note that `toFQDNs` only works when the DNS rule above is also present. Cilium learns which IPs belong to a name by proxying the pod's DNS queries and reading the responses, so without the DNS rule it never sees those responses and cannot allow the IPs.

### Explicit deny

This policy blocks egress from every pod in the namespace to `10.200.0.0/16`.

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

Deny rules always win over allow rules. But Cilium puts a pod into default-deny as soon as any policy selects it, so a deny rule on its own would block more than you want. That is why this example pairs the deny with a broad allow (`toEntities: all`). Without the allow, all other egress traffic would be blocked too. Also note that deny rules cannot use L7 rules or `toFQDNs`.

Reference: [Network Policies](https://kubernetes.io/docs/concepts/services-networking/network-policies/) | [Cilium L3 Policy](https://docs.cilium.io/en/stable/security/policy/layer3/)

---

## 3. L7 Policies with Cilium

When you add `rules.http` to a `toPorts` block, Cilium sends the traffic on that port through its Envoy proxy. The proxy checks each HTTP request, and only requests that match a rule are allowed. Every other request on that port gets an **HTTP 403 Access denied** response. The connection is not dropped, so you can tell an L7 denial apart from an L3/L4 one.

The `method` and `path` values are regular expressions. A plain entry under `headers` (like `X-Session` below) only requires that the header is present. To require a value, write it as `Name: value`.

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
          - "X-Session"
```

To test the policy, send requests from the frontend and watch for drops with Hubble. With the policy above, the request to `/products` should succeed and the request to `/admin` should return 403.

```bash
kubectl -n shop exec deploy/frontend -- curl -s -o /dev/null -w '%{http_code}\n' api:8080/products
kubectl -n shop exec deploy/frontend -- curl -s -o /dev/null -w '%{http_code}\n' api:8080/admin
hubble observe -n shop --protocol http --verdict DROPPED
```

The result of a test request tells you which layer blocked it:

| Result | Meaning |
|--------|---------|
| Timeout | L3/L4 drop: no rule allows this identity or port |
| `403 Access denied` | The L4 rule allowed the connection, but no L7 rule matched the method, path or header |
| Works for one path only | The path regex is anchored or too narrow |

Reference: [Cilium Layer 7 Policy](https://docs.cilium.io/en/stable/security/policy/layer7/)

---

## 4. Node and Pod Encryption with WireGuard

Cilium can use WireGuard to encrypt all pod-to-pod traffic that travels **between nodes**. Each node generates a key pair and publishes its public key on its `CiliumNode` object, so that the other nodes can find it. Traffic to other nodes then goes through the `cilium_wg0` tunnel on UDP port 51871. Traffic between pods on the same node never leaves the host, so it is not encrypted.

```bash
# New install
cilium install --set encryption.enabled=true --set encryption.type=wireguard

# Existing install
cilium upgrade --reuse-values --set encryption.enabled=true --set encryption.type=wireguard
kubectl -n kube-system rollout restart ds/cilium

# Also encrypt node-to-node (host) traffic, not just pod traffic (beta feature)
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
> In the status output, `Peers` should equal the number of other nodes in the cluster. If the peer count is 0, or if you can see traffic to TCP/80 in plaintext on `eth0`, encryption is not in effect for that path. If large requests hang after you enable encryption, check the MTU. To see the full encryption state, run `cilium-dbg debuginfo --output json | jq .encryption`.

WireGuard is not the only option. Cilium also supports IPsec (`encryption.type=ipsec`), which uses a pre-shared key stored in a Secret. Encryption at the mesh layer, in the form of pod-to-pod mTLS, is covered in the Istio section below.

Reference: [Cilium WireGuard Encryption](https://docs.cilium.io/en/stable/security/network/encryption-wireguard/)

---

## 5. TLS Certificates for Gateway API

### Create the certificate Secret

The Gateway reads its certificate from a Secret of type `kubernetes.io/tls`. For practice, you can create a self-signed certificate with `openssl` and store it in a Secret.

```bash
# Self-signed for practice
openssl req -x509 -nodes -days 365 -newkey rsa:2048 \
  -keyout tls.key -out tls.crt -subj "/CN=shop.example.com" \
  -addext "subjectAltName=DNS:shop.example.com"

kubectl -n web create secret tls shop-tls --cert=tls.crt --key=tls.key
```

If a task gives you the certificate and key files, use them exactly as given instead of generating your own.

### Issuing certificates with cert-manager

Instead of creating the Secret by hand, you can let cert-manager create and renew it for you. There are two ways to do this:

- **Option A:** request the certificate with a `Certificate` resource.
- **Option B:** annotate the Gateway. Then cert-manager creates one Certificate for each unique Secret name in `certificateRefs`.

Option B has a few rules. The listener needs a `hostname` and `tls.mode: Terminate`, and the Secret must be in the same namespace as the Gateway. You also have to turn on Gateway API support in cert-manager with the Helm value `config.gatewayAPI.enabled=true`. Finally, the Gateway API CRDs must exist before cert-manager starts. If you install them later, restart cert-manager so it picks them up.

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

The Gateway below terminates TLS on port 443 with the `shop-tls` Secret. It also has an HTTP listener on port 80, which is used only to redirect clients to HTTPS. Each HTTPRoute attaches to one of the listeners through `sectionName`.

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

If the Secret lives in a different namespace from the Gateway (here `certs`), the Secret's namespace must allow the reference with a ReferenceGrant. Otherwise, the listener reports `RefNotPermitted`.

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

Two related options are also worth knowing. A listener with `tls.mode: Passthrough` and a `TLSRoute` does not terminate TLS at the gateway. It hands the encrypted stream to the backend untouched. A `BackendTLSPolicy` does the opposite job: it makes the gateway use TLS again when it connects to the backend.

### Verify and troubleshoot

To test the listener, get the Gateway address and send requests with the correct hostname. Use `--resolve` so that curl sends the right SNI name, and use `openssl s_client` to inspect the certificate that is actually served.

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
| Listener `ResolvedRefs=False`, `InvalidCertificateRef` | The Secret is missing, has the wrong name, or is not of type `kubernetes.io/tls` |
| Listener `ResolvedRefs=False`, `RefNotPermitted` | The Secret is in another namespace and there is no ReferenceGrant for it |
| Wrong cert served | The SNI hostname does not match the listener `hostname`, so always pass `-servername` / `--resolve` |
| `certificate has expired` / name mismatch | Check `-dates` and `subjectAltName` in the `openssl x509` output |

Reference: [Gateway API TLS](https://gateway-api.sigs.k8s.io/guides/tls/)

---

## 6. Pod-level AuthN/AuthZ with Istio Ambient Mesh

### Ambient architecture

Ambient mode splits the mesh into two layers. Every mesh pod gets L4 features from ztunnel, and only traffic that needs L7 features is sent through a waypoint.

| Component | Layer | Role |
|-----------|-------|------|
| **ztunnel** (DaemonSet) | L4 | Provides transparent mTLS (HBONE) between mesh pods, gives each ServiceAccount a SPIFFE identity, and enforces L4 AuthorizationPolicy |
| **waypoint** (Envoy Deployment, per namespace or service) | L7 | Handles HTTP routing, L7 AuthorizationPolicy, retries and telemetry |
| istio-cni | node | Redirects pod traffic into ztunnel, so no sidecars are needed |

```text
client pod ─► ztunnel(node A) ══mTLS/HBONE══► [waypoint, if L7] ══► ztunnel(node B) ─► server pod
```

### Install and enroll workloads

Install Istio with the ambient profile, then add workloads to the mesh by labelling their namespace. Because there is no sidecar to inject, the pods do not need to restart.

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
> **Running ambient on Cilium:** Cilium has to share the node with istio-cni, so install it with `cni.exclusive=false`. If you also use kube-proxy replacement, set `socketLB.hostNamespaceOnly=true` as well. Note that `bpf.masquerade=true` is not supported with ambient. If you use Cilium default-deny policies, allow ingress from `169.254.7.127/32`, because Istio SNATs kubelet health probes to that link-local address and the probes would otherwise be blocked.

### Mesh vs non-mesh workloads

Whether traffic is encrypted depends on whether both sides are in the mesh and on the mTLS mode of the server:

| Client | Server | Default (PERMISSIVE) | With `STRICT` |
|--------|--------|----------------------|---------------|
| mesh | mesh | mTLS | mTLS |
| non-mesh | mesh | plaintext accepted | **rejected** |
| mesh | non-mesh | plaintext | plaintext |

To stop non-mesh clients from reaching mesh workloads, set the mode to `STRICT` with a PeerAuthentication.

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

An L4 policy uses `selector` to choose the workloads it applies to. Because ztunnel only works at L4, the policy can only match L4 attributes: source principals and namespaces, IP addresses and ports.

> [!WARNING]
> When a waypoint is in the path, the destination ztunnel sees the **waypoint's** identity, not the original client's. A waypoint uses the service account named after its Gateway. So a ztunnel policy must also allow that identity, which is `cluster.local/ns/<ns>/sa/waypoint` for the default waypoint. The other option is to check the client identity at the waypoint by using `targetRefs`.

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

An L7 policy uses `targetRefs` to point at the Service (or at the waypoint Gateway) instead of using `selector`. HTTP attributes such as methods, paths and headers are only available at this layer, because the waypoint is the component that handles HTTP.

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

**Evaluation order:** Istio evaluates CUSTOM policies first, then DENY, then ALLOW. Keep in mind that once any ALLOW policy targets a workload, every request that matches none of its rules is denied.

### Troubleshooting authorization failures

When a request is denied, first find out which identity the client has, and then check which layer rejected the request.

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
| `RBAC: access denied` (HTTP 403) | An L7 policy at the waypoint denied the request |
| `Connection reset` / `recv failure` | An L4 policy at ztunnel denied it, or STRICT mTLS rejected a non-mesh client |
| L7 policy has no effect | There is no waypoint, or the Service is not using it (check `istio.io/use-waypoint`) |
| L7 ALLOW via `selector` blocks everything | ztunnel cannot evaluate L7 rules, so it skips the rule and denies all traffic (connection reset). Use `targetRefs` instead |
| L7-only DENY via `selector` does nothing | ztunnel skips the L7 rule, so nothing is denied. Use `targetRefs` instead |
| Principal never matches | The ServiceAccount or namespace in `cluster.local/ns/<ns>/sa/<sa>` is wrong |
| Non-mesh client still gets through | PeerAuthentication is not `STRICT`, or the target namespace is not labelled for ambient |

Reference: [Istio Ambient Mode](https://istio.io/latest/docs/ambient/) | [Istio Authorization Policy](https://istio.io/latest/docs/reference/config/security/authorization-policy/)

---

## 7. Hands-on Checklist

Before you move on, make sure you can do each of these tasks on a real cluster:

- [ ] Explain when a Kubernetes NetworkPolicy is enough and when you need a CiliumNetworkPolicy
- [ ] Create a default-deny policy for a namespace, then open only DNS and one application port
- [ ] Allow traffic only between selected workloads and deny everything else
- [ ] Restrict a pod's egress so that it can reach only one external FQDN
- [ ] Allow only specific HTTP methods and paths with a Cilium L7 rule, and explain why a blocked request sometimes returns 403 and sometimes times out
- [ ] Enable WireGuard, then use the agent status and `tcpdump` to prove that cross-node traffic is encrypted
- [ ] Serve HTTPS from a Gateway with a certificate you are given, including one stored in a Secret in another namespace
- [ ] Issue a Gateway certificate with cert-manager and confirm that the Certificate becomes Ready
- [ ] Check the certificate the Gateway serves with `openssl s_client` and `curl --resolve`
- [ ] Enroll a namespace in Istio ambient mode and confirm that ztunnel sees its workloads
- [ ] Block workloads outside the mesh from reaching services inside the mesh
- [ ] Write both an L4 (ztunnel) and an L7 (waypoint) AuthorizationPolicy, and decide which one a task needs
- [ ] Restrict access to a specific application endpoint by path and method
- [ ] Debug a denied request using the ztunnel and waypoint logs
