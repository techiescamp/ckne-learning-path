# CKNE Practice Tasks

> 20 exam-style scenarios covering all 5 domains. Try each one before opening the solution, and time yourself.

**How to use:** read the task, note every exact value (names, namespaces, ports, paths, counts), solve it, then compare. When you get one wrong, rebuild it from scratch the next day.

| Solved | Readiness |
|--------|-----------|
| 17–20 | Exam-ready 🟢 |
| 13–16 | Almost there 🟡 |
| 9–12 | More practice needed 🟠 |
| < 9 | Revisit the study notes 🔴 |

---

## Domain 1: Core Infrastructure and CNI

### Task 1: Install Cilium without kube-proxy

A new cluster has no CNI and no kube-proxy. The API server is at `172.18.0.2:6443`. Install Cilium with the Cilium CLI as a full kube-proxy replacement, with eBPF masquerading enabled.

<details><summary>Solution</summary>

```bash
cilium install \
  --set kubeProxyReplacement=true \
  --set k8sServiceHost=172.18.0.2 \
  --set k8sServicePort=6443 \
  --set bpf.masquerade=true
cilium status --wait
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep -E "KubeProxyReplacement|Masquerading"
```
</details>

### Task 2: Capture backend traffic

Pods of Deployment `api` in namespace `shop` listen on TCP 8080. On node `worker-1`, capture exactly 25 packets destined to port 8080 on any interface, and write them to `/opt/captures/api.pcap`.

<details><summary>Solution</summary>

```bash
ssh worker-1
sudo tcpdump -i any -nn -c 25 -w /opt/captures/api.pcap dst port 8080
# generate traffic from another terminal if needed, then verify
sudo tcpdump -nn -r /opt/captures/api.pcap | wc -l
```
</details>

### Task 3: Broken NAT path

Requests to the `web` Service (ClusterIP `10.96.120.10:80`) from pods on `worker-2` reach the wrong application. Pods on other nodes work. Find and fix the cause on `worker-2`.

<details><summary>Solution</summary>

```bash
ssh worker-2
sudo iptables-save -t nat | grep 10.96.120.10
# A manual rule above the Kubernetes chains, e.g.
#   -A PREROUTING -d 10.96.120.10/32 -p tcp --dport 80 -j DNAT --to-destination 10.0.3.9:9000
sudo iptables -t nat -L PREROUTING -n --line-numbers
sudo iptables -t nat -D PREROUTING <line-number>
```
Re-test from a pod on `worker-2`. Also check `tc qdisc show` and `sysctl net.ipv4.ip_forward` if you see latency or drops rather than misrouting.
</details>

### Task 4: Slow requests from one node

Requests from pods on `worker-1` to any Service take over 300 ms. Other nodes respond in under 5 ms. Find and remove the cause.

<details><summary>Solution</summary>

```bash
ssh worker-1
tc qdisc show dev eth0
sudo tc qdisc del dev eth0 root
```
</details>

---

## Domain 2: Service Networking and DNS

### Task 5: Forward a corporate domain

Pods must resolve `*.corp.internal` using the DNS server `10.0.0.53`. All other external names continue to use the node resolver.

<details><summary>Solution</summary>

Add a top-level server block to the `coredns` ConfigMap in `kube-system`:

```text
corp.internal:53 {
    errors
    cache 30
    forward . 10.0.0.53
}
```
```bash
kubectl -n kube-system rollout restart deploy coredns
kubectl run t --rm -it --image=busybox:1.36 --restart=Never -- nslookup app.corp.internal
```
</details>

### Task 6: External names fail

Pods resolve `kubernetes.default` but not `example.com`. Fix it so that external lookups use `1.1.1.1`.

<details><summary>Solution</summary>

In the Corefile, change the `forward` line in `.:53`:
```text
forward . 1.1.1.1
```
Check the CoreDNS logs for upstream errors, and check that no NetworkPolicy blocks CoreDNS egress on UDP/TCP 53.
</details>

### Task 7: Service with no healthy backends

`curl checkout.shop:8080` times out. The pods are Running. Fix the Service so it serves traffic, and add a TCP readiness probe on the app port.

<details><summary>Solution</summary>

