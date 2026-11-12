# Domain 1: Core Infrastructure and CNI (15%)

> **Exam Weight: 15%**: This domain covers installing a CNI, managing IPAM, using Linux tools to debug packet-level issues, troubleshooting pod connectivity and running pods with more than one network interface.

Everything else in the CKNE builds on this domain. Gateway API, encryption, BGP, egress gateways and Cluster Mesh all assume a few basic skills. You can set up a CNI, check that it is healthy, and trace a packet when something breaks. Once these basics are solid, the later domains get much easier.

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

When kubelet creates a Pod sandbox, the container runtime calls the CNI plugin binary with the `ADD` command. It also passes the path of the Pod's network namespace. The plugin then creates the network interface (usually a veth pair). It gets an IP address for the Pod from IPAM and sets up the routes the Pod needs. When the Pod is deleted, the runtime calls the plugin with `DEL`, which undoes all of this.

The runtime and the plugin rely on a few fixed locations on each node:

| Location | What lives there |
|----------|------------------|
| `/etc/cni/net.d/` | The CNI config files. If there is more than one, the runtime uses the **first file in lexical order** |
| `/opt/cni/bin/` | The plugin binaries, such as `cilium-cni`, `bridge`, `host-local` and `macvlan` |
| `/var/run/netns/` or `/proc/<pid>/ns/net` | The network namespaces of the Pods |

```bash
# Which CNI is active on this node?
ls -l /etc/cni/net.d/
cat /etc/cni/net.d/05-cilium.conflist

# Nodes stay NotReady until a CNI config exists
kubectl get nodes
kubectl describe node <node> | grep -i -A3 "NetworkReady\|Ready"
```

> [!IMPORTANT]
> The runtime picks the first file in lexical order. So a leftover config from an old CNI (for example `10-flannel.conflist`) wins if it sorts **before** the one you want. If pods get IPs from the wrong range, look in `/etc/cni/net.d/` first.

