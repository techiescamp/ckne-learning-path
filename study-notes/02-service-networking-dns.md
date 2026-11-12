# Domain 2: Service Networking and DNS (25%)

> **Exam Weight: 25%**: This domain covers L4 Services, kube-proxy and its alternatives, CoreDNS, endpoint health and the Gateway API.

This is one of the two heaviest domains in the exam, so it deserves a large share of your practice time. You should expect to expose workloads, route HTTP traffic through a Gateway, and fix Services that look fine at first glance but send traffic nowhere.

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

Kubernetes offers several Service types, and each one decides who can reach the Service and how. The table below compares them.

| Type | Reachable from | Notes |
|------|----------------|-------|
| `ClusterIP` | Only from inside the cluster | This is the default type |
| `NodePort` | `<anyNodeIP>:30000-32767` | Builds on top of a ClusterIP |
| `LoadBalancer` | An external IP handed out by a LB implementation (cloud, MetalLB, Cilium LB-IPAM) | Builds on top of a NodePort, unless you set `allocateLoadBalancerNodePorts: false` |
| `ExternalName` | Only through a DNS CNAME, because no traffic is proxied | Has no endpoints |
| Headless (`clusterIP: None`) | DNS returns the pod IPs directly | Used by StatefulSets |

The following Service uses most of the fields you are likely to change in the exam:

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

The traffic policy fields control which endpoints receive traffic, and some of them also decide whether the client IP survives:

| Field | Effect |
|-------|--------|
| `externalTrafficPolicy: Cluster` | Any node can forward the traffic, but the client IP is SNATed, so the backend never sees it |
| `externalTrafficPolicy: Local` | The client IP is preserved, but nodes without a local endpoint fail the health checks and receive no traffic |
| `internalTrafficPolicy: Local` | Clients inside the cluster only reach endpoints on their own node |
| `trafficDistribution: PreferSameZone` | Traffic prefers endpoints in the client's zone (`PreferClose` is the deprecated alias for this) |
| `trafficDistribution: PreferSameNode` | Traffic prefers endpoints on the client's own node |

