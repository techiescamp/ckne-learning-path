# Domain 3: Advanced Traffic Management (20%)

> **Exam Weight: 20%**: This domain covers routing traffic to LLM inference servers, using BGP to expose cluster networks, sending exit traffic through egress gateways, and discovering services across clusters.

Tasks in this domain combine several moving parts, such as CRDs, Helm values and node labels, so a mistake in one layer can hide behind another. Read the whole task before you touch anything, and verify each layer before you move on to the next one.

## Index

1. [Optimizing LLM Traffic: Gateway API Inference Extension](#1-optimizing-llm-traffic-gateway-api-inference-extension)
2. [Routing to Expose Networks: BGP](#2-routing-to-expose-networks-bgp)
3. [Egress Gateways for Cluster Exit Traffic](#3-egress-gateways-for-cluster-exit-traffic)
4. [Cross-cluster Service Discovery: Cilium Cluster Mesh](#4-cross-cluster-service-discovery-cilium-cluster-mesh)
5. [Hands-on Checklist](#5-hands-on-checklist)

---

## 1. Optimizing LLM Traffic: Gateway API Inference Extension

Ordinary load balancing, such as round-robin, is a poor fit for LLM servers. The cost of a request varies widely, and each replica has its own queue depth, KV-cache usage and set of loaded LoRA adapters. If the gateway simply sends each request to the next pod in line, one replica can end up overloaded while another sits idle.

The **Gateway API Inference Extension** solves this by adding an **Endpoint Picker (EPP)**. The gateway consults the EPP for every request, and the EPP chooses the best model-server pod to handle it.

```text
Client ──POST /v1/completions──► Gateway ──► HTTPRoute ──► InferencePool ──(ask EPP)──► best vLLM pod
```

| Resource | Purpose |
|----------|---------|
| `InferencePool` | A group of model-server pods, defined by a label selector and a target port, plus a reference to its EPP. An HTTPRoute uses it as a backend in place of a Service |
| Endpoint Picker (EPP) | A Deployment and a Service that score the endpoints using live metrics such as queue length, KV cache and loaded adapters |
| `InferenceObjective` | An optional resource that sets a request priority (`spec.priority`, an integer) and binds to a pool through `spec.poolRef`. It uses the experimental API `inference.networking.x-k8s.io/v1alpha2` |

> [!IMPORTANT]
> The API versions changed as the project matured. Early releases used `inference.networking.x-k8s.io/v1alpha2`, while the GA `InferencePool` is `inference.networking.k8s.io/v1`. Because of this, always check which version the cluster actually serves:
> ```bash
> kubectl api-resources | grep -i inference
> kubectl explain inferencepool.spec --recursive
> ```

### Configure an InferencePool

An InferencePool selects the model-server pods by label, sets the port they listen on, and points to the EPP that chooses between them:

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

Releases up to v1.5.0 ship a Helm chart that creates the pool and its EPP together. From v1.6 onward, the EPP and its charts are maintained in the llm-d-router project instead, so check which of the two your cluster uses:

```bash
helm install llama-pool \
  oci://registry.k8s.io/gateway-api-inference-extension/charts/inferencepool --version v1.5.0 \
  --set inferencePool.modelServers.matchLabels.app=vllm-llama \
  -n inference
```

### Route inference requests to the pool

To send requests to the pool, reference it in the `backendRefs` of an HTTPRoute, in the place where you would normally put a Service:

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

First check the pool and the route status, then send a test request through the gateway, and finally look at the logs to see which pod served it:

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

If the request fails, the symptom usually points to the cause:

| Symptom | Check |
|---------|-------|
| 404 from gateway | The path match is wrong, or the route is not attached to the gateway (`Accepted=False`) |
| 500/503 immediately | The EPP is not running or `endpointPickerRef` is wrong, and the pool uses `failureMode: FailClose` (the API default). The Helm chart defaults to `FailOpen` instead, which forwards the request anyway |
| `ResolvedRefs=False` | The `group`, `kind` or `name` in `backendRefs` is wrong, or the gateway does not support InferencePool |
| Traffic hits wrong pods | The `selector` labels or `targetPorts` do not match the model servers |

Reference: [Gateway API Inference Extension](https://gateway-api-inference-extension.sigs.k8s.io/)

---

## 2. Routing to Expose Networks: BGP

BGP lets the cluster tell an upstream router to send traffic for certain prefixes to it. You can advertise **pod CIDRs**, so that external networks can reach pods directly without NAT, and **Service IPs**, which can be LoadBalancer, ClusterIP or externalIPs addresses.

### Cilium BGP Control Plane

Before you create any BGP resources, enable the control plane, restart the Cilium agents and operator so they pick up the change, and confirm that the BGP CRDs now exist:

```bash
cilium upgrade --reuse-values --set bgpControlPlane.enabled=true
kubectl -n kube-system rollout restart ds/cilium deploy/cilium-operator
kubectl api-resources | grep -i ciliumbgp
```

The configuration uses three resources that are linked in this order: **ClusterConfig → PeerConfig → Advertisement**. The ClusterConfig chooses which nodes speak BGP and who their peers are, the PeerConfig defines how to talk to each peer, and the Advertisement defines what to announce.

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

Because the ClusterConfig only applies to nodes that match its `nodeSelector`, label every node that should peer:

```bash
kubectl label node <node> bgp=enabled
```

> [!NOTE]
> Older Cilium releases use `cilium.io/v2alpha1` for these kinds, and very old ones use the legacy `CiliumBGPPeeringPolicy` instead, so match whatever `kubectl api-resources` shows. Also keep in mind that `PodCIDR` advertises each node's own pod CIDR. This works only with Kubernetes or cluster-pool IPAM, while multi-pool IPAM needs `advertisementType: CiliumPodIPPool` instead. Before you peer, check what will be advertised against the pod CIDRs you are given (`kubectl get ciliumnodes`).

### Verify BGP

Check the sessions and routes from the Cilium side first, and then confirm on the upstream router that it actually received them:

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

If something is wrong, the session state tells you where to look:

| Session state | Likely cause |
|---------------|--------------|
| `active` / `connect` / `idle` | The `peerAddress` is wrong, TCP/179 is blocked, or the router is not configured for this neighbor |
| `established`, no routes | The Advertisement labels do not match the PeerConfig selector, or the service selector excludes every Service |
| Routes present but traffic fails | The return path is the problem. The router must have routes back to the cluster, and you should also check the node's `rp_filter` setting |
| ASN mismatch | `localASN` and `peerASN` are swapped compared with the router config |

### Other BGP speakers you may meet

Cilium is not the only tool that speaks BGP. You may also meet these:

| Tool | Advertises | Inspect |
|------|-----------|---------|
| MetalLB BGP mode | LoadBalancer IPs, configured with `BGPPeer` and `BGPAdvertisement` | `kubectl -n metallb-system logs -l component=speaker` (for a Helm install, use `-l app.kubernetes.io/component=speaker`) |
| kube-router | Pod CIDRs, ClusterIPs, external IPs and LB IPs | `gobgp neighbor`, `gobgp global rib` |

Reference: [Cilium BGP Control Plane](https://docs.cilium.io/en/stable/network/bgp-control-plane/bgp-control-plane/)

---

## 3. Egress Gateways for Cluster Exit Traffic

By default, a pod's external traffic leaves from whichever node the pod runs on and is SNATed to that node's IP, so the source IP depends on where the pod happens to be scheduled. An **egress gateway** instead sends selected traffic through designated nodes and SNATs it to a **fixed, predictable IP**. Firewalls and partner APIs can then allow-list that one IP.

### Prerequisites

The egress gateway depends on BPF masquerading and kube-proxy replacement, so enable all three settings and restart the agents and operator. Then label the node that will act as the gateway:

```bash
cilium upgrade --reuse-values \
  --set egressGateway.enabled=true \
  --set bpf.masquerade=true \
  --set kubeProxyReplacement=true
kubectl -n kube-system rollout restart ds/cilium deploy/cilium-operator

kubectl label node <gateway-node> egress-gw=true
```

### CiliumEgressGatewayPolicy

The policy below sends traffic from the selected pods to the destination CIDRs through the labelled gateway node, using a fixed egress IP:

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

The policy is cluster-scoped, which means it does not belong to any namespace. To limit it to one namespace, select the `io.kubernetes.pod.namespace` label as the example does, or use `namespaceSelector`.

### Verify the egress path

Confirm that the policy reached the BPF maps, and then check the source IP from both ends of the connection:

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

If the traffic does not leave with the expected IP, use this table to narrow it down:

| Symptom | Check |
|---------|-------|
| `bpf egress list` empty | `egressGateway.enabled` is not set, or the agents were not restarted after setting it |
| Source is still the worker node IP | The pod labels or the namespace label in `selectors` do not match, or the destination is not in `destinationCIDRs` |
| Traffic dropped | The `egressIP` is not present on any interface of the selected gateway node |
| Gateway IP shows `0.0.0.0` | No node matches the `nodeSelector` |

Reference: [Cilium Egress Gateway](https://docs.cilium.io/en/stable/network/egress-gateway/egress-gateway/)

---

## 4. Cross-cluster Service Discovery: Cilium Cluster Mesh

Cluster Mesh joins the Cilium datapaths of multiple clusters. Once they are joined, pods can reach pods in other clusters directly, policies can select identities from remote clusters, and **global services** can load-balance across backends in all clusters.

### Requirements

Check these requirements before you connect any clusters, because each one prevents a specific failure:

| Requirement | Why |
|-------------|-----|
| Each cluster has a unique `cluster.name` and `cluster.id` (1–255) | Otherwise identities and IPs collide between clusters |
| Pod CIDRs do not overlap | Traffic must be routable between the clusters |
| Nodes in all clusters can reach each other and the clustermesh-apiserver | Both the datapath and the control plane depend on this |
| All clusters share the Cilium CA | The clustermesh components use mutual TLS, which needs a common CA |

### Setup

Install each cluster with its own name, ID and pod CIDR. Because the clusters must share a CA, copy cluster 1's CA Secret into cluster 2 before you install Cilium there. After that, enable the clustermesh-apiserver in both clusters and connect them:

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

To make a service global, create a Service with the **same name and namespace** in each cluster and add these annotations:

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

The backend can run only in cluster 2, and a client in cluster 1 can still resolve `backend.shop.svc.cluster.local`. This works as long as the Service object also exists in cluster 1, even if its selector matches nothing there.

To test it, call the service several times from a client in cluster 1, and then check the backends that the Cilium agent knows for the service:

```bash
kubectl --context kind-c1 -n shop exec deploy/client -- \
  sh -c 'for i in $(seq 10); do curl -s backend/; done'

kubectl --context kind-c1 -n kube-system exec ds/cilium -- cilium-dbg service list | grep -A4 <clusterIP>
```

### Troubleshooting Cluster Mesh

When the mesh does not work, start with these commands:

```bash
cilium clustermesh status --context kind-c1
kubectl --context kind-c1 -n kube-system exec ds/cilium -- cilium-dbg troubleshoot clustermesh
kubectl --context kind-c1 -n kube-system logs deploy/clustermesh-apiserver -c apiserver
kubectl --context kind-c1 -n kube-system exec ds/cilium -- cilium-dbg node list
```

Then match what you see against the most common causes:

| Symptom | Likely cause |
|---------|--------------|
| Status shows 0 remote nodes | The clustermesh-apiserver Service is not reachable, for example because it has no LB IP, the NodePort is wrong, or a firewall blocks it |
| TLS / certificate errors | The clusters do not share a CA because the `cilium-ca` Secret was not copied |
| Duplicate cluster ID error | The same `cluster.id` is used in two clusters |
| Global service only hits local backends | The annotation is missing in **one** of the clusters, or `affinity: local` is set and healthy local backends exist |
| Cross-cluster pod traffic dropped | The pod CIDRs overlap, or a policy does not allow the remote identity |

As an alternative to the annotations, newer Cilium versions also support the Kubernetes **Multi-Cluster Services API**, which uses `ServiceExport` / `ServiceImport` objects and `*.svc.clusterset.local` names.

Reference: [Cilium Cluster Mesh](https://docs.cilium.io/en/stable/network/clustermesh/clustermesh/)

---

## 5. Hands-on Checklist

- [ ] Explain why inference traffic needs an endpoint picker rather than round-robin load balancing
- [ ] Create an InferencePool for a set of model-server pods, then route `/v1/completions` to it
- [ ] Prove which backend pod served a given inference request
- [ ] Enable the Cilium BGP control plane and peer the cluster with an upstream router
- [ ] Advertise pod CIDRs and LoadBalancer IPs, and make sure they match the pod CIDRs the task gives you
- [ ] Verify that the BGP sessions are established and that the routes are visible on both sides
- [ ] Send one app's external traffic through an egress gateway node so that it leaves with a fixed source IP
- [ ] Prove the egress path with `cilium-dbg bpf egress list` and with the source IP that the server sees
- [ ] Connect two clusters with Cluster Mesh so that a client in one cluster reaches a backend in the other
- [ ] Control how a global service behaves with the `shared` and `affinity` annotations
- [ ] Diagnose a broken mesh connection from the `cilium clustermesh status` output
