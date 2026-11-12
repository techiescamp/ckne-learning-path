# Domain 2: Service Networking and DNS (25%)

> **Exam Weight: 25%**: L4 Services, kube-proxy and its alternatives, CoreDNS, endpoint health, Gateway API.

This is one of the two heaviest domains. Expect to expose workloads, route HTTP through a Gateway, and fix services that look fine but send traffic nowhere.

## Index

1. [L4 Services](#1-l4-services)
2. [LoadBalancer IPs with MetalLB](#2-loadbalancer-ips-with-metallb)
3. [Reaching External Services from Pods](#3-reaching-external-services-from-pods)
4. [kube-proxy and CNI Alternatives](#4-kube-proxy-and-cni-alternatives)
5. [Customizing CoreDNS](#5-customizing-coredns)
6. [Pod Endpoint Availability](#6-pod-endpoint-availability)
7. [Gateway API](#7-gateway-api)
8. [Troubleshooting Service Network Traffic](#8-troubleshooting-service-network-traffic)
9. [Hands-on Checklist](#9-hands-on-checklist)

---

## 1. L4 Services

| Type | Reachable from | Notes |
|------|----------------|-------|
| `ClusterIP` | Inside the cluster | Default |
| `NodePort` | `<anyNodeIP>:30000-32767` | Builds on ClusterIP |
| `LoadBalancer` | External IP from a LB implementation (cloud, MetalLB, Cilium LB-IPAM) | Builds on NodePort unless `allocateLoadBalancerNodePorts: false` |
| `ExternalName` | DNS CNAME only, no proxying | No endpoints |
| Headless (`clusterIP: None`) | DNS returns pod IPs directly | Used by StatefulSets |

```yaml
apiVersion: v1
kind: Service
metadata:
  name: web
spec:
  type: LoadBalancer
  selector:
    app: web
  ports:
  - name: http
    protocol: TCP
    port: 80
    targetPort: 8080
  externalTrafficPolicy: Local
  sessionAffinity: ClientIP
```

| Field | Effect |
|-------|--------|
| `externalTrafficPolicy: Cluster` | Any node forwards. Client IP is SNATed (lost) |
| `externalTrafficPolicy: Local` | Client IP preserved. Nodes without a local endpoint fail health checks |
| `internalTrafficPolicy: Local` | In-cluster clients only reach endpoints on their own node |
| `trafficDistribution: PreferSameZone` | Prefer endpoints in the client's zone (`PreferClose` is the deprecated alias) |
| `trafficDistribution: PreferSameNode` | Prefer endpoints on the client's own node |

Reference: [Service](https://kubernetes.io/docs/concepts/services-networking/service/)

---

## 2. LoadBalancer IPs with MetalLB

On bare metal and kind, `LoadBalancer` Services stay `<pending>` until something allocates IPs.

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.2/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Ready pod -l app=metallb --timeout=120s
```

```yaml
apiVersion: metallb.io/v1beta1
kind: IPAddressPool
metadata:
  name: lab-pool
  namespace: metallb-system
spec:
  addresses:
  - 172.18.255.200-172.18.255.250
---
# Layer 2 mode: one node answers ARP for the IP
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - lab-pool
```

MetalLB can also announce over BGP using `BGPPeer` and `BGPAdvertisement`. The BGP concepts are covered with Cilium BGP in Domain 3.

```bash
kubectl get svc web
kubectl describe svc web | grep -A5 Events
kubectl -n metallb-system logs -l component=speaker
```

> [!NOTE]
> Cilium can do the same thing natively with `CiliumLoadBalancerIPPool` plus `l2announcements.enabled=true` or BGP. Do not run two LB IP allocators on the same Services.

Reference: [MetalLB Configuration](https://metallb.universe.tf/configuration/)

---

## 3. Reaching External Services from Pods

### Give an external endpoint a cluster name

A Service **without a selector** plus a hand-written EndpointSlice points a stable in-cluster name at an external IP:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: legacy-db
spec:
  ports:
  - name: pg
    port: 5432
    targetPort: 5432
---
apiVersion: discovery.k8s.io/v1
kind: EndpointSlice
metadata:
  name: legacy-db-1
  labels:
    kubernetes.io/service-name: legacy-db
addressType: IPv4
ports:
- name: pg
  port: 5432
  protocol: TCP
endpoints:
- addresses:
  - 192.168.10.50
```

For a DNS name rather than an IP, use `type: ExternalName` with `externalName: db.example.com`.

### What happens to the source IP

Pod → external traffic leaves the node with the **node IP** as its source (masquerading, see Domain 1). If the external side allow-lists source IPs, you need either a predictable node or an Egress Gateway (Domain 3).

```bash
# What source IP does the outside world see?
kubectl exec <pod> -- curl -s http://<external-echo-server>/ip

# Is the route out of the node correct?
ip route get <external-ip>
```

Common failures: no route from the node, `ip_forward=0`, a NetworkPolicy without an egress allow, masquerading disabled for that destination, or DNS for the external name failing (see CoreDNS below).

---

## 4. kube-proxy and CNI Alternatives

| Implementation | How Services are programmed | Where to look |
|----------------|-----------------------------|---------------|
| kube-proxy `iptables` | `KUBE-SERVICES` → `KUBE-SVC-*` → `KUBE-SEP-*` DNAT chains | `iptables-save -t nat` |
| kube-proxy `ipvs` (deprecated since v1.35) | IPVS virtual servers on `kube-ipvs0` | `ipvsadm -Ln` |
| kube-proxy `nftables` | nftables `kube-proxy` table | `nft list table ip kube-proxy` |
| Cilium KPR | eBPF maps | `cilium-dbg service list`, `cilium-dbg bpf lb list` |
| kube-router | IPVS (service proxy) + GoBGP (routing) + iptables/ipset (policy) | `ipvsadm -Ln`, `gobgp neighbor` |

```bash
# Which mode is kube-proxy running in?
kubectl -n kube-system get cm kube-proxy -o yaml | grep mode
kubectl -n kube-system logs ds/kube-proxy | grep -i "using"
```

### kube-router

kube-router runs as a DaemonSet and can replace kube-proxy (`--run-service-proxy=true`), act as the pod router (`--run-router=true`) and enforce NetworkPolicy (`--run-firewall=true`). It peers with upstream routers over BGP to advertise pod CIDRs and Service IPs.

```text
--run-router=true --run-firewall=true --run-service-proxy=true
--cluster-asn=64512
--peer-router-ips=172.18.0.100 --peer-router-asns=65000
--advertise-cluster-ip=true --advertise-external-ip=true --advertise-loadbalancer-ip=true
```

```bash
kubectl -n kube-system exec ds/kube-router -- gobgp neighbor
kubectl -n kube-system exec ds/kube-router -- gobgp global rib
kubectl -n kube-system exec ds/kube-router -- ipvsadm -Ln
```

Per-service options are set with annotations, for example `kube-router.io/service.scheduler: lc` (least connection).

Reference: [kube-router User Guide](https://www.kube-router.io/docs/user-guide/)

---

## 5. Customizing CoreDNS

CoreDNS is configured by the `coredns` ConfigMap in `kube-system`. Allow up to about 2 minutes for an edit to take effect: the kubelet has to sync the ConfigMap, and `reload` checks every 30s (±15s jitter). A rollout restart applies it immediately.

```text
.:53 {
    errors
    health {
       lameduck 5s
    }
    ready
    kubernetes cluster.local in-addr.arpa ip6.arpa {
       pods insecure
       fallthrough in-addr.arpa ip6.arpa
       ttl 30
    }
    prometheus :9153
    forward . /etc/resolv.conf {
       max_concurrent 1000
    }
    cache 30 {
       disable success cluster.local
       disable denial cluster.local
    }
    loop
    reload
    loadbalance
}
```

### Common customizations

```text
# 1. Send ALL external lookups to a specific DNS server instead of the node's resolver
    forward . 10.0.0.53 10.0.0.54

# 2. Send ONE domain to a dedicated DNS server (separate server block)
corp.example.com:53 {
    errors
    cache 30
    forward . 10.0.0.53
}

# 3. Static records
    hosts {
       192.168.10.50 legacy-db.corp.example.com
       fallthrough
    }

# 4. Alias one name to another
    rewrite name api.example.internal api.prod.svc.cluster.local

# 5. Log every query while debugging (remove afterwards)
    log
```

```bash
kubectl -n kube-system edit cm coredns
kubectl -n kube-system rollout restart deploy coredns
kubectl -n kube-system logs -l k8s-app=kube-dns

# Test from inside a pod
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup app.corp.example.com
kubectl run dns-test --rm -it --image=nicolaka/netshoot --restart=Never -- dig @10.96.0.10 example.com
```

> [!WARNING]
> A server block for a domain must be at the **top level** of the Corefile, not nested inside `.:53 { }`. If the forward target is unreachable from the CoreDNS pods (routing or NetworkPolicy), lookups hang and then return `SERVFAIL`.

Reference: [Customizing DNS Service](https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/)

---

## 6. Pod Endpoint Availability

A Service only sends traffic to endpoints whose pods are **Ready**. Readiness comes from probes.

```yaml
containers:
- name: app
  image: my-app:1.0
  ports:
  - name: http
    containerPort: 8080
  readinessProbe:
    tcpSocket:
      port: 8080
    periodSeconds: 5
    failureThreshold: 3
  livenessProbe:
    tcpSocket:
      port: http
    initialDelaySeconds: 10
  startupProbe:
    httpGet:
      path: /healthz
      port: 8080
    failureThreshold: 30
    periodSeconds: 5
```

```bash
# Ready / serving / terminating state per endpoint
kubectl get endpointslices -l kubernetes.io/service-name=web -o yaml | grep -A4 conditions
kubectl describe pod <pod> | grep -A10 -i "readiness\|events"
```

### Finding and fixing an unhealthy Service

| Check | Broken when |
|-------|-------------|
| `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` | No addresses → selector does not match pod labels |
| Endpoints exist but `ready: false` | Readiness probe failing (wrong port, path or timing) |
| `targetPort` vs `containerPort` | Service sends to a port the app does not listen on |
| Named `targetPort` | Name does not exist in the pod spec |
| `kubectl exec <pod> -- ss -lntp` | App listening on `127.0.0.1` only, not `0.0.0.0` |
| Probe port differs from app port | Pod never becomes Ready |

`publishNotReadyAddresses: true` keeps not-ready pods in DNS. It is used for StatefulSet peer discovery and is rarely the right fix.

Reference: [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)

---

## 7. Gateway API

| Resource | Owner | Purpose |
|----------|-------|---------|
| `GatewayClass` | Infra provider | Names the controller (Envoy Gateway, Cilium, Istio, ...) |
| `Gateway` | Cluster operator | Listeners: port, protocol, hostname, TLS, allowed routes |
| `HTTPRoute` | App team | Matches (path, header, method, query) → filters → backends |
| `ReferenceGrant` | Target namespace owner | Allows cross-namespace references (backends, secrets) |

### Install Gateway API CRDs and Envoy Gateway

```bash
# Envoy Gateway's Helm chart installs the Gateway API CRDs (experimental channel) with it
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.10.0 \
  -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system wait --for=condition=Available deploy/envoy-gateway --timeout=120s
```

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: GatewayClass
metadata:
  name: eg
spec:
  controllerName: gateway.envoyproxy.io/gatewayclass-controller
---
apiVersion: gateway.networking.k8s.io/v1
kind: Gateway
metadata:
  name: web-gw
  namespace: web
spec:
  gatewayClassName: eg
  listeners:
  - name: http
    protocol: HTTP
    port: 80
    hostname: "*.example.com"
    allowedRoutes:
      namespaces:
        from: Same
---
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: shop
  namespace: web
spec:
  parentRefs:
  - name: web-gw
    sectionName: http
  hostnames:
  - shop.example.com
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /api
    backendRefs:
    - name: api-v1
      port: 8080
      weight: 90
    - name: api-v2
      port: 8080
      weight: 10
  - matches:
    - headers:
      - name: x-canary
        value: "true"
    backendRefs:
    - name: api-v2
      port: 8080
  - matches:
    - path:
        type: PathPrefix
        value: /
    filters:
    - type: RequestHeaderModifier
      requestHeaderModifier:
        add:
        - name: x-served-by
          value: gateway
    backendRefs:
    - name: frontend
      port: 80
```

Cilium also implements Gateway API (`--set gatewayAPI.enabled=true`, GatewayClass `cilium`). It requires `kubeProxyReplacement=true`, and the Gateway API CRDs must be installed **before** you enable it, because Cilium does not install them. The resources are the same; only `gatewayClassName` changes.

HTTPS listeners and certificates are covered in Domain 4 under Gateway TLS.

### Testing a Gateway

```bash
GW_IP=$(kubectl -n web get gateway web-gw -o jsonpath='{.status.addresses[0].value}')
curl -s -H "Host: shop.example.com" http://$GW_IP/api
curl -s --resolve shop.example.com:80:$GW_IP http://shop.example.com/
```

### Troubleshooting Gateway API routing

The resources' `status.conditions` tell you exactly what is wrong.

```bash
kubectl get gatewayclass
kubectl -n web get gateway web-gw
kubectl -n web describe httproute shop
```

| Condition / Reason | Meaning |
|--------------------|---------|
| GatewayClass `Accepted=Unknown`, reason `Pending` | No running controller claims this `controllerName` |
| Gateway `Programmed=False`, no address | No LoadBalancer IP (no MetalLB / LB-IPAM) or controller problem |
| Route `Accepted=False`, `NotAllowedByListeners` | Listener's `allowedRoutes` excludes the route's namespace |
| Route `Accepted=False`, `NoMatchingListenerHostname` | Route hostnames do not intersect listener hostname |
| Route `Accepted=False`, `NoMatchingParent` | `parentRefs` `sectionName` or `port` matches no listener |
| Route has no status for a parent | `parentRefs` name points at a Gateway that does not exist |
| Route `ResolvedRefs=False`, `BackendNotFound` | Backend Service does not exist (wrong name or namespace) |
| Route `ResolvedRefs=False`, `RefNotPermitted` | Cross-namespace backend without a `ReferenceGrant` |

Controller logs: `kubectl -n envoy-gateway-system logs deploy/envoy-gateway`. Reading the data-plane (Envoy) access logs is covered in Domain 5.

Reference: [Gateway API](https://gateway-api.sigs.k8s.io/) | [Envoy Gateway Docs](https://gateway.envoyproxy.io/docs/)

---

## 8. Troubleshooting Service Network Traffic

```text
Client ──► DNS ──► ClusterIP/NodePort/LB IP ──► service translation ──► EndpointSlice ──► Pod:targetPort
```

```bash
# 1. Name resolves to the expected IP?
kubectl exec client -- nslookup web.default.svc.cluster.local

# 2. Service and ports correct?
kubectl get svc web -o wide
kubectl get svc web -o jsonpath='{.spec.ports}'

# 3. Endpoints present and ready?
kubectl get endpointslices -l kubernetes.io/service-name=web

# 4. Pod answers directly (bypass the Service)?
kubectl exec client -- curl -m3 <podIP>:<targetPort>

# 5. Translation programmed? (pick one depending on implementation)
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep <clusterIP>
iptables-save -t nat | grep <clusterIP>
ipvsadm -Ln | grep -A3 <clusterIP>

# 6. Anything dropping it?
hubble observe -n default --to-label app=web --verdict DROPPED
```

If step 4 works but the Service does not, the problem is in steps 2, 3 or 5. If step 4 fails, look at the pod, its probes or a NetworkPolicy.

---

## 9. Hands-on Checklist

- [ ] Expose a Deployment as `LoadBalancer` and get a real external IP from MetalLB
- [ ] Preserve the client source IP with `externalTrafficPolicy: Local` and explain the trade-off
- [ ] Map an external IP to an in-cluster Service name with a selectorless Service + EndpointSlice
- [ ] Identify whether a cluster uses kube-proxy (iptables/ipvs/nftables), Cilium KPR or kube-router, and show the programmed rules for one Service
- [ ] Forward a specific domain, and separately all external lookups, to a given DNS server in the Corefile
- [ ] Debug a pod that cannot resolve external names, from `resolv.conf` through CoreDNS logs
- [ ] Add TCP readiness/liveness probes and confirm endpoints flip between ready and not-ready
- [ ] Find why a Service has no healthy backends (labels, ports, probes) and fix it
- [ ] Create a GatewayClass, Gateway with listeners, and HTTPRoutes with path, header and weighted rules
- [ ] Diagnose a Route that is not working using only its `status.conditions`
