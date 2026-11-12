# Certified Kubernetes Network Engineer (CKNE) Learning Path (2026)

![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.37-326CE5?logo=kubernetes&logoColor=white)
![Exam](https://img.shields.io/badge/CKNE-Exam%20Prep-green)
![Passing Score](https://img.shields.io/badge/Passing%20Score-67%25-blue)
![Duration](https://img.shields.io/badge/Duration-2%20Hours-orange)
![License](https://img.shields.io/badge/License-All%20Rights%20Reserved-red)

This is a structured, hands-on learning path for the **Certified Kubernetes Network Engineer (CKNE)** exam from the Linux Foundation and CNCF. It follows the official curriculum domain by domain, and for each topic it gives you the concept, working YAML, the commands to verify it, and the failures you should be able to fix.

---
## Hit the Star! :star:
If you plan to use this repo as a reference, please hit the star so that others can find it too. Thanks!

---

## CKNE Exam Coupon (40% Off Exclusive Discount)

You can save a flat 40% on CKNE exam registration by using the following coupon code.
> [!IMPORTANT]
> **Coupon:** Use code **40KUBE26CT** at [kube.promo/ckne](https://kube.promo/recommends/ckne/)

The same code, **40KUBE26CT**, also saves you up to 47% on the following bundles:

- CKA + CKAD: [kube.promo/cka-ckad](https://kube.promo/cka-ckad)
- CKA + CKS Bundle: [kube.promo/bundle](https://kube.promo/bundle)
- CKA + CKAD + CKS Exam bundle: [kube.promo/k8s-bundle](https://kube.promo/k8s-bundle)
- KCNA + KCSA + CKA + CKAD + CKS: [kube.promo/kubestronaut](https://kube.promo/kubestronaut)
---


## About the Exam

| Item | Detail |
|------|--------|
| **Format** | Online and proctored, with performance-based tasks in a Linux remote desktop |
| **Duration** | 2 hours |
| **Passing Score** | 67% |
| **Kubernetes Version** | v1.37 |
| **Results** | Sent to you by email within 24 hours |
| **Retake** | One retake is included |
| **Eligibility** | You have 12 months from purchase to take the exam |
| **Validity** | The certification is valid for 2 years |
| **Simulator** | Killer.sh, with 2 attempts and 36 hours of access for each one |

---

### Official Weightage per Domain

<details>
<summary><strong>1. Core Infrastructure and CNI (15%)</strong></summary>

- Installing and Configuring CNI Plugins
- Managing IPAM and Pod CIDR Allocation
- Using Linux Tools (iptables, ip, tcpdump) for Packet-level Issues
- Troubleshooting Pod Connectivity (DNS, pod-to-pod)
- Configuring Multi-interface Pods
</details>

<details>
<summary><strong>2. Service Networking and DNS (25%)</strong></summary>

- Configuring L4 Services
- Understanding kube-proxy and CNI Alternatives
- Customizing coreDNS for Services
- Troubleshooting Service Network Traffic
- Configuring Pod Endpoint Availability
- Managing Traffic with the Gateway API (Gateway, HTTPRoutes)
</details>

<details>
<summary><strong>3. Advanced Traffic Management (20%)</strong></summary>

- Optimizing LLM Traffic
- Implementing Routing to Expose Networks
- Configuring Egress Gateways for Cluster Exit Traffic
- Implementing Cross Cluster Service Discovery and Load Balancing
</details>

<details>
<summary><strong>4. Network Security and Policy (25%)</strong></summary>

- Securing Traffic with Network Policies
- Implementing Node and Pod Level Encryption
- Managing TLS Certificates for Gateway API
- Implementing Pod-level Authentication and Authorization
</details>

<details>
<summary><strong>5. Observability (15%)</strong></summary>

- Analyzing Network Health Using Metrics
- Troubleshooting End to End Network Performance with Tracing
- Auditing Traffic with Logs
</details>

---

## Syllabus and Study Notes

> **Source:** [CNCF CKNE Curriculum](https://github.com/cncf/curriculum/blob/main/CKNE_Curriculum.pdf)

| # | Domain | Weight | Study Notes | Key Tools & Topics |
|:-:|--------|:------:|:-----------:|--------------------|
| 1 | Core Infrastructure and CNI | **15%** | [Notes](./study-notes/01-core-infrastructure-cni.md) | Cilium install, kube-proxy-free mode, IPAM, Multus, `ip` / `iptables` / `tcpdump` |
| 2 | Service Networking and DNS | **25%** | [Notes](./study-notes/02-service-networking-dns.md) | Services, MetalLB, kube-router, CoreDNS, probes and endpoints, Gateway API, Envoy Gateway |
| 3 | Advanced Traffic Management | **20%** | [Notes](./study-notes/03-advanced-traffic-management.md) | Gateway API Inference Extension, BGP, Egress Gateway, Cluster Mesh |
| 4 | Network Security and Policy | **25%** | [Notes](./study-notes/04-network-security-policy.md) | NetworkPolicy, CiliumNetworkPolicy (L3/L4/L7), WireGuard, Gateway TLS, Istio ambient AuthorizationPolicy |
| 5 | Observability | **15%** | [Notes](./study-notes/05-observability.md) | Hubble, Prometheus, Jaeger, Envoy access logs |

> [!TIP]
> **Service Networking (25%)** and **Network Security (25%)** together make up half the exam, so plan most of your study time around them. Troubleshooting also shows up in every domain, which means that for each feature you build, you should also practise breaking it and then fixing it.

---

## The Learning Path

The domains build on each other, so study them in the order shown below. Every later topic assumes that you already have a working CNI, which is why the first week is spent building a Cilium cluster.

| Week | Focus | What you should be able to do at the end |
|:----:|-------|-------------------------------------------|
| 1 | Domain 1 | Install Cilium with kube-proxy replacement and BPF masquerading, and then debug pod-to-pod traffic and DNS using `ip`, `iptables` and `tcpdump` |
| 2 | Domain 2 | Expose apps with L4 Services and MetalLB, customise CoreDNS, fix broken endpoints and probes, and route HTTP traffic with Gateway API |
| 3 | Domain 4 | Write Kubernetes and Cilium L3/L4/L7 policies, enable WireGuard, terminate TLS on a Gateway, and secure workloads with Istio ambient |
| 4 | Domain 3 | Peer with a router over BGP, pin egress traffic to a gateway node, connect two clusters with Cluster Mesh, and route inference traffic with an InferencePool |
| 5 | Domain 5 | Use Hubble to find drops, Prometheus to find failing backends, Jaeger to find slow hops, and Envoy access logs to find bad clients |
| 6 | Review | Solve the practice tasks under time pressure, and only then use your Killer.sh sessions |

---

## 📚 CKNE Exam Detailed Study Guide

### [Core Infrastructure and CNI](#1-core-infrastructure-and-cni-15) `15%`

| # | Topic |
|---|-------|
| 1 | 🔌 [Installing and configuring CNI plugins](#installing-and-configuring-cni-plugins) |
| 2 | 🧮 [Managing IPAM and Pod CIDR allocation](#managing-ipam-and-pod-cidr-allocation) |
| 3 | 🛠️ [Using Linux tools for packet-level issues](#using-linux-tools-for-packet-level-issues) |
| 4 | 🔗 [Troubleshooting Pod connectivity](#troubleshooting-pod-connectivity) |
| 5 | 🧩 [Configuring multi-interface Pods](#configuring-multi-interface-pods) |

---

### [Service Networking and DNS](#2-service-networking-and-dns-25) `25%`

| # | Topic |
|---|-------|
| 1 | 🔀 [Configuring L4 Services](#configuring-l4-services) |
| 2 | ⚙️ [Understanding kube-proxy and CNI alternatives](#understanding-kube-proxy-and-cni-alternatives) |
| 3 | 🔍 [Customizing CoreDNS for Services](#customizing-coredns-for-services) |
| 4 | 🩺 [Configuring Pod endpoint availability](#configuring-pod-endpoint-availability) |
| 5 | 🚪 [Managing traffic with the Gateway API](#managing-traffic-with-the-gateway-api) |
| 6 | 🌐 [Troubleshooting Service network traffic](#troubleshooting-service-network-traffic) |

---

### [Advanced Traffic Management](#3-advanced-traffic-management-20) `20%`

| # | Topic |
|---|-------|
| 1 | 🤖 [Optimizing LLM traffic](#optimizing-llm-traffic) |
| 2 | 🛣️ [Implementing routing to expose networks](#implementing-routing-to-expose-networks) |
| 3 | 🚀 [Configuring egress gateways for cluster exit traffic](#configuring-egress-gateways-for-cluster-exit-traffic) |
| 4 | 🌍 [Implementing cross-cluster service discovery and load balancing](#implementing-cross-cluster-service-discovery-and-load-balancing) |

---

### [Network Security and Policy](#4-network-security-and-policy-25) `25%`

| # | Topic |
|---|-------|
| 1 | 🛡️ [Securing traffic with network policies](#securing-traffic-with-network-policies) |
| 2 | 🔐 [Implementing node and Pod level encryption](#implementing-node-and-pod-level-encryption) |
| 3 | 📜 [Managing TLS certificates for Gateway API](#managing-tls-certificates-for-gateway-api) |
| 4 | 🪪 [Implementing Pod-level authentication and authorization](#implementing-pod-level-authentication-and-authorization) |

---

### [Observability](#5-observability-15) `15%`

| # | Topic |
|---|-------|
| 1 | 📊 [Analyzing network health using metrics](#analyzing-network-health-using-metrics) |
| 2 | ⏱️ [Troubleshooting end-to-end network performance with tracing](#troubleshooting-end-to-end-network-performance-with-tracing) |
| 3 | 📋 [Auditing traffic with logs](#auditing-traffic-with-logs) |

---

## 1. Core Infrastructure and CNI (15%)

This section walks through each subtopic of the Core Infrastructure and CNI domain.

### Installing and configuring CNI plugins
> CNI Basics : Whenever a new Pod sandbox is created, the container runtime calls the CNI plugin with an `ADD` command, and the plugin sets up the Pod's network. The runtime finds the plugin through a config file in `/etc/cni/net.d/`. If there is more than one file there, the first one in alphabetical order wins, while the plugin binaries themselves live in `/opt/cni/bin/`. Until a CNI config exists, the node stays `NotReady`, which is why the CNI is the first thing you install on a new cluster.

```bash
# Check which CNI is active on a node
ls -l /etc/cni/net.d/
cat /etc/cni/net.d/05-cilium.conflist
```

> Install Cilium with the Cilium CLI : The `cilium install` command is a wrapper around the Cilium Helm chart, so you can pass any Helm value with `--set`. To run Cilium as a full kube-proxy replacement with eBPF masquerading, you also have to point it at the real API server address, because without kube-proxy Cilium cannot rely on the in-cluster Service IP to reach the API server.

```bash
# Install Cilium without kube-proxy, with eBPF masquerading
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=<API_SERVER_IP> \
  --set k8sServicePort=6443 \
  --set bpf.masquerade=true

# Check health and run the end-to-end test
cilium status --wait
cilium connectivity test

# Verify kube-proxy replacement and masquerading mode
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -E "KubeProxyReplacement|Masquerading"

# Change a setting on a running install, then restart the agents
cilium upgrade --reuse-values --set <key>=<value>
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout restart deploy/cilium-operator
```

> Removing kube-proxy : If an existing cluster already runs kube-proxy, first delete its DaemonSet and ConfigMap. Then flush the rules it left behind on every node, so that the old kube-proxy rules do not get in the way of Cilium.

```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy
iptables-save | grep -v KUBE | iptables-restore
```

### Managing IPAM and Pod CIDR allocation
> IPAM Modes : There are two IPAM modes you need to know. In `kubernetes` mode, Cilium uses the `spec.podCIDR` that is set on each node. In `cluster-pool` mode, which is the default, the Cilium operator carves a CIDR for each node out of `ipam.operator.clusterPoolIPv4PodCIDRList`. Whichever mode you use, the pod CIDR must not overlap the node network, the Service CIDR or the pods of another cluster in the mesh, because overlapping ranges make routing ambiguous.

```bash
# Kubernetes-level allocation
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR

# Cilium-level allocation
cilium config view | grep -i ipam
kubectl get ciliumnodes -o custom-columns=NAME:.metadata.name,CIDRS:.spec.ipam.podCIDRs

# Install with a specific pod CIDR
cilium install \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="10.10.0.0/16" \
  --set ipam.operator.clusterPoolIPv4MaskSize=24
```

> [!WARNING]
> Never edit the existing entries in `clusterPoolIPv4PodCIDRList`. If you need more addresses, only append new CIDRs to the list. Also note that `clusterPoolIPv4MaskSize` cannot be changed after install, so choose it carefully up front.

### Using Linux tools for packet-level issues
> tcpdump : In the exam, capture exactly what the task asks for, which usually means a specific interface, port, packet count and output file. Always add `-nn` so that tcpdump does not stall while it tries to resolve addresses through reverse DNS.

```bash
# Capture a fixed number of packets on an interface and port into a file
tcpdump -i eth0 -nn -c 100 -w /tmp/capture.pcap port 80

# Read the capture back
tcpdump -nn -r /tmp/capture.pcap

# Traffic going to one backend pod
tcpdump -i any -nn host <pod-ip> and tcp port 8080
```

> nsenter : Application images often do not include `ip` or `tcpdump`. In that case, find the container's process ID and use nsenter to run the node's own tools inside the pod's network namespace.

```bash
PID=$(crictl inspect <container-id> | jq .info.pid)
nsenter -t $PID -n ip addr
nsenter -t $PID -n tcpdump -i eth0 -nn
```

> iptables : Rules are evaluated from top to bottom, so their order matters. This means that a stray `DNAT`/`REDIRECT` rule placed above the Kubernetes chains, or a `DROP` rule whose packet counters keep growing, can break the traffic path.

```bash
iptables -t nat -L -n -v --line-numbers
iptables-save | grep <service-or-pod-ip>

# Delete a bad rule by line number
iptables -t nat -D PREROUTING <line-number>
```

> Latency : When a request is slow, first measure where the time goes, for example connection setup compared with time to first byte. Then check whether a delay has been injected on the network interface, and remove it if you find one.

```bash
curl -o /dev/null -s -w 'connect:%{time_connect} ttfb:%{time_starttransfer} total:%{time_total}\n' http://<svc>
tc qdisc show dev eth0
tc qdisc del dev eth0 root
```

### Troubleshooting Pod connectivity
> Bottom-up Approach : Work from the bottom of the stack upwards, so that each check rules out one layer before you move on. Start with the pod's IP and readiness, then test pod-to-pod traffic on the same node and across nodes. After that, test the Service, then DNS, then external access, and finally look for policy drops.

```bash
# Throwaway client with all the network tools
kubectl run netshoot --rm -it --image=nicolaka/netshoot -- bash

# Cilium's view of endpoints, health and live drops
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --all-health
kubectl -n kube-system exec ds/cilium -- cilium-dbg monitor --type drop

# DNS checks from inside a pod
kubectl exec -it <pod> -- cat /etc/resolv.conf
kubectl exec -it <pod> -- nslookup kubernetes.default
kubectl get endpointslices -n kube-system -l kubernetes.io/service-name=kube-dns
```

### Configuring multi-interface Pods
> Multus : With Multus, Cilium still provides the pod's main interface, `eth0`, while Multus attaches extra interfaces (`net1`, `net2`, ...) that you describe in a `NetworkAttachmentDefinition`. For this to work, install Cilium with `cni.exclusive=false`. Otherwise, Cilium renames the other CNI configs to `*.cilium_bak`, and the extra interfaces are never attached.

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-storage
spec:
  config: |
    {
      "cniVersion": "0.4.0",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.50.0/24"
      }
    }
---
apiVersion: v1
kind: Pod
metadata:
  name: dual-nic
  annotations:
    k8s.v1.cni.cncf.io/networks: macvlan-storage
spec:
  containers:
  - name: app
    image: nicolaka/netshoot
    command: ["sleep", "infinity"]
```

```bash
kubectl exec dual-nic -- ip -br addr
```

---

## 2. Service Networking and DNS (25%)

This section walks through each subtopic of the Service Networking and DNS domain.

### Configuring L4 Services
> Service Types : Practise all three Service types: ClusterIP, NodePort and LoadBalancer. Setting `externalTrafficPolicy: Local` preserves the client's source IP, but the trade-off is that only nodes with a local endpoint answer, because traffic is no longer forwarded to pods on other nodes.

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
  - port: 80
    targetPort: 8080
  externalTrafficPolicy: Local
```

> MetalLB : On bare metal there is nothing to hand out external IPs, so `LoadBalancer` Services stay `<pending>` until something allocates them. MetalLB fills this gap: you install it, give it a pool of addresses, and then advertise that pool.

```bash
kubectl apply -f https://raw.githubusercontent.com/metallb/metallb/v0.16.2/config/manifests/metallb-native.yaml
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
apiVersion: metallb.io/v1beta1
kind: L2Advertisement
metadata:
  name: lab-l2
  namespace: metallb-system
spec:
  ipAddressPools:
  - lab-pool
```

> External Services : To give an external IP a stable name inside the cluster, create a Service without a selector and then add an EndpointSlice that points to that IP. Keep in mind that when pods send traffic outside the cluster, it leaves with the node IP as its source address, which is called masquerading.

```yaml
apiVersion: v1
kind: Service
metadata:
  name: legacy-db
spec:
  ports:
  - name: pg
    port: 5432
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

### Understanding kube-proxy and CNI alternatives
> Service Implementations : Services can be implemented by several different components, so you need to know how to tell which one a cluster uses and where its rules live. The table below shows where to look for each one.

| Implementation | Where to look |
|----------------|---------------|
| kube-proxy `iptables` | `iptables-save -t nat \| grep KUBE-SVC` |
| kube-proxy `ipvs` (deprecated since v1.35) | `ipvsadm -Ln` |
| kube-proxy `nftables` | `nft list table ip kube-proxy` |
| Cilium kube-proxy replacement | `cilium-dbg service list` |
| kube-router | `gobgp neighbor`, `ipvsadm -Ln` |

```bash
# kube-proxy mode
kubectl -n kube-system get cm kube-proxy -o yaml | grep mode

# kube-router BGP sessions and service table
kubectl -n kube-system exec ds/kube-router -- gobgp neighbor
kubectl -n kube-system exec ds/kube-router -- ipvsadm -Ln
```

### Customizing CoreDNS for Services
> Corefile : CoreDNS reads its configuration from the `coredns` ConfigMap in `kube-system`. After you edit it, allow up to about 2 minutes for the change to apply, or restart the Deployment to apply it straight away. If you add a server block for a specific domain, it must sit at the top level of the Corefile, not nested inside `.:53 { }`.

```text
# Send all external lookups to a specific DNS server (inside .:53)
    forward . 10.0.0.53

# Send one domain to a dedicated DNS server (separate top-level block)
corp.example.com:53 {
    errors
    cache 30
    forward . 10.0.0.53
}
```

```bash
kubectl -n kube-system edit cm coredns
kubectl -n kube-system rollout restart deploy coredns
kubectl -n kube-system logs -l k8s-app=kube-dns
kubectl run dns-test --rm -it --image=busybox:1.36 --restart=Never -- nslookup app.corp.example.com
```

### Configuring Pod endpoint availability
> Probes and Endpoints : A Service only sends traffic to pods that are Ready. Readiness probes decide whether a pod is included as an endpoint, while liveness probes restart the container when it fails. So if a pod is running but receives no traffic, check its readiness first, and then compare the Service's selector and ports with the pod.

```yaml
readinessProbe:
  tcpSocket:
    port: 8080
  periodSeconds: 5
  failureThreshold: 3
livenessProbe:
  tcpSocket:
    port: 8080
  initialDelaySeconds: 10
```

```bash
# Endpoint ready / serving / terminating state
kubectl get endpointslices -l kubernetes.io/service-name=<svc> -o yaml | grep -A4 conditions

# Compare selector with labels, and targetPort with the listening port
kubectl get svc <svc> -o yaml
kubectl get pods --show-labels
kubectl exec <pod> -- ss -lntp
```

### Managing traffic with the Gateway API
> Gateway API : Three resources work together here. The `GatewayClass` names the controller, the `Gateway` defines the listeners, and the `HTTPRoute` maps request matches to backends. When a route does not work, read its `status.conditions`, because they tell you exactly what is wrong.

```bash
# Install Envoy Gateway (also installs the Gateway API CRDs)
helm install eg oci://docker.io/envoyproxy/gateway-helm --version v1.10.0 \
  -n envoy-gateway-system --create-namespace
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
    - name: api
      port: 8080
  - backendRefs:
    - name: frontend
      port: 80
```

```bash
kubectl get gatewayclass,gateway,httproute -A
kubectl -n web describe httproute shop
curl -s --resolve shop.example.com:80:<GW_IP> http://shop.example.com/api
```

### Troubleshooting Service network traffic
> Service Path : A request to a Service travels along this path: Client → DNS → Service IP → translation → EndpointSlice → Pod:targetPort, so check each step in that order. If the pod answers when you call it directly but the Service does not, the fault lies in the Service, its endpoints or the translation step.

```bash
kubectl exec client -- nslookup web.default.svc.cluster.local
kubectl get svc web -o wide
kubectl get endpointslices -l kubernetes.io/service-name=web
kubectl exec client -- curl -m3 <podIP>:<targetPort>
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list | grep <clusterIP>
hubble observe -n default --to-label app=web --verdict DROPPED
```

---

## 3. Advanced Traffic Management (20%)

This section walks through each subtopic of the Advanced Traffic Management domain.

### Optimizing LLM traffic
> Gateway API Inference Extension : An `InferencePool` groups model-server pods and points to an Endpoint Picker (EPP), which uses live metrics to choose the best pod for each request. You then use the pool as an HTTPRoute backend in place of a Service. Before you write the YAML, check which API version the cluster serves with `kubectl explain inferencepool.spec`, so that your manifest matches it.

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
---
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

```bash
kubectl -n inference describe httproute llm-route
curl -s http://<GW_IP>/v1/completions \
  -H 'Content-Type: application/json' \
  -d '{"model":"<model-name>","prompt":"Hello","max_tokens":20}'
```

### Implementing routing to expose networks
> Cilium BGP : With BGP, Cilium advertises pod CIDRs and Service IPs to an upstream router, so that the outside network knows how to reach them. The configuration links three resources together in a chain: ClusterConfig → PeerConfig → Advertisement. None of this works until you enable the feature with `bgpControlPlane.enabled=true`.

```yaml
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
apiVersion: cilium.io/v2
kind: CiliumBGPPeerConfig
metadata:
  name: tor-peer-config
spec:
  families:
  - afi: ipv4
    safi: unicast
    advertisements:
      matchLabels:
        advertise: "bgp"
---
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
cilium bgp peers
cilium bgp routes advertised ipv4 unicast
```

### Configuring egress gateways for cluster exit traffic
> Egress Gateway : An egress gateway sends the external traffic of selected pods through a gateway node, so that it leaves the cluster with a fixed source IP. For this to work, Cilium needs `egressGateway.enabled=true`, `bpf.masquerade=true` and `kubeProxyReplacement=true`. Also note that the `egressIP` must already exist on the gateway node before you apply the policy.

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
  egressGateway:
    nodeSelector:
      matchLabels:
        egress-gw: "true"
    egressIP: 172.18.0.50
```

```bash
kubectl label node <gateway-node> egress-gw=true
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf egress list
kubectl -n payments exec deploy/billing -- curl -s http://203.0.113.20/whoami
```

### Implementing cross-cluster service discovery and load balancing
> Cluster Mesh : Before you connect clusters, make sure each one has a unique `cluster.name` and `cluster.id`, that their pod CIDRs do not overlap, and that they share the same Cilium CA. Once they are connected, a Service that has the same name and namespace in both clusters and is annotated with `service.cilium.io/global: "true"` load-balances across both of them.

```bash
# Share cluster 1's CA with cluster 2 before installing there
kubectl --context c1 get secret -n kube-system cilium-ca -o yaml | \
  kubectl --context c2 create -f -

cilium clustermesh enable --context c1 --service-type LoadBalancer
cilium clustermesh enable --context c2 --service-type LoadBalancer
cilium clustermesh connect --context c1 --destination-context c2
cilium clustermesh status --context c1 --wait
```

```yaml
apiVersion: v1
kind: Service
metadata:
  name: backend
  namespace: shop
  annotations:
    service.cilium.io/global: "true"
    service.cilium.io/affinity: "local"
spec:
  selector:
    app: backend
  ports:
  - port: 80
```

---

## 4. Network Security and Policy (25%)

This section walks through each subtopic of the Network Security and Policy domain.

### Securing traffic with network policies
> NetworkPolicy vs CiliumNetworkPolicy : A Kubernetes NetworkPolicy works only at L3/L4 and can only allow traffic. A CiliumNetworkPolicy goes further and adds L7 (HTTP, DNS) rules, FQDN rules, entities and explicit deny rules. Be careful with a default-deny egress policy, because it also blocks DNS, so always re-allow traffic to `kube-dns`.

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

> L7 Policy : The two kinds of denial look different from the client side, which helps when you debug. A request that matches the L4 rule but not the HTTP rule gets a `403 Access denied` response, whereas an L3/L4 drop shows up as a timeout.

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
```

```bash
kubectl get netpol,cnp -A
hubble observe -n shop --verdict DROPPED
```

### Implementing node and Pod level encryption
> WireGuard : When WireGuard is enabled, Cilium encrypts pod traffic between nodes and sends it over the `cilium_wg0` interface (UDP 51871). If you also want traffic between the nodes themselves to be encrypted, add `encryption.nodeEncryption=true`.

```bash
cilium upgrade --reuse-values --set encryption.enabled=true --set encryption.type=wireguard
kubectl -n kube-system rollout restart ds/cilium

kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep Encryption
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status

# On a node: cross-node pod traffic appears only as UDP 51871
tcpdump -i eth0 -nn udp port 51871 -c 10
```

### Managing TLS certificates for Gateway API
> HTTPS Listener : To serve HTTPS, store the certificate in a `kubernetes.io/tls` Secret and reference it from the Gateway listener. If the Secret is in a different namespace from the Gateway, you also need a `ReferenceGrant` to allow that reference. Instead of creating the Secret by hand, you can also let cert-manager issue it for you.

```bash
kubectl -n web create secret tls shop-tls --cert=tls.crt --key=tls.key
```

```yaml
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
```

```bash
curl -vk --resolve shop.example.com:443:<GW_IP> https://shop.example.com/
openssl s_client -connect <GW_IP>:443 -servername shop.example.com </dev/null 2>/dev/null \
  | openssl x509 -noout -subject -dates
```

### Implementing Pod-level authentication and authorization
> Istio Ambient : In ambient mode, ztunnel gives every enrolled pod mTLS and a SPIFFE identity at L4. When you need L7 features, you add a waypoint on top. To accept only mesh traffic, set a `PeerAuthentication` to `STRICT`, which rejects clients that are not part of the mesh.

```bash
istioctl install --set profile=ambient --skip-confirmation
kubectl label namespace shop istio.io/dataplane-mode=ambient
istioctl waypoint apply -n shop --enroll-namespace --wait
istioctl ztunnel-config workloads
```

> AuthorizationPolicy : How you attach the policy decides who enforces it. Use `selector` for L4 rules, which ztunnel enforces, and use `targetRefs` pointing to a Service for L7 rules, which the waypoint enforces. You can tell the two apart when debugging, because L7 denials return `RBAC: access denied`, while L4 denials reset the connection.

```yaml
apiVersion: security.istio.io/v1
kind: PeerAuthentication
metadata:
  name: strict
  namespace: shop
spec:
  mtls:
    mode: STRICT
---
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
```

---

## 5. Observability (15%)

This section walks through each subtopic of the Observability domain.

### Analyzing network health using metrics
> Hubble : Hubble records every network flow together with its verdict and, for dropped packets, the drop reason. You can use either the CLI or the service map in the Hubble UI to find out where traffic is being dropped.

```bash
cilium hubble port-forward &
hubble observe --verdict DROPPED
hubble observe --from-pod shop/frontend --to-pod shop/api
hubble observe --protocol http --http-status 5+
hubble observe --protocol dns
```

> Prometheus : Start with broad queries that tell you which service has a problem, and then narrow down to the workload and finally the pod.

```promql
up == 0
sum by (reason) (rate(hubble_drop_total[5m]))
sum by (destination_service) (rate(istio_requests_total{response_code=~"5.."}[5m]))
histogram_quantile(0.99, sum by (le, destination_service) (rate(istio_request_duration_milliseconds_bucket[5m])))
sum by (rcode) (rate(coredns_dns_responses_total{rcode=~"SERVFAIL|NXDOMAIN"}[5m]))
```

### Troubleshooting end-to-end network performance with tracing
> Jaeger : A trace is a tree of spans, with one span for each hop the request takes. Sort the traces with the longest first, open a slow one, and find the span that holds most of the time. If a parent span is long but its children are short, the time is being spent inside that service itself. Note that in ambient mode, spans come from waypoints and gateways, not from ztunnel.

### Auditing traffic with logs
> Envoy Access Logs : Envoy Gateway writes access logs in JSON, and each entry records the path, status, response flags, user agent and client IP. This makes the logs a good place to find out who is sending bad traffic to a particular path.

```bash
kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=<gw> -c envoy --tail=-1 \
  | jq -R -r 'fromjson? | select((."x-envoy-origin-path" // "") | startswith("/api/login"))
      | select((.response_code|tonumber) >= 400) | ."user-agent"' \
  | sort | uniq -c | sort -rn

kubectl -n envoy-gateway-system logs deploy/envoy-gateway
kubectl -n istio-system logs -l app=ztunnel | grep -iE "policy rejection|denied"
```

| Envoy flag | Meaning |
|------------|---------|
| `UH` | No healthy upstream hosts |
| `UF` | Upstream connection failure |
| `UT` | Upstream request timeout |
| `NR` | No route configured |

---

## Repository Contents

| File | Purpose |
|------|---------|
| [study-notes/](./study-notes/) | One file per exam domain, covering concepts, YAML, verification and troubleshooting |
| [PRACTICE_QUESTIONS.md](./PRACTICE_QUESTIONS.md) | Exam-style scenario tasks, with the solutions hidden until you open them |
| [CHEATSHEET.md](./CHEATSHEET.md) | A one-page command reference for every tool used in the exam |
| [EXAM_GUIDE.md](./EXAM_GUIDE.md) | What the exam environment looks like, how to approach exam day, and FAQs |

---

## Official Resources

| Resource | Link |
|----------|------|
| CKNE Certification Page | [training.linuxfoundation.org](https://training.linuxfoundation.org/certification/certified-kubernetes-network-engineer-ckne/) |
| Candidate Handbook | [docs.linuxfoundation.org](https://docs.linuxfoundation.org/tc-docs/certification/lf-handbook2) |
| Kubernetes Networking Concepts | [kubernetes.io](https://kubernetes.io/docs/concepts/cluster-administration/networking/) |
| Killer.sh Simulator | [killer.sh](https://killer.sh) |

---

## Contributing

Corrections and additions are welcome. Please read [CONTRIBUTING.md](./CONTRIBUTING.md) to see how to contribute.

> ⭐ If this guide helped you, please star the repo!