Reference: [Service](https://kubernetes.io/docs/concepts/services-networking/service/)

---

## 2. LoadBalancer IPs with MetalLB

On bare metal and on kind there is no cloud provider to hand out external IPs. Because of this, a `LoadBalancer` Service stays in `<pending>` until something else allocates the IPs, and MetalLB is one tool that does this job. First install it and wait for its pods to become ready:

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.2/config/manifests/metallb-native.yaml
kubectl -n metallb-system wait --for=condition=Ready pod -l app=metallb --timeout=120s
```

Next, give MetalLB a pool of addresses it is allowed to use, and tell it how to announce them. In the example below, an `L2Advertisement` announces the pool in Layer 2 mode:

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

Instead of Layer 2, MetalLB can also announce the IPs over BGP by using `BGPPeer` and `BGPAdvertisement`. The BGP concepts themselves are covered together with Cilium BGP in Domain 3.

Once the pool exists, check that the Service received an IP. If it did not, the Service events and the speaker logs usually tell you why:

```bash
kubectl get svc web
kubectl describe svc web | grep -A5 Events
kubectl -n metallb-system logs -l component=speaker
```

> [!NOTE]
> Cilium can do the same job natively with a `CiliumLoadBalancerIPPool` combined with either `l2announcements.enabled=true` or BGP. However, you should not run two LB IP allocators on the same Services, because they will compete for them.

Reference: [MetalLB Configuration](https://metallb.universe.tf/configuration/)

---

## 3. Reaching External Services from Pods

### Give an external endpoint a cluster name

Sometimes pods need to reach something outside the cluster, such as a legacy database, but you still want them to use a stable in-cluster name. To do this, create a Service **without a selector** and then write its EndpointSlice by hand so that it points at the external IP:

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

If the external side has a DNS name rather than an IP, use `type: ExternalName` with `externalName: db.example.com` instead.

### What happens to the source IP

When a pod talks to something outside the cluster, the traffic leaves the node with the **node IP** as its source address, because of masquerading (see Domain 1). This matters if the external side allow-lists source IPs, since it will see node IPs and not pod IPs. In that case you need either a predictable node or an Egress Gateway (Domain 3).

The commands below show which source IP the outside world sees and whether the node routes the traffic correctly:

```bash
# What source IP does the outside world see?
kubectl exec <pod> -- curl -s http://<external-echo-server>/ip

# Is the route out of the node correct?
ip route get <external-ip>
```

When pods cannot reach an external service, the usual causes are a missing route from the node, `ip_forward=0`, a NetworkPolicy that has no egress allow rule, masquerading being disabled for that destination, or a failing DNS lookup for the external name (see CoreDNS below).

---

## 4. kube-proxy and CNI Alternatives

Every Service needs something on each node that translates the Service IP into a pod IP. Several components can do this job, and each one stores its rules in a different place, so you need to know where to look:

| Implementation | How Services are programmed | Where to look |
|----------------|-----------------------------|---------------|
| kube-proxy `iptables` | Through the `KUBE-SERVICES` → `KUBE-SVC-*` → `KUBE-SEP-*` DNAT chains | `iptables-save -t nat` |
| kube-proxy `ipvs` (deprecated since v1.35) | As IPVS virtual servers on `kube-ipvs0` | `ipvsadm -Ln` |
| kube-proxy `nftables` | In the nftables `kube-proxy` table | `nft list table ip kube-proxy` |
| Cilium KPR | In eBPF maps | `cilium-dbg service list`, `cilium-dbg bpf lb list` |
| kube-router | IPVS for the service proxy, GoBGP for routing and iptables/ipset for policy | `ipvsadm -Ln`, `gobgp neighbor` |

If the cluster runs kube-proxy, first find out which mode it uses:

```bash
# Which mode is kube-proxy running in?
kubectl -n kube-system get cm kube-proxy -o yaml | grep mode
kubectl -n kube-system logs ds/kube-proxy | grep -i "using"
```

### kube-router

kube-router runs as a DaemonSet and can take on three roles. It can replace kube-proxy (`--run-service-proxy=true`), act as the pod router (`--run-router=true`) and enforce NetworkPolicy (`--run-firewall=true`). In addition, it peers with upstream routers over BGP so that it can advertise pod CIDRs and Service IPs to them. A typical set of flags looks like this:

```text
--run-router=true --run-firewall=true --run-service-proxy=true
--cluster-asn=64512
--peer-router-ips=172.18.0.100 --peer-router-asns=65000
--advertise-cluster-ip=true --advertise-external-ip=true --advertise-loadbalancer-ip=true
```

To check the BGP sessions, the routes it learned and the IPVS rules, run the tools inside the kube-router pod:

```bash
kubectl -n kube-system exec ds/kube-router -- gobgp neighbor
kubectl -n kube-system exec ds/kube-router -- gobgp global rib
kubectl -n kube-system exec ds/kube-router -- ipvsadm -Ln
```

You set per-service options with annotations. For example, `kube-router.io/service.scheduler: lc` switches that Service to the least connection scheduler.

Reference: [kube-router User Guide](https://www.kube-router.io/docs/user-guide/)

---

## 5. Customizing CoreDNS

CoreDNS reads its configuration, called the Corefile, from the `coredns` ConfigMap in `kube-system`. After you edit it, allow up to about 2 minutes for the change to take effect. This delay happens because the kubelet first has to sync the ConfigMap into the pod, and then the `reload` plugin only checks for changes every 30s (±15s jitter). If you do not want to wait, a rollout restart applies the change immediately.

A default Corefile looks like this:

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

These are the changes you are most likely to be asked for. Except for the separate server block in example 2, each snippet goes inside the existing `.:53 { }` block.

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

After editing, restart CoreDNS if you do not want to wait for the reload, check its logs, and then test the lookup from inside a pod:

```bash
kubectl -n kube-system edit cm coredns
kubectl -n kube-system rollout restart deploy coredns
kubectl -n kube-system logs -l k8s-app=kube-dns

# Test from inside a pod
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup app.corp.example.com
kubectl run dns-test --rm -it --image=nicolaka/netshoot --restart=Never -- dig @10.96.0.10 example.com
```

> [!WARNING]
> A server block for a domain must sit at the **top level** of the Corefile, and not nested inside `.:53 { }`. Also, if the forward target cannot be reached from the CoreDNS pods (because of routing or a NetworkPolicy), lookups hang for a while and then return `SERVFAIL`.

Reference: [Customizing DNS Service](https://kubernetes.io/docs/tasks/administer-cluster/dns-custom-nameservers/)

---

## 6. Pod Endpoint Availability

A Service only sends traffic to endpoints whose pods are **Ready**, and a pod's readiness comes from its probes. As a result, a wrong probe can silently remove a pod from the Service. The example below defines all three probe types:

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

To see whether each endpoint is ready, serving or terminating, look at the EndpointSlice conditions. The pod description then shows why a probe is failing:

```bash
# Ready / serving / terminating state per endpoint
kubectl get endpointslices -l kubernetes.io/service-name=web -o yaml | grep -A4 conditions
kubectl describe pod <pod> | grep -A10 -i "readiness\|events"
```

### Finding and fixing an unhealthy Service

When a Service has no healthy backends, work through these checks in order:

| Check | Broken when |
|-------|-------------|
| `kubectl get endpointslices -l kubernetes.io/service-name=<svc>` | There are no addresses, which means the selector does not match the pod labels |
| Endpoints exist but show `ready: false` | The readiness probe is failing because of a wrong port, path or timing |
| `targetPort` vs `containerPort` | The Service sends traffic to a port the app does not listen on |
| Named `targetPort` | The name does not exist in the pod spec |
| `kubectl exec <pod> -- ss -lntp` | The app listens only on `127.0.0.1` instead of `0.0.0.0` |
| Probe port differs from the app port | The pod never becomes Ready |

Setting `publishNotReadyAddresses: true` keeps not-ready pods in DNS. This is meant for StatefulSet peer discovery, so it is rarely the right fix for an unhealthy Service.

Reference: [Configure Liveness, Readiness and Startup Probes](https://kubernetes.io/docs/tasks/configure-pod-container/configure-liveness-readiness-startup-probes/)

---

## 7. Gateway API

The Gateway API splits HTTP routing into several resources, so that each team owns only the part it is responsible for:

| Resource | Owner | Purpose |
|----------|-------|---------|
| `GatewayClass` | Infra provider | Names the controller that runs it (Envoy Gateway, Cilium, Istio, ...) |
| `Gateway` | Cluster operator | Defines the listeners: port, protocol, hostname, TLS and which routes are allowed |
| `HTTPRoute` | App team | Matches requests (path, header, method, query), applies filters and sends them to backends |
| `ReferenceGrant` | Owner of the target namespace | Allows references across namespaces (to backends or secrets) |

### Install Gateway API CRDs and Envoy Gateway

Envoy Gateway's Helm chart installs the Gateway API CRDs along with the controller, so a single command is enough:

```bash
# Envoy Gateway's Helm chart installs the Gateway API CRDs (experimental channel) with it
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.10.0 \
  -n envoy-gateway-system --create-namespace
kubectl -n envoy-gateway-system wait --for=condition=Available deploy/envoy-gateway --timeout=120s
```

Next, create a GatewayClass that points at the controller, a Gateway with an HTTP listener, and an HTTPRoute. The route below shows three common patterns: a weighted split between two backends on `/api`, a header match that sends canary traffic to `api-v2`, and a catch-all rule that adds a request header before sending traffic to the frontend.

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

Cilium also implements the Gateway API. You enable it with `--set gatewayAPI.enabled=true`, and it then provides the GatewayClass `cilium`. It requires `kubeProxyReplacement=true`, and you must install the Gateway API CRDs **before** you enable it, because Cilium does not install them itself. The resources stay the same, and only `gatewayClassName` changes.

HTTPS listeners and certificates are covered in Domain 4 under Gateway TLS.

### Testing a Gateway

To test the routing, first read the Gateway's address from its status. Then send requests with the right hostname, either by setting the `Host` header or by using `--resolve`:

```bash
GW_IP=$(kubectl -n web get gateway web-gw -o jsonpath='{.status.addresses[0].value}')
curl -s -H "Host: shop.example.com" http://$GW_IP/api
curl -s --resolve shop.example.com:80:$GW_IP http://shop.example.com/
```

### Troubleshooting Gateway API routing

When routing does not work, start with the `status.conditions` of each resource, because they tell you exactly what is wrong.

```bash
kubectl get gatewayclass
kubectl -n web get gateway web-gw
kubectl -n web describe httproute shop
```

The table below maps the most common conditions to their cause:

| Condition / Reason | Meaning |
|--------------------|---------|
| GatewayClass `Accepted=Unknown`, reason `Pending` | No running controller claims this `controllerName` |
| Gateway `Programmed=False`, no address | There is no LoadBalancer IP (no MetalLB or LB-IPAM), or the controller has a problem |
| Route `Accepted=False`, `NotAllowedByListeners` | The listener's `allowedRoutes` excludes the route's namespace |
| Route `Accepted=False`, `NoMatchingListenerHostname` | The route hostnames do not overlap with the listener hostname |
| Route `Accepted=False`, `NoMatchingParent` | The `sectionName` or `port` in `parentRefs` matches no listener |
| Route has no status for a parent | The `parentRefs` name points at a Gateway that does not exist |
| Route `ResolvedRefs=False`, `BackendNotFound` | The backend Service does not exist (wrong name or namespace) |
| Route `ResolvedRefs=False`, `RefNotPermitted` | The backend is in another namespace and there is no `ReferenceGrant` for it |

If the conditions are not enough, read the controller logs with `kubectl -n envoy-gateway-system logs deploy/envoy-gateway`. Reading the data-plane (Envoy) access logs is covered in Domain 5.

Reference: [Gateway API](https://gateway-api.sigs.k8s.io/) | [Envoy Gateway Docs](https://gateway.envoyproxy.io/docs/)

---

## 8. Troubleshooting Service Network Traffic

A request to a Service passes through several stages before it reaches a pod. When something breaks, follow the same path and check each stage in turn:

```text
Client ──► DNS ──► ClusterIP/NodePort/LB IP ──► service translation ──► EndpointSlice ──► Pod:targetPort
```

The commands below follow that path step by step:

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

Step 4 is the key split. If the pod answers directly but the Service does not, the problem is in steps 2, 3 or 5. If step 4 also fails, the problem is with the pod itself, its probes or a NetworkPolicy.

---

## 9. Hands-on Checklist

- [ ] Can you expose a Deployment as a `LoadBalancer` Service and get a real external IP from MetalLB?
- [ ] Can you preserve the client source IP with `externalTrafficPolicy: Local` and explain what you give up in return?
- [ ] Can you map an external IP to an in-cluster Service name by using a selectorless Service and an EndpointSlice?
- [ ] Can you tell whether a cluster uses kube-proxy (iptables/ipvs/nftables), Cilium KPR or kube-router, and show the programmed rules for one Service?
- [ ] Can you edit the Corefile to forward one specific domain to a given DNS server, and separately to forward all external lookups to it?
- [ ] Can you debug a pod that cannot resolve external names, starting from `resolv.conf` and ending at the CoreDNS logs?
- [ ] Can you add TCP readiness and liveness probes and confirm that the endpoints flip between ready and not-ready?
- [ ] Can you find out why a Service has no healthy backends (labels, ports or probes) and fix it?
- [ ] Can you create a GatewayClass, a Gateway with listeners, and HTTPRoutes with path, header and weighted rules?
- [ ] Can you diagnose a Route that is not working by using only its `status.conditions`?