```bash
kubectl -n shop get endpointslices -l kubernetes.io/service-name=checkout
kubectl -n shop get svc checkout -o yaml | yq '.spec.selector, .spec.ports'
kubectl -n shop get pods --show-labels
kubectl -n shop exec deploy/checkout -- ss -lnt
```
Fix whatever does not line up (selector vs labels, `targetPort` vs the real listening port), then add:
```yaml
readinessProbe:
  tcpSocket:
    port: 8080
  periodSeconds: 5
```
Endpoints must show `ready: true`.
</details>

### Task 8: Point a Service at an external database

Create a Service `legacy-db` in namespace `apps` on port 5432 that sends traffic to `192.168.10.50:5432`.

<details><summary>Solution</summary>

Create a selectorless Service with a named port `pg`, plus an EndpointSlice labelled `kubernetes.io/service-name: legacy-db` with the same port name and the address `192.168.10.50`. See Domain 2, section 3.
</details>

### Task 9: Gateway API path routing

In namespace `web`, using GatewayClass `eg`, create Gateway `web-gw` with an HTTP listener on port 80 for `shop.example.com`. Route `/api` to Service `api:8080` and everything else to `frontend:80`.

<details><summary>Solution</summary>

Create one Gateway and one HTTPRoute with two rules: `PathPrefix /api` → `api:8080` and `PathPrefix /` → `frontend:80`. Verify:
```bash
kubectl -n web describe httproute
curl -s --resolve shop.example.com:80:$GW_IP http://shop.example.com/api
```
</details>

---

## Domain 3: Advanced Traffic Management

### Task 10: Inference routing

Model-server pods labelled `app=vllm-llama` in namespace `inference` listen on port 8000, and an endpoint picker Service `llama-epp` listens on 9002. Create InferencePool `llama-pool` and route `POST /v1/completions` on Gateway `inference-gw` to it.

<details><summary>Solution</summary>

```bash
kubectl explain inferencepool.spec
```
Create the InferencePool (`selector.matchLabels.app: vllm-llama`, `targetPorts: [{number: 8000}]`, `endpointPickerRef: {name: llama-epp, port: {number: 9002}}`). Then create an HTTPRoute with a match on `method: POST` and `PathPrefix /v1/completions` whose backendRef has `group: inference.networking.k8s.io`, `kind: InferencePool`, `name: llama-pool`. Check that the route shows `ResolvedRefs=True`, and send a test completion.
</details>

### Task 11: BGP peering

Nodes labelled `bgp=enabled` must peer from ASN 65001 with router `172.18.0.100` (ASN 65000) and advertise their pod CIDRs and all LoadBalancer IPs.

<details><summary>Solution</summary>

Enable `bgpControlPlane.enabled=true`. Create a `CiliumBGPClusterConfig` (nodeSelector `bgp=enabled`, localASN 65001, peer 172.18.0.100 / 65000), a `CiliumBGPPeerConfig` selecting advertisements by label, and a `CiliumBGPAdvertisement` with `PodCIDR` and `Service` → `LoadBalancerIP`. A Service advertisement only covers Services matching its `selector`, so to advertise all of them add `matchExpressions: [{key: bgp-exclude, operator: DoesNotExist}]` (or a `NotIn` with a never-used value).
```bash
cilium bgp peers
cilium bgp routes advertised ipv4 unicast
```
</details>

### Task 12: Predictable source IP

Pods with `app=billing` in namespace `payments` call `203.0.113.0/24`. The partner only accepts traffic from `172.18.0.50`, which is configured on node `worker-3`. Make it work.

<details><summary>Solution</summary>

```bash
kubectl label node worker-3 egress-gw=true
```
Make sure `egressGateway.enabled`, `bpf.masquerade` and `kubeProxyReplacement` are on. Create a `CiliumEgressGatewayPolicy` selecting `app=billing` + `io.kubernetes.pod.namespace=payments`, with `destinationCIDRs: [203.0.113.0/24]`, `nodeSelector egress-gw=true` and `egressIP: 172.18.0.50`.
```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf egress list
```
</details>

### Task 13: Cross-cluster backend

Clusters `c1` and `c2` are already joined in a Cluster Mesh. Deployment `backend` runs only in `c2` (namespace `shop`). Make `client` in `c1` reach it at `backend.shop`.

<details><summary>Solution</summary>

Create Service `backend` in namespace `shop` in **both** clusters with the annotation `service.cilium.io/global: "true"`. Its selector can match nothing in `c1`. Test with `kubectl --context c1 -n shop exec deploy/client -- curl -s backend`. If it fails, check `cilium clustermesh status`.
</details>

