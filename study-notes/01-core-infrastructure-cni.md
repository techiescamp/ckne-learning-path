# Domain 1: Core Infrastructure and CNI (15%)

> **Exam Weight: 15%**: CNI installation, IPAM, Linux packet tools, pod connectivity and multi-interface pods.

Everything else in the CKNE builds on this domain. Gateway API, encryption, BGP, egress gateways and Cluster Mesh all assume you can stand up a CNI, confirm it is healthy, and trace a packet when it is not.

## Index

1. [How CNI Works](#1-how-cni-works)
2. [Installing Cilium with the Cilium CLI](#2-installing-cilium-with-the-cilium-cli)
3. [kube-proxy Replacement and BPF Masquerading](#3-kube-proxy-replacement-and-bpf-masquerading)
4. [IPAM and Pod CIDR Allocation](#4-ipam-and-pod-cidr-allocation)
5. [Linux Tools for Packet-level Issues](#5-linux-tools-for-packet-level-issues)
6. [Troubleshooting Pod Connectivity](#6-troubleshooting-pod-connectivity)
7. [Multi-interface Pods with Multus](#7-multi-interface-pods-with-multus)
8. [Hands-on Checklist](#8-hands-on-checklist)

---

## 1. How CNI Works

When kubelet creates a Pod sandbox, the container runtime calls the CNI plugin binary with `ADD`, passing the network namespace path. The plugin creates the interface (usually a veth pair), assigns an IP from IPAM and programs routes. `DEL` reverses this when the Pod is deleted.

| Location | What lives there |
|----------|------------------|
| `/etc/cni/net.d/` | CNI config files. The runtime uses the **first file in lexical order** |
| `/opt/cni/bin/` | Plugin binaries (`cilium-cni`, `bridge`, `host-local`, `macvlan`, ...) |
| `/var/run/netns/` or `/proc/<pid>/ns/net` | Pod network namespaces |

```bash
# Which CNI is active on this node?
ls -l /etc/cni/net.d/
cat /etc/cni/net.d/05-cilium.conflist

# Nodes stay NotReady until a CNI config exists
kubectl get nodes
kubectl describe node <node> | grep -i -A3 "NetworkReady\|Ready"
```

> [!IMPORTANT]
> A leftover config from a previous CNI (for example `10-flannel.conflist`) that sorts **before** the one you want will win. When pods get IPs from the wrong range, look in `/etc/cni/net.d/` first.

Reference: [CNI Specification](https://github.com/containernetworking/cni/blob/main/SPEC.md)

---

## 2. Installing Cilium with the Cilium CLI

```bash
# Install the Cilium CLI (Linux amd64)
CILIUM_CLI_VERSION=$(curl -s https://raw.githubusercontent.com/cilium/cilium-cli/main/stable.txt)
CLI_ARCH=amd64
curl -L --fail --remote-name-all https://github.com/cilium/cilium-cli/releases/download/${CILIUM_CLI_VERSION}/cilium-linux-${CLI_ARCH}.tar.gz{,.sha256sum}
sha256sum --check cilium-linux-${CLI_ARCH}.tar.gz.sha256sum
sudo tar xzvfC cilium-linux-${CLI_ARCH}.tar.gz /usr/local/bin

# Basic install (uses the current kubectl context)
cilium install

# Wait for it to be healthy
cilium status --wait

# End-to-end validation (creates a cilium-test-1 namespace)
cilium connectivity test
```

`cilium install` is a wrapper around the Helm chart, so any Helm value can be passed with `--set`. `cilium config view` shows the agent ConfigMap (`cilium-config`), and `helm get values` shows the Helm values you supplied:

```bash
cilium config view
helm get values cilium -n kube-system
```

Change settings on a running install with `cilium upgrade --reuse-values --set <key>=<value>` (or `helm upgrade ... --reuse-values`), then restart the agents. Use `--reuse-values` only for config changes on the same Cilium version, not for version upgrades:

```bash
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout restart deploy/cilium-operator
```

Reference: [Cilium Quick Installation](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/)

---

## 3. kube-proxy Replacement and BPF Masquerading

With **kube-proxy replacement (KPR)**, Cilium implements ClusterIP, NodePort, LoadBalancer, externalIPs and hostPort in eBPF, so there are no `KUBE-SVC-*` iptables chains. Because kube-proxy is not there to reach the API server through the `kubernetes` ClusterIP, Cilium must be told the real API server address.

```bash
# Find the API server address
kubectl get endpointslices -n default -l kubernetes.io/service-name=kubernetes

# Install Cilium as a full kube-proxy replacement with BPF masquerading
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=<API_SERVER_IP> \
  --set k8sServicePort=6443 \
  --set bpf.masquerade=true
```

On a cluster that already runs kube-proxy, remove it **before** (or right after) switching:

```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy
# On every node, flush the rules kube-proxy left behind
iptables-save | grep -v KUBE | iptables-restore
```

On a new kubeadm cluster, skip kube-proxy entirely with `kubeadm init --skip-phases=addon/kube-proxy`.

**Verify:**

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -E "KubeProxyReplacement|Masquerading"
#   KubeProxyReplacement:   True   [eth0 ...]
#   Masquerading:           BPF    [eth0]   10.0.0.0/8 [IPv4: Enabled ...]

# The eBPF service table replaces KUBE-SVC chains
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
```

| Masquerading mode | How SNAT for pod→outside traffic is done | Setting |
|-------------------|------------------------------------------|---------|
| iptables (default) | `CILIUM_POST_nat` chain in the nat table | `bpf.masquerade=false` |
| eBPF | Directly in eBPF on the native device | `bpf.masquerade=true` (depends on eBPF NodePort, i.e. KPR) |

Only traffic leaving through a native (non-Cilium) device is masqueraded to the node IP. It is **not** masqueraded when the destination is in the local node's pod CIDR, inside `ipv4NativeRoutingCIDR` (if set), or, in eBPF mode, another cluster node. The Egress Gateway in Domain 3 builds on this and changes the source IP to a chosen gateway IP.

Reference: [Kubernetes Without kube-proxy](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)

---

## 4. IPAM and Pod CIDR Allocation

| Layer | Where the Pod CIDR comes from |
|-------|-------------------------------|
| Cluster | `kube-controller-manager --cluster-cidr` and `--allocate-node-cidrs=true` (kubeadm `networking.podSubnet`) |
| Node | `node.spec.podCIDR(s)`, assigned by the controller manager |
| Cilium `ipam.mode=kubernetes` | Uses `node.spec.podCIDR` |
| Cilium `ipam.mode=cluster-pool` (default) | Cilium operator carves per-node CIDRs from `ipam.operator.clusterPoolIPv4PodCIDRList` |
| Cilium `ipam.mode=multi-pool` | Multiple `CiliumPodIPPool` objects, selected per namespace or pod via annotation |

```bash
# Kubernetes-level allocation
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR
kubectl -n kube-system get pod -l component=kube-controller-manager -o yaml | grep -i cluster-cidr

# Cilium-level allocation
cilium config view | grep -i ipam
kubectl get ciliumnodes -o custom-columns=NAME:.metadata.name,CIDRS:.spec.ipam.podCIDRs
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | grep -A5 "IPAM"
```

```bash
# Install with a specific pod CIDR (cluster-pool mode)
cilium install \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="10.10.0.0/16" \
  --set ipam.operator.clusterPoolIPv4MaskSize=24
```

> [!WARNING]
> The pod CIDR must not overlap the node network, the Service CIDR or, for Cluster Mesh, the other cluster's pod CIDR. Never edit existing entries in `clusterPoolIPv4PodCIDRList`; you can only append new CIDRs. `clusterPoolIPv4MaskSize` cannot be changed after install, and the IPAM mode of a live cluster should not be changed.

**Symptoms of IPAM trouble:** pods stuck in `ContainerCreating` and IP allocation errors in `kubectl describe pod`. Check the per-node pool size against `maxPods`. A `/24` gives about 252 pod IPs, because Cilium reserves addresses for its router and health endpoint.

Reference: [Cilium IPAM](https://docs.cilium.io/en/stable/network/concepts/ipam/)

---

## 5. Linux Tools for Packet-level Issues

### Inspect interfaces and routes: `ip`

```bash
ip -br addr
ip route
ip route get 10.10.1.23
ip -d link show cilium_vxlan
ip neigh
```

### Enter a Pod's network namespace from the node

Many app images ship without `ip` or `tcpdump`. Run the node's tools inside the pod's namespace instead:

```bash
# Find the pod's PID through the runtime
crictl ps --name <container-name>
PID=$(crictl inspect <container-id> | jq .info.pid)

nsenter -t $PID -n ip addr
nsenter -t $PID -n tcpdump -i eth0 -nn

# Or attach a debug container that shares the pod's network namespace
kubectl debug -it <pod> --image=nicolaka/netshoot --target=<container>
```

### Capture traffic: `tcpdump`

| Need | Command |
|------|---------|
| Specific interface and port | `tcpdump -i eth0 -nn port 8080` |
| Fixed number of packets | `tcpdump -i eth0 -nn -c 20 port 80` |
| Write to a file | `tcpdump -i eth0 -nn -c 100 -w /tmp/capture.pcap port 80` |
| Read a file back | `tcpdump -nn -r /tmp/capture.pcap` |
| Traffic to one backend pod | `tcpdump -i any -nn host 10.10.1.23 and tcp port 8080` |
| Only SYNs (connection attempts) | `tcpdump -i any -nn 'tcp[tcpflags] & (tcp-syn|tcp-ack) == tcp-syn'` |
| DNS queries | `tcpdump -i any -nn udp port 53` |
| Print payload (HTTP) | `tcpdump -i any -nn -A port 80` |

> [!TIP]
> Always use `-nn` so tcpdump does not stall on reverse DNS. When a task gives an exact packet count, output file path or interface, use exactly those. The result is usually checked by reading the file you wrote.

### Read NAT and filter rules: `iptables`

```bash
iptables -t nat -L -n -v --line-numbers
iptables -t filter -L FORWARD -n -v
iptables-save | grep <service-or-pod-ip>
iptables-save -t nat | grep KUBE-SVC

# Remove a bad rule by line number
iptables -t nat -D PREROUTING 3
```

How to read a NAT problem:

1. `PREROUTING` → `KUBE-SERVICES` → `KUBE-SVC-xxx` → `KUBE-SEP-xxx` holds the `DNAT --to-destination <podIP>:<port>`. A wrong port or IP there sends traffic to the wrong place.
2. A manually inserted `DNAT` or `REDIRECT` **above** the Kubernetes jump will take precedence. Rules are evaluated top-down.
3. A `DROP` or `REJECT` in `FORWARD` or `INPUT` with growing packet counters is your culprit. Watch the counters change with `watch -n1 'iptables -L FORWARD -n -v'`.
4. `MASQUERADE` / `SNAT` in `POSTROUTING` decides the source IP leaving the node.

Also check `sysctl net.ipv4.ip_forward`. It must be `1` on nodes that forward pod traffic.

### Network delay and latency

```bash
# Measure where the time goes
curl -o /dev/null -s -w 'dns:%{time_namelookup} connect:%{time_connect} tls:%{time_appconnect} ttfb:%{time_starttransfer} total:%{time_total}\n' http://<svc>

# Look for artificial delay or loss on an interface (tc netem)
tc qdisc show dev eth0
#   qdisc netem 8001: root refcnt 2 limit 1000 delay 300ms
tc qdisc del dev eth0 root

# Other places latency hides
ss -tni
ethtool -S eth0 | grep -i drop
```

---

## 6. Troubleshooting Pod Connectivity

Work from the bottom up and change one thing at a time.

```text
1. Pod has an IP and is Ready?            kubectl get pod -o wide
2. Same-node pod-to-pod works?            kubectl exec a -- curl -m3 <podB-IP>:<port>
3. Cross-node pod-to-pod works?           (tunnel / routing / MTU / encryption)
4. Pod-to-Service ClusterIP works?        (service translation, endpoints)
5. DNS resolves the service name?         nslookup <svc>.<ns>.svc.cluster.local
6. Pod-to-external works?                 (masquerading, egress policy, node routes)
7. Is a policy dropping it?               hubble observe --verdict DROPPED
```

```bash
# Throwaway client pod with all the tools
kubectl run netshoot --rm -it --image=nicolaka/netshoot -- bash

# Cilium's view of endpoints and health
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --all-health
cilium status

# Drops in real time on a node
kubectl -n kube-system exec ds/cilium -- cilium-dbg monitor --type drop
```

### DNS checks from inside a Pod

```bash
kubectl exec -it <pod> -- cat /etc/resolv.conf
kubectl exec -it <pod> -- nslookup kubernetes.default
kubectl exec -it <pod> -- nslookup example.com
kubectl get svc -n kube-system kube-dns
kubectl get endpointslices -n kube-system -l kubernetes.io/service-name=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
```

| Symptom | Likely cause |
|---------|--------------|
| Cluster names fail, IPs work | CoreDNS down, kube-dns Service has no endpoints, or a policy blocks UDP/TCP 53 |
| Cluster names work, external fail | CoreDNS `forward` target wrong or unreachable (see Domain 2) |
| Intermittent timeouts | One CoreDNS replica unhealthy, conntrack races, or MTU |
| Large responses fail | MTU mismatch (tunnel overhead or WireGuard) |
| Pod `dnsPolicy` wrong | `Default` uses the node's resolver, not CoreDNS |

Reference: [Debugging DNS Resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)

---

## 7. Multi-interface Pods with Multus

Multus is a "meta" CNI. The primary CNI (Cilium) still provides `eth0`, and Multus attaches extra interfaces (`net1`, `net2`, ...) described by `NetworkAttachmentDefinition` objects.

> [!NOTE]
> When running alongside Cilium, install Cilium with `--set cni.exclusive=false`. Otherwise Cilium renames other CNI configs in `/etc/cni/net.d/` to `*.cilium_bak`.

```yaml
apiVersion: k8s.cni.cncf.io/v1
kind: NetworkAttachmentDefinition
metadata:
  name: macvlan-storage
  namespace: default
spec:
  config: |
    {
      "cniVersion": "0.4.0",
      "type": "macvlan",
      "master": "eth0",
      "mode": "bridge",
      "ipam": {
        "type": "host-local",
        "subnet": "192.168.50.0/24",
        "rangeStart": "192.168.50.100",
        "rangeEnd": "192.168.50.150"
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
kubectl get network-attachment-definitions
kubectl exec dual-nic -- ip -br addr
kubectl get pod dual-nic -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
```

The plugin named in `"type"` must exist in `/opt/cni/bin/` on every node. If it does not, the pod stays in `ContainerCreating` and the event names the missing binary.

Reference: [Multus CNI Quickstart](https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/quickstart.md)

---

## 8. Hands-on Checklist

You are ready for this domain when you can do each of these without notes:

- [ ] Install Cilium with the Cilium CLI on a cluster that has no CNI, then confirm `cilium status` is all green
- [ ] Run Cilium as the only service proxy (no kube-proxy) and show that `KubeProxyReplacement: True`
- [ ] Turn on eBPF masquerading and prove it from the agent status output
- [ ] Explain which traffic gets SNATed to the node IP and which does not
- [ ] Read a node's pod CIDR from both the Node object and the CiliumNode
- [ ] Capture N packets on a given interface and port into a `.pcap` file, then read it back
- [ ] Use `nsenter` or `kubectl debug` to sniff traffic arriving at one backend pod
- [ ] Find and delete a stray DNAT/DROP rule that breaks a service path
- [ ] Spot and remove an injected `tc netem` delay
- [ ] Attach a second interface to a pod with Multus
