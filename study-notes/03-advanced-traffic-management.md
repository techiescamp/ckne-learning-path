# Domain 3: Advanced Traffic Management (20%)

> **Exam Weight: 20%**: LLM / inference routing, BGP to expose networks, egress gateways, cross-cluster service discovery.

These tasks combine several moving parts: CRDs, Helm values and node labels. Read the whole task before touching anything, and verify each layer before moving to the next.

## Index

1. [Optimizing LLM Traffic: Gateway API Inference Extension](#1-optimizing-llm-traffic-gateway-api-inference-extension)
2. [Routing to Expose Networks: BGP](#2-routing-to-expose-networks-bgp)
3. [Egress Gateways for Cluster Exit Traffic](#3-egress-gateways-for-cluster-exit-traffic)
4. [Cross-cluster Service Discovery: Cilium Cluster Mesh](#4-cross-cluster-service-discovery-cilium-cluster-mesh)
5. [Hands-on Checklist](#5-hands-on-checklist)

---

## 1. Optimizing LLM Traffic: Gateway API Inference Extension

Ordinary load balancing (round-robin) is a poor fit for LLM servers. Request cost varies widely, and each replica has its own queue depth, KV-cache usage and loaded LoRA adapters. The **Gateway API Inference Extension** adds an **Endpoint Picker (EPP)** that the gateway consults to choose the best model-server pod for each request.

```text
Client ──POST /v1/completions──► Gateway ──► HTTPRoute ──► InferencePool ──(ask EPP)──► best vLLM pod
```

| Resource | Purpose |
|----------|---------|
| `InferencePool` | A group of model-server pods (label selector + target port) plus a reference to its EPP. Used as an HTTPRoute backend in place of a Service |
| Endpoint Picker (EPP) | A Deployment + Service that scores endpoints using live metrics (queue length, KV cache, adapters) |
| `InferenceObjective` | Optional request priority (`spec.priority`, integer) bound to a pool via `spec.poolRef`. Experimental API `inference.networking.x-k8s.io/v1alpha2` |

> [!IMPORTANT]
> API versions changed as the project matured: early releases used `inference.networking.x-k8s.io/v1alpha2`, and the GA `InferencePool` is `inference.networking.k8s.io/v1`. Always check what the cluster actually serves:
> ```bash
> kubectl api-resources | grep -i inference
> kubectl explain inferencepool.spec --recursive
> ```

### Configure an InferencePool

```yaml
apiVersion: inference.networking.k8s.io/v1
kind: InferencePool
metadata:
  name: llama-pool
  namespace: inference
spec:
  selector:
    matchLabels:
      app: vllm-llama
  targetPorts:
  - number: 8000
  endpointPickerRef:
    name: llama-pool-epp
    port:
      number: 9002
```

Releases up to v1.5.0 ship a Helm chart that creates the pool and its EPP together. From v1.6 the EPP and its charts are maintained in the llm-d-router project, so check which one your cluster uses:

```bash
helm install llama-pool \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool --version v1.5.0 \
  --set inferencePool.modelServers.matchLabels.app=vllm-llama \
  -n inference
```

### Route inference requests to the pool

```yaml
apiVersion: gateway.networking.k8s.io/v1
kind: HTTPRoute
metadata:
  name: llm-route
  namespace: inference
spec:
  parentRefs:
  - name: inference-gateway
  rules:
  - matches:
    - path:
        type: PathPrefix
        value: /v1/completions
    backendRefs:
    - group: inference.networking.k8s.io
      kind: InferencePool
      name: llama-pool
```

### Verify

```bash
kubectl -n inference get inferencepool llama-pool -o yaml
kubectl -n inference describe httproute llm-route

GW_IP=$(kubectl -n inference get gateway inference-gateway -o jsonpath='{.status.addresses[0].value}')
curl -s http://$GW_IP/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<model-name>","prompt":"Hello","max_tokens":20}'

# Which pod served it?
kubectl -n inference logs deploy/llama-pool-epp | tail
kubectl -n inference logs -l app=vllm-llama --prefix | grep completions
```

| Symptom | Check |
|---------|-------|
| 404 from gateway | Path match wrong, or route not attached (`Accepted=False`) |
| 500/503 immediately | EPP not running or `endpointPickerRef` wrong, with `failureMode: FailClose` (API default). The Helm chart defaults to `FailOpen`, which forwards anyway |
| `ResolvedRefs=False` | Wrong `group`/`kind`/`name` in `backendRefs`, or the gateway does not support InferencePool |
| Traffic hits wrong pods | `selector` labels or `targetPorts` do not match the model servers |

Reference: [Gateway API Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/)

---

## 2. Routing to Expose Networks: BGP

BGP lets the cluster tell an upstream router "send traffic for these prefixes to me". You advertise **pod CIDRs** (so external networks can reach pods directly, without NAT) and **Service IPs** (LoadBalancer / ClusterIP / externalIPs).

### Cilium BGP Control Plane

Enable it first:

```bash
cilium upgrade --reuse-values --set bgpControlPlane.enabled=true
kubectl -n kube-system rollout restart ds/cilium deploy/cilium-operator
kubectl api-resources | grep -i ciliumbgp
```

Configuration uses three linked resources: **ClusterConfig → PeerConfig → Advertisement**.

```yaml
# Which nodes speak BGP, their ASN and their peers
apiVersion: cilium.io/v2
kind: CiliumBGPClusterConfig
metadata:
  name: cluster-bgp
spec:
  nodeSelector:
    matchLabels:
      bgp: "enabled"
  bgpInstances:
  - name: instance-65001
    localASN: 65001
    peers:
    - name: tor-router
      peerASN: 65000
      peerAddress: 172.18.0.100
      peerConfigRef:
        name: tor-peer-config
---
# How to talk to the peer and which advertisements to send
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: tor-peer-config
spec:
  timers:
    holdTimeSeconds: 9
    keepAliveTimeSeconds: 3
  gracefulRestart:
    enabled: true
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        advertise: "bgp"
---
# What to advertise
apiVersion: cilium.io/v2
kind: CiliumBGPAdvertisement
metadata:
  name: pod-and-lb
  labels:
    advertise: "bgp"
spec:
  advertisements:
  - advertisementType: PodCIDR
  - advertisementType: Service
    service:
      addresses:
      - LoadBalancerIP
    selector:
      matchExpressions:
      - key: bgp-exclude
        operator: DoesNotExist
```

```bash
kubectl label node <node> bgp=enabled
```

> [!NOTE]
> Older Cilium releases use `cilium.io/v2alpha1` for these kinds, and very old ones use the legacy `CiliumBGPPeeringPolicy`. Match whatever `kubectl api-resources` shows. `PodCIDR` advertises each node's own pod CIDR (Kubernetes or cluster-pool IPAM only; multi-pool needs `advertisementType: CiliumPodIPPool`), so check it against the pod CIDRs you are given (`kubectl get ciliumnodes`) before you peer.

### Verify BGP

```bash
cilium bgp peers
cilium bgp routes advertised ipv4 unicast
cilium bgp routes available ipv4 unicast
kubectl get ciliumbgpnodeconfigs -o yaml

# On the upstream router (FRR)
vtysh -c "show bgp summary"
vtysh -c "show ip bgp"
vtysh -c "show ip route bgp"
```

| Session state | Likely cause |
|---------------|--------------|
| `active` / `connect` / `idle` | Wrong `peerAddress`, TCP/179 blocked, router not configured for this neighbor |
| `established`, no routes | Advertisement labels do not match the PeerConfig selector, or the service selector excludes everything |
| Routes present but traffic fails | Return path: the router must have routes back, and check the node's `rp_filter` |
| ASN mismatch | `localASN`/`peerASN` swapped relative to the router config |

### Other BGP speakers you may meet

| Tool | Advertises | Inspect |
|------|-----------|---------|
| MetalLB BGP mode | LoadBalancer IPs (`BGPPeer`, `BGPAdvertisement`) | `kubectl -n metallb-system logs -l component=speaker` (Helm install: `-l app.kubernetes.io/component=speaker`) |
| kube-router | Pod CIDRs, ClusterIPs, external and LB IPs | `gobgp neighbor`, `gobgp global rib` |

Reference: [Cilium BGP Control Plane](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane/)

---

## 3. Egress Gateways for Cluster Exit Traffic

By default a pod's external traffic leaves from whichever node it runs on, SNATed to that node's IP. An **egress gateway** sends selected traffic through designated nodes and SNATs it to a **fixed, predictable IP**. That IP is what firewalls and partner APIs allow-list.

### Prerequisites

```bash
cilium upgrade --reuse-values \
  --set egressGateway.enabled=true \
  --set bpf.masquerade=true \
  --set kubeProxyReplacement=true
kubectl -n kube-system rollout restart ds/cilium deploy/cilium-operator

kubectl label node <gateway-node> egress-gw=true
```

### CiliumEgressGatewayPolicy

```yaml
apiVersion: cilium.io/v2
kind: CiliumEgressGatewayPolicy
metadata:
  name: payments-egress
spec:
  selectors:
  - podSelector:
      matchLabels:
        app: billing
        io.kubernetes.pod.namespace: payments
  destinationCIDRs:
  - 203.0.113.0/24
  excludedCIDRs:
  - 203.0.113.10/32
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gw: "true"
    egressIP: 172.18.0.50
    # interface: eth1
```

The policy is cluster-scoped. Select a namespace with the `io.kubernetes.pod.namespace` label, or use `namespaceSelector`.

### Verify the egress path

```bash
# Policy translated into BPF; Egress IP shows 0.0.0.0 except on the agent running on the gateway node
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf egress list
#  Source IP    Destination CIDR   Egress IP     Gateway IP
#  10.10.1.23   203.0.113.0/24     172.18.0.50   172.18.0.4

# From the workload: what source IP does the server see?
kubectl -n payments exec deploy/billing -- curl -s http://203.0.113.20/whoami

# On the gateway node: traffic leaves with the egress IP
tcpdump -i eth0 -nn host 203.0.113.20
```

| Symptom | Check |
|---------|-------|
| `bpf egress list` empty | `egressGateway.enabled` not set, or agents not restarted |
| Source is still the worker node IP | Pod labels / namespace label in `selectors` do not match, or destination not in `destinationCIDRs` |
| Traffic dropped | `egressIP` not present on any interface of the selected gateway node |
| Gateway IP shows `0.0.0.0` | No node matches `nodeSelector` |

Reference: [Cilium Egress Gateway](https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/)

---

## 4. Cross-cluster Service Discovery: Cilium Cluster Mesh

Cluster Mesh joins multiple clusters' Cilium datapaths. Pods reach pods across clusters directly, policies can select remote identities, and **global services** load-balance across backends in all clusters.

### Requirements

| Requirement | Why |
|-------------|-----|
| Unique `cluster.name` and `cluster.id` (1–255) per cluster | Identities and IPs must not collide |
| Non-overlapping pod CIDRs | Routing between clusters |
| Nodes in all clusters can reach each other (and the clustermesh-apiserver) | Datapath and control plane |
| Shared Cilium CA | Mutual TLS between clustermesh components |

### Setup

```bash
# Cluster 1
cilium install --context kind-c1 \
  --set cluster.name=c1 --set cluster.id=1 \
  --set ipam.operator.clusterPoolIPv4PodCIDRList=10.1.0.0/16

# Cluster 2 must share cluster 1's CA: copy it before installing
kubectl --context kind-c1 get secret -n kube-system cilium-ca -o yaml | \
  kubectl --context kind-c2 create -f -

cilium install --context kind-c2 \
  --set cluster.name=c2 --set cluster.id=2 \
  --set ipam.operator.clusterPoolIPv4PodCIDRList=10.2.0.0/16

# Enable the clustermesh-apiserver in each cluster
cilium clustermesh enable --context kind-c1 --service-type LoadBalancer
cilium clustermesh enable --context kind-c2 --service-type LoadBalancer
cilium clustermesh status --context kind-c1 --wait

# Connect (bidirectional)
cilium clustermesh connect --context kind-c1 --destination-context kind-c2
cilium clustermesh status --context kind-c1 --wait
```

### Global services

Create a Service with the **same name and namespace** in each cluster and annotate it:

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: shop
  annotations:
    service.cilium.io/global: "true"
    service.cilium.io/shared: "true"
    service.cilium.io/affinity: "local"
spec:
  selector:
    app: backend
  ports:
  - port: 80
```

The backend can live only in cluster 2. A client in cluster 1 still resolves `backend.shop.svc.cluster.local`, as long as the Service object (selector can match nothing locally) exists in cluster 1 too.

```bash
kubectl --context kind-c1 -n shop exec deploy/client -- \
  sh -c 'for i in $(seq 10); do curl -s backend/; done'

kubectl --context kind-c1 -n kube-system exec ds/cilium -- cilium-dbg service list | grep -A4 <clusterIP>
```

### Troubleshooting Cluster Mesh

```bash
cilium clustermesh status --context kind-c1
kubectl --context kind-c1 -n kube-system exec ds/cilium -- cilium-dbg troubleshoot clustermesh
kubectl --context kind-c1 -n kube-system logs deploy/clustermesh-apiserver -c apiserver
kubectl --context kind-c1 -n kube-system exec ds/cilium -- cilium-dbg node list
```

| Symptom | Likely cause |
|---------|--------------|
| Status shows 0 remote nodes | clustermesh-apiserver Service not reachable (no LB IP, wrong NodePort, firewall) |
| TLS / certificate errors | Clusters do not share a CA (`cilium-ca` Secret not copied) |
| Duplicate cluster ID error | Same `cluster.id` used twice |
| Global service only hits local backends | Annotation missing in **one** of the clusters, or `affinity: local` with healthy local backends |
| Cross-cluster pod traffic dropped | Overlapping pod CIDRs or a policy that does not allow the remote identity |

Kubernetes' **Multi-Cluster Services API** (`ServiceExport` / `ServiceImport`, `*.svc.clusterset.local`) is supported by newer Cilium versions as an alternative to the annotations.

Reference: [Cilium Cluster Mesh](https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/)

---

## 5. Hands-on Checklist

- [ ] Explain why inference traffic needs an endpoint picker instead of round-robin
- [ ] Create an InferencePool for a set of model-server pods and route `/v1/completions` to it
- [ ] Prove which backend pod served an inference request
- [ ] Enable the Cilium BGP control plane and peer with an upstream router
- [ ] Advertise pod CIDRs and LoadBalancer IPs, matching the pod CIDRs a task gives you
- [ ] Verify sessions are established and routes are visible on both sides
- [ ] Send one app's external traffic through an egress gateway node with a fixed source IP
- [ ] Prove the egress path with `cilium-dbg bpf egress list` and the source IP seen by the server
- [ ] Connect two clusters with Cluster Mesh and make a client in one reach a backend in the other
- [ ] Control global service behaviour with the `shared` and `affinity` annotations
- [ ] Diagnose a broken mesh connection from `cilium clustermesh status` output