---

## Domain 4: Network Security and Policy

### Task 14: Lock down a namespace

In namespace `shop`: deny all ingress and egress by default. Allow `frontend` → `api` on TCP 8080, and allow DNS for all pods.

<details><summary>Solution</summary>

Create a default-deny NetworkPolicy (`podSelector: {}`, both policyTypes), an egress policy for all pods to `kube-system`/`k8s-app=kube-dns` on UDP+TCP 53, an ingress policy on `api` from `app=frontend` on 8080, and an egress policy on `frontend` to `app=api` on 8080. Test both the allowed path and a denied one.
</details>

### Task 15: L7 allow-list

`frontend` may only call `GET /products` and `GET /products/*` on `api:8080`. All other requests must be rejected with HTTP 403.

<details><summary>Solution</summary>

Create a CiliumNetworkPolicy on `app=api` with `fromEndpoints app=frontend`, `toPorts 8080`, `rules.http: [{method: GET, path: "/products(/.*)?"}]`.
```bash
kubectl -n shop exec deploy/frontend -- curl -s -o /dev/null -w '%{http_code}' api:8080/admin
```
</details>

### Task 16: Encrypt node-to-node traffic

Enable WireGuard encryption for pod traffic between nodes and prove it is active.

<details><summary>Solution</summary>

```bash
cilium upgrade --reuse-values --set encryption.enabled=true --set encryption.type=wireguard
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep Encryption
```
</details>

### Task 17: HTTPS on a Gateway

The cert and key are at `/opt/certs/shop.crt` and `/opt/certs/shop.key`. Serve `https://shop.example.com` from Gateway `web-gw` (namespace `web`) on port 443.

<details><summary>Solution</summary>

```bash
kubectl -n web create secret tls shop-tls --cert=/opt/certs/shop.crt --key=/opt/certs/shop.key
```
Add an `HTTPS` listener (port 443, hostname `shop.example.com`, `tls.mode: Terminate`, `certificateRefs: [{name: shop-tls}]`) and attach the HTTPRoute to it with `sectionName`.
```bash
curl -v --cacert /opt/certs/shop.crt --resolve shop.example.com:443:$GW_IP https://shop.example.com/
```
</details>

### Task 18: Mesh-only access with endpoint restriction

Namespace `bank` is in Istio ambient mode. Non-mesh pods must not reach any `bank` service. Within the mesh, only ServiceAccount `teller` in `bank` may call `POST /transfer` on Service `ledger`.

<details><summary>Solution</summary>

1. `PeerAuthentication` `mtls.mode: STRICT` in `bank`.
2. `istioctl waypoint apply -n bank --enroll-namespace --wait`
3. `AuthorizationPolicy` with `targetRefs: [{kind: Service, group: "", name: ledger}]`, ALLOW, principal `cluster.local/ns/bank/sa/teller`, `methods: [POST]`, `paths: [/transfer]`.

Expect a reset from non-mesh clients and `RBAC: access denied` for the wrong identity or path.
</details>

---

## Domain 5: Observability

### Task 19: Who is hammering the login endpoint?

The Gateway `web-gw` sees many failing requests to `/api/login`. Find the user agent responsible and write it to `/opt/answers/agent.txt`.

<details><summary>Solution</summary>

```bash
kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=web-gw -c envoy --tail=-1 \
  | jq -R -r 'fromjson? | select((."x-envoy-origin-path" // "") | startswith("/api/login"))
      | select((.response_code|tonumber) >= 400) | ."user-agent"' \
  | sort | uniq -c | sort -rn | head -1
echo '<agent>' > /opt/answers/agent.txt
```
</details>

### Task 20: Find the failing backend

Requests to Service `orders` intermittently return 503. Using Hubble and Prometheus, find which pod is responsible and fix it.

<details><summary>Solution</summary>

```promql
sum by (destination_workload) (rate(istio_requests_total{destination_service=~"orders.*", response_code="503"}[5m]))
```
```bash
hubble observe --to-service <ns>/orders --verdict DROPPED
hubble observe --protocol http --http-status 5+ --to-label app=orders
kubectl get endpointslices -l kubernetes.io/service-name=orders -o wide
```
Istio metrics narrow it to the workload. Hubble flows and the EndpointSlice narrow it to the pod. One pod stands out. Check its probes, logs and node, then fix the root cause (for example, a wrong readiness port or a crashing container).
</details>