Reference: [CNI Specification](https://github.com/containernetworking/cni/blob/main/SPEC.md)

---

## 2. Installing Cilium with the Cilium CLI

The quickest way to get Cilium running is with the Cilium CLI. First install the CLI. Then use it to install Cilium, wait until Cilium is healthy, and run the built-in connectivity test:

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

`cilium install` uses the Cilium Helm chart under the hood, so you can pass any Helm value with `--set`. To see what is really configured, use two commands. `cilium config view` shows the agent ConfigMap (`cilium-config`). `helm get values` shows the Helm values you supplied:

```bash
cilium config view
helm get values cilium -n kube-system
```

To change settings on a running install, use `cilium upgrade --reuse-values --set <key>=<value>` (or `helm upgrade ... --reuse-values`). Only use `--reuse-values` when the chart version stays the same, so for config changes and not for version upgrades. The agents only pick up the new config after a restart, so restart them afterwards:

```bash
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system rollout restart deploy/cilium-operator
```

Reference: [Cilium Quick Installation](https://docs.cilium.io/en/stable/gettingstarted/k8s-install-default/)

---

## 3. kube-proxy Replacement and BPF Masquerading

With **kube-proxy replacement (KPR)**, Cilium handles ClusterIP, NodePort, LoadBalancer, externalIPs and hostPort in eBPF. So the node no longer has any `KUBE-SVC-*` iptables chains. This creates a chicken-and-egg problem, though. Without kube-proxy, nothing translates the `kubernetes` ClusterIP, so Cilium cannot use it to reach the API server. That is why you must give Cilium the real API server address.

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

If the cluster already runs kube-proxy, remove it **before** you switch (or right after), so its rules do not compete with Cilium. Removing kube-proxy breaks existing Service connections, so expect a short disruption:

```bash
kubectl -n kube-system delete ds kube-proxy
kubectl -n kube-system delete cm kube-proxy
# On every node, flush the rules kube-proxy left behind
iptables-save | grep -v KUBE | iptables-restore
```

On a new kubeadm cluster, you can avoid this cleanup by skipping kube-proxy entirely with `kubeadm init --skip-phases=addon/kube-proxy`.

**Verify:**

Check the agent status to confirm that both features are on. Then look at the eBPF service table:

```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -E "KubeProxyReplacement|Masquerading"
#   KubeProxyReplacement:   True   [eth0 ...]
#   Masquerading:           BPF    [eth0]   10.0.0.0/8 [IPv4: Enabled ...]

# The eBPF service table replaces KUBE-SVC chains
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
```

Cilium can do the masquerading (SNAT) of traffic leaving the cluster in two ways:

| Masquerading mode | How SNAT for pod→outside traffic is done | Setting |
|-------------------|------------------------------------------|---------|
| iptables (default) | Through the `CILIUM_POST_nat` chain in the nat table | `bpf.masquerade=false` |
| eBPF | Directly in eBPF on the native device | `bpf.masquerade=true` (it depends on the eBPF NodePort feature, which KPR turns on) |

Only traffic that leaves through a native (non-Cilium) device is masqueraded to the node IP. Traffic is **not** masqueraded in these cases:

- The destination is in the local node's pod CIDR.
- The destination is inside `ipv4NativeRoutingCIDR`, if that is set.
- In eBPF mode, the destination is another node of the cluster.

The Egress Gateway in Domain 3 builds on this. It changes the source IP to a gateway IP that you choose.

Reference: [Kubernetes Without kube-proxy](https://docs.cilium.io/en/stable/network/kubernetes/kubeproxy-free/)

---

## 4. IPAM and Pod CIDR Allocation

Pod IP ranges come from Kubernetes or from Cilium, depending on the IPAM mode. The table shows where the Pod CIDR comes from at each layer:

| Layer | Where the Pod CIDR comes from |
|-------|-------------------------------|
| Cluster | `kube-controller-manager --cluster-cidr` together with `--allocate-node-cidrs=true` (in kubeadm, this is `networking.podSubnet`) |
| Node | `node.spec.podCIDR(s)`, which the controller manager assigns |
| Cilium `ipam.mode=kubernetes` | Cilium uses the `node.spec.podCIDR` that Kubernetes assigned |
| Cilium `ipam.mode=cluster-pool` (default) | The Cilium operator carves per-node CIDRs out of `ipam.operator.clusterPoolIPv4PodCIDRList` |
| Cilium `ipam.mode=multi-pool` | Several `CiliumPodIPPool` objects, and each namespace or pod selects one through an annotation |

```bash
# Kubernetes-level allocation
kubectl get nodes -o custom-columns=NAME:.metadata.name,PODCIDR:.spec.podCIDR
kubectl -n kube-system get pod -l component=kube-controller-manager -o yaml | grep -i cluster-cidr

# Cilium-level allocation
cilium config view | grep -i ipam
kubectl get ciliumnodes -o custom-columns=NAME:.metadata.name,CIDRS:.spec.ipam.podCIDRs
kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose | grep -A5 "IPAM"
```

If you need a specific pod CIDR, set it at install time:

```bash
# Install with a specific pod CIDR (cluster-pool mode)
cilium install \
  --set ipam.mode=cluster-pool \
  --set ipam.operator.clusterPoolIPv4PodCIDRList="10.10.0.0/16" \
  --set ipam.operator.clusterPoolIPv4MaskSize=24
```

> [!WARNING]
> The pod CIDR must not overlap the node network or the Service CIDR. With Cluster Mesh, it must not overlap the other cluster's pod CIDR either. After install, never edit the existing entries in `clusterPoolIPv4PodCIDRList`. If the pool runs out, add a new CIDR to the list instead. You also cannot change `clusterPoolIPv4MaskSize` after install. And do not change the IPAM mode of a live cluster.

**Symptoms of IPAM trouble:** pods get stuck in `ContainerCreating`, and `kubectl describe pod` shows IP allocation errors. When you see this, compare the size of the per-node pool with `maxPods`. A `/24` has 256 addresses, but not all of them go to pods. The allocator reserves the network and broadcast addresses. Cilium also takes IPs from the same pool for its own endpoints, such as the health endpoint.

Reference: [Cilium IPAM](https://docs.cilium.io/en/stable/network/concepts/ipam/)

---

## 5. Linux Tools for Packet-level Issues

### Inspect interfaces and routes: `ip`

Start with `ip` to see which interfaces exist, which addresses they have and which route a packet will take:

```bash
ip -br addr
ip route
ip route get 10.10.1.23
ip -d link show cilium_vxlan
ip neigh
```

### Enter a Pod's network namespace from the node

Many application images ship without `ip` or `tcpdump`. You do not need to install them in the container. Instead, run the node's own tools inside the pod's network namespace:

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

These are the `tcpdump` commands you will need most often:

| Need | Command |
|------|---------|
| Capture on a specific interface and port | `tcpdump -i eth0 -nn port 8080` |
| Stop after a fixed number of packets | `tcpdump -i eth0 -nn -c 20 port 80` |
| Write the capture to a file | `tcpdump -i eth0 -nn -c 100 -w /tmp/capture.pcap port 80` |
| Read a capture file back | `tcpdump -nn -r /tmp/capture.pcap` |
| See traffic to one backend pod | `tcpdump -i any -nn host 10.10.1.23 and tcp port 8080` |
| See only SYNs (connection attempts) | `tcpdump -i any -nn 'tcp[tcpflags] & (tcp-syn\|tcp-ack) == tcp-syn'` |
| See DNS queries | `tcpdump -i any -nn udp port 53` |
| Print the payload (HTTP) | `tcpdump -i any -nn -A port 80` |

> [!TIP]
> Always use `-nn`. It stops tcpdump from turning addresses and ports into names, so it does not stall on reverse DNS lookups. When a task gives you an exact packet count, file path or interface, use exactly those values. The result is often checked by reading the file you wrote.

### Read NAT and filter rules: `iptables`

When a service path is broken, the cause is often an iptables rule. These commands list the rules and remove a bad one:

```bash
iptables -t nat -L -n -v --line-numbers
iptables -t filter -L FORWARD -n -v
iptables-save | grep <service-or-pod-ip>
iptables-save -t nat | grep KUBE-SVC

# Remove a bad rule by line number
iptables -t nat -D PREROUTING 3
```

To read a NAT problem, follow the path a packet takes:

1. The packet goes from `PREROUTING` to `KUBE-SERVICES`, then to `KUBE-SVC-xxx`, and then to `KUBE-SEP-xxx`. The `KUBE-SEP-xxx` chain holds the `DNAT --to-destination <podIP>:<port>`. If the IP or port there is wrong, traffic goes to the wrong place.
2. Rules are checked from top to bottom. So a manually inserted `DNAT` or `REDIRECT` **above** the Kubernetes jump wins.
3. A `DROP` or `REJECT` rule in `FORWARD` or `INPUT` with growing packet counters is your culprit. Watch the counters change with `watch -n1 'iptables -L FORWARD -n -v'`.
4. Last, `MASQUERADE` / `SNAT` in `POSTROUTING` sets the source IP the traffic has when it leaves the node.

Also check `sysctl net.ipv4.ip_forward`, because it must be `1` on any node that forwards pod traffic.

### Network delay and latency

When requests are slow but not failing, first measure where the time goes. Then look for injected delay or drops on the interface:

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

Work from the bottom of the stack up. Change only one thing at a time, so you know which change fixed the problem. Each step only makes sense once the step before it works:

```text
1. Pod has an IP and is Ready?            kubectl get pod -o wide
2. Same-node pod-to-pod works?            kubectl exec a -- curl -m3 <podB-IP>:<port>
3. Cross-node pod-to-pod works?           (tunnel / routing / MTU / encryption)
4. Pod-to-Service ClusterIP works?        (service translation, endpoints)
5. DNS resolves the service name?         nslookup <svc>.<ns>.svc.cluster.local
6. Pod-to-external works?                 (masquerading, egress policy, node routes)
7. Is a policy dropping it?               hubble observe --verdict DROPPED
```

These commands give you a client pod to test from and show Cilium's own view of the problem:

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

Many connectivity problems turn out to be DNS problems. So check name resolution from inside the pod, and then check CoreDNS itself:

```bash
kubectl exec -it <pod> -- cat /etc/resolv.conf
kubectl exec -it <pod> -- nslookup kubernetes.default
kubectl exec -it <pod> -- nslookup example.com
kubectl get svc -n kube-system kube-dns
kubectl get endpointslices -n kube-system -l kubernetes.io/service-name=kube-dns
kubectl logs -n kube-system -l k8s-app=kube-dns
```

The symptom usually points you to the cause:

| Symptom | Likely cause |
|---------|--------------|
| Cluster names fail, but IPs work | CoreDNS is down, the kube-dns Service has no endpoints, or a policy blocks UDP/TCP 53 |
| Cluster names work, but external names fail | The CoreDNS `forward` target is wrong or unreachable (see Domain 2) |
| Lookups time out now and then | One CoreDNS replica is unhealthy, there are conntrack races, or the MTU is wrong |
| Large responses fail | There is an MTU mismatch, caused by tunnel overhead or WireGuard |
| The Pod's `dnsPolicy` is wrong | With `Default`, the pod uses the node's resolver instead of CoreDNS |

Reference: [Debugging DNS Resolution](https://kubernetes.io/docs/tasks/administer-cluster/dns-debugging-resolution/)

---

## 7. Multi-interface Pods with Multus

Multus is a "meta" CNI. It does not replace your primary CNI. It works alongside it. The primary CNI (Cilium) still provides `eth0`. Multus adds extra interfaces (`net1`, `net2`, ...), which you describe with `NetworkAttachmentDefinition` objects.

> [!NOTE]
> When you run Multus alongside Cilium, install Cilium with `--set cni.exclusive=false`. The default is `true`, which makes Cilium rename the other CNI configs in `/etc/cni/net.d/` to `*.cilium_bak`. Then Multus stops working.

The example below defines a macvlan network and then attaches it to a Pod through an annotation:

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

Once the Pod is running, confirm that it has the second interface:

```bash
kubectl get network-attachment-definitions
kubectl exec dual-nic -- ip -br addr
kubectl get pod dual-nic -o jsonpath='{.metadata.annotations.k8s\.v1\.cni\.cncf\.io/network-status}'
```

The plugin named in `"type"` must exist as a binary in `/opt/cni/bin/` on every node. If it is missing, the pod stays in `ContainerCreating`, and its events name the binary that could not be found.

Reference: [Multus CNI Quickstart](https://github.com/k8snetworkplumbingwg/multus-cni/blob/master/docs/quickstart.md)

---

## 8. Hands-on Checklist

You are ready for this domain when you can do each of these tasks without looking at your notes:

- [ ] Can you install Cilium with the Cilium CLI on a cluster that has no CNI, and then confirm that `cilium status` is all green?
- [ ] Can you run Cilium as the only service proxy (with no kube-proxy) and show that the agent reports `KubeProxyReplacement: True`?
- [ ] Can you turn on eBPF masquerading and prove that it is active from the agent status output?
- [ ] Can you explain which traffic gets SNATed to the node IP and which traffic does not?
- [ ] Can you read a node's pod CIDR from both the Node object and the CiliumNode?
- [ ] Can you capture N packets on a given interface and port into a `.pcap` file, and then read the file back?
- [ ] Can you use `nsenter` or `kubectl debug` to sniff the traffic that arrives at one backend pod?
- [ ] Can you find and delete a stray DNAT/DROP rule that breaks a service path?
- [ ] Can you spot and remove an injected `tc netem` delay?
- [ ] Can you attach a second interface to a pod with Multus?
