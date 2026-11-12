# CKNE Practice Tasks

> This page has 20 exam-style scenarios that together cover all 5 domains. Try each task on your own before you open its solution, and time yourself so you get used to working under exam pressure.

**How to use:** Read each task carefully and write down every exact value it gives you, such as names, namespaces, ports, paths and counts, because the exam checks those values precisely. Then solve the task and compare your work with the solution. If you get a task wrong, rebuild it from scratch the next day so the fix sticks.

---

## Domain 1: Core Infrastructure and CNI

### Task 1: Install Cilium without kube-proxy

You have a new cluster that has no CNI and no kube-proxy, and its API server is at `172.18.0.2:6443`. Use the Cilium CLI to install Cilium as a full kube-proxy replacement, and enable eBPF masquerading as well.

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

The pods of Deployment `api` in namespace `shop` listen on TCP 8080. On node `worker-1`, capture exactly 25 packets that are going to port 8080 on any interface, and save them to `/opt/captures/api.pcap`.

<details><summary>Solution</summary>

```bash
ssh worker-1
sudo tcpdump -i any -nn -c 25 -w /opt/captures/api.pcap dst port 8080
# generate traffic from another terminal if needed, then verify
sudo tcpdump -nn -r /opt/captures/api.pcap | wc -l
```
</details>

### Task 3: Broken NAT path

When pods on `worker-2` send requests to the `web` Service (ClusterIP `10.96.120.10:80`), the requests reach the wrong application. Pods on the other nodes work correctly, so the problem is local to that node. Find the cause on `worker-2` and fix it.

<details><summary>Solution</summary>

```bash
ssh worker-2
sudo iptables-save -t nat | grep 10.96.120.10
# A manual rule above the Kubernetes chains, e.g.
#   -A PREROUTING -d 10.96.120.10/32 -p tcp --dport 80 -j DNAT --to-destination 10.0.3.9:9000
sudo iptables -t nat -L PREROUTING -n --line-numbers
sudo iptables -t nat -D PREROUTING <line-number>
```
After you delete the rule, test again from a pod on `worker-2`. If you see latency or dropped packets instead of traffic going to the wrong place, the cause is probably different, so also check `tc qdisc show` and `sysctl net.ipv4.ip_forward`.
</details>

### Task 4: Slow requests from one node

Requests from pods on `worker-1` to any Service take more than 300 ms, while the other nodes respond in under 5 ms. Find what is slowing down `worker-1` and remove it.

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

Pods must resolve `*.corp.internal` names through the DNS server `10.0.0.53`. At the same time, all other external names must keep using the node's resolver.

<details><summary>Solution</summary>

Add a separate top-level server block to the `coredns` ConfigMap in `kube-system`, so that only queries for this domain go to the corporate DNS server:

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

Pods can resolve `kubernetes.default`, but they cannot resolve `example.com`. Fix this so that external lookups go to `1.1.1.1`.

<details><summary>Solution</summary>

In the Corefile, change the `forward` line inside the `.:53` block:
```text
forward . 1.1.1.1
```
If lookups still fail, look at the CoreDNS logs for upstream errors, and make sure that no NetworkPolicy blocks CoreDNS egress on UDP/TCP 53.
</details>

### Task 7: Service with no healthy backends

Running `curl checkout.shop:8080` times out, even though the pods are Running. Fix the Service so that it serves traffic again, and then add a TCP readiness probe on the app port.

<details><summary>Solution</summary>

```bash
kubectl -n shop get endpointslices -l kubernetes.io/service-name=checkout
kubectl -n shop get svc checkout -o yaml | yq '.spec.selector, .spec.ports'
kubectl -n shop get pods --show-labels
kubectl -n shop exec deploy/checkout -- ss -lnt
```
Compare the output and fix whatever does not match, for example a selector that does not match the pod labels, or a `targetPort` that differs from the port the app really listens on. Then add the probe:
```yaml
readinessProbe:
  tcpSocket:
    port: 8080
  periodSeconds: 5
```
When you are done, the endpoints must show `ready: true`.
</details>

### Task 8: Point a Service at an external database

Create a Service `legacy-db` in namespace `apps` on port 5432, and make it send traffic to `192.168.10.50:5432`, which is outside the cluster.

<details><summary>Solution</summary>

Because the backend is not a pod, create a Service without a selector and give it a named port `pg`. Then create an EndpointSlice labelled `kubernetes.io/service-name: legacy-db`, which links it to the Service, with the same port name and the address `192.168.10.50`. See Domain 2, section 3 for the full example.
</details>

### Task 9: Gateway API path routing

In namespace `web`, use GatewayClass `eg` to create Gateway `web-gw` with an HTTP listener on port 80 for `shop.example.com`. Requests to `/api` must go to Service `api:8080`, and all other requests must go to `frontend:80`.

<details><summary>Solution</summary>

Create one Gateway and one HTTPRoute that has two rules: `PathPrefix /api` sends traffic to `api:8080`, and `PathPrefix /` sends everything else to `frontend:80`. The more specific `/api` prefix wins for API requests. Then verify the setup:
```bash
kubectl -n web describe httproute
curl -s --resolve shop.example.com:80:$GW_IP http://shop.example.com/api
```
</details>

---

## Domain 3: Advanced Traffic Management

### Task 10: Inference routing

In namespace `inference`, the model-server pods are labelled `app=vllm-llama` and listen on port 8000, and an endpoint picker Service called `llama-epp` listens on port 9002. Create InferencePool `llama-pool`, and then route `POST /v1/completions` on Gateway `inference-gw` to that pool.

<details><summary>Solution</summary>

```bash
kubectl explain inferencepool.spec
```
First, create the InferencePool with `selector.matchLabels.app: vllm-llama`, `targetPorts: [{number: 8000}]` and `endpointPickerRef: {name: llama-epp, port: {number: 9002}}`. Next, create an HTTPRoute that matches `method: POST` and `PathPrefix /v1/completions`. Its backendRef points to the pool with `group: inference.networking.k8s.io`, `kind: InferencePool` and `name: llama-pool`. Finally, check that the route shows `ResolvedRefs=True`. Then send a test completion to confirm it works end to end.
</details>

### Task 11: BGP peering

Nodes labelled `bgp=enabled` must use ASN 65001 to peer with router `172.18.0.100` (ASN 65000). Over that session, they must advertise their pod CIDRs and all LoadBalancer IPs.

<details><summary>Solution</summary>

Start by enabling `bgpControlPlane.enabled=true`. Then create three resources:

- A `CiliumBGPClusterConfig` with nodeSelector `bgp=enabled`, localASN 65001, and peer 172.18.0.100 with ASN 65000.
- A `CiliumBGPPeerConfig` whose address family selects advertisements by label. Without a matching advertisement, nothing is sent to the peer.
- A `CiliumBGPAdvertisement` (with that label) that has two entries: `PodCIDR`, and `Service` with `addresses: [LoadBalancerIP]`.

A Service advertisement only covers the Services that match its `selector`. So, to advertise all of them, use the pattern from the Cilium docs: `matchExpressions: [{key: somekey, operator: NotIn, values: [never-used-value]}]`. Every Service matches it.
```bash
cilium bgp peers
cilium bgp routes advertised ipv4 unicast
```
</details>

### Task 12: Predictable source IP

Pods with `app=billing` in namespace `payments` call `203.0.113.0/24`. However, the partner only accepts traffic from `172.18.0.50`, and that address is configured on node `worker-3`. Make the traffic leave from that IP so that the calls work.

<details><summary>Solution</summary>

```bash
kubectl label node worker-3 egress-gw=true
```
Make sure that `egressGateway.enabled`, `bpf.masquerade` and `kubeProxyReplacement` are all turned on, because the egress gateway needs all three. If you change any of them, restart the `cilium` DaemonSet and the `cilium-operator` Deployment. Then create a `CiliumEgressGatewayPolicy` that selects `app=billing` + `io.kubernetes.pod.namespace=payments`, with `destinationCIDRs: [203.0.113.0/24]`, `nodeSelector egress-gw=true` and `egressIP: 172.18.0.50`.
```bash
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf egress list
```
</details>

### Task 13: Cross-cluster backend

Clusters `c1` and `c2` are already joined in a Cluster Mesh. Deployment `backend` runs only in `c2`, in namespace `shop`. Make it possible for `client` in `c1` to reach it at `backend.shop`.

<details><summary>Solution</summary>

Create Service `backend` in namespace `shop` in **both** clusters, and give it the annotation `service.cilium.io/global: "true"` so that Cilium merges the backends from both clusters. In `c1` the selector can match nothing, because the real pods live in `c2`. Test the result with `kubectl --context c1 -n shop exec deploy/client -- curl -s backend`, and if it fails, check `cilium clustermesh status`.
</details>

---

## Domain 4: Network Security and Policy

### Task 14: Lock down a namespace

In namespace `shop`, deny all ingress and egress traffic by default. Then allow `frontend` to reach `api` on TCP 8080, and allow DNS for all pods.

<details><summary>Solution</summary>

You need four NetworkPolicies:

1. A default-deny policy: `podSelector: {}` with both policyTypes.
2. An egress policy that lets all pods reach `kube-system`/`k8s-app=kube-dns` on UDP+TCP 53. You need this because the default deny also blocks name lookups.
3. An ingress policy on `api` that allows `app=frontend` on 8080.
4. An egress policy on `frontend` that allows traffic to `app=api` on 8080. Both sides of the connection must be allowed, so you need this one too.

Finally, test a path that should work and a path that should be denied.
</details>

### Task 15: L7 allow-list

`frontend` may only call `GET /products` and `GET /products/*` on `api:8080`. Any other request must be rejected with HTTP 403.

<details><summary>Solution</summary>

Create a CiliumNetworkPolicy on `app=api` with `fromEndpoints app=frontend`, `toPorts 8080` and `rules.http: [{method: GET, path: "/products(/.*)?"}]`. The path is a regular expression, so this one rule covers both `/products` and everything under it. To test it, call a path that is not allowed and check that you get 403:
```bash
kubectl -n shop exec deploy/frontend -- curl -s -o /dev/null -w '%{http_code}' api:8080/admin
```
</details>

### Task 16: Encrypt node-to-node traffic

Turn on WireGuard encryption for pod traffic between nodes, and then prove that it is active.

<details><summary>Solution</summary>

```bash
cilium upgrade --reuse-values --set encryption.enabled=true --set encryption.type=wireguard
kubectl -n kube-system rollout restart ds/cilium
kubectl -n kube-system exec ds/cilium -- cilium-dbg status | grep Encryption
```
</details>

### Task 17: HTTPS on a Gateway

The certificate and key are at `/opt/certs/shop.crt` and `/opt/certs/shop.key`. Use them to serve `https://shop.example.com` from Gateway `web-gw` (namespace `web`) on port 443.

<details><summary>Solution</summary>

```bash
kubectl -n web create secret tls shop-tls --cert=/opt/certs/shop.crt --key=/opt/certs/shop.key
```
Next, add an `HTTPS` listener to the Gateway (port 443, hostname `shop.example.com`, `tls.mode: Terminate`, `certificateRefs: [{name: shop-tls}]`), and attach the HTTPRoute to that listener with `sectionName`. Then test it. The `-k` flag skips certificate verification, so the test works even if the certificate is not signed by a CA your machine trusts. The `openssl` command shows which certificate the Gateway serves:
```bash
curl -vk --resolve shop.example.com:443:$GW_IP https://shop.example.com/
openssl s_client -connect $GW_IP:443 -servername shop.example.com </dev/null | openssl x509 -noout -subject -dates
```
</details>

### Task 18: Mesh-only access with endpoint restriction

Namespace `bank` runs in Istio ambient mode. Pods that are not in the mesh must not be able to reach any `bank` service. Inside the mesh, only ServiceAccount `teller` in `bank` may call `POST /transfer` on Service `ledger`.

<details><summary>Solution</summary>

1. Create a `PeerAuthentication` with `mtls.mode: STRICT` in `bank`, so that plain-text traffic from non-mesh pods is refused.
2. Deploy a waypoint, which is needed to enforce L7 rules such as methods and paths: `istioctl waypoint apply -n bank --enroll-namespace --wait`
3. Create an `AuthorizationPolicy` with `targetRefs: [{kind: Service, group: "", name: ledger}]` and action ALLOW, for principal `cluster.local/ns/bank/sa/teller`, `methods: [POST]` and `paths: [/transfer]`.

If everything is correct, clients outside the mesh get a connection reset, and a request with the wrong identity or path gets `RBAC: access denied`.
</details>

---

## Domain 5: Observability

### Task 19: Who is hammering the login endpoint?

Gateway `web-gw` is receiving many failing requests to `/api/login`. Find the user agent that is sending them, and write it to `/opt/answers/agent.txt`.

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

Requests to Service `orders` sometimes return 503. Use Hubble and Prometheus to find the pod that causes the errors, and then fix it.

<details><summary>Solution</summary>

```promql
sum by (destination_workload) (rate(istio_requests_total{destination_service=~"orders.*", response_code="503"}[5m]))
```
```bash
hubble observe --to-service <ns>/orders --verdict DROPPED
hubble observe --protocol http --http-status 5+ --to-label app=orders
kubectl get endpointslices -l kubernetes.io/service-name=orders -o wide
```
The Istio metrics tell you which workload is failing, and then the Hubble flows and the EndpointSlice narrow it down to a single pod. Once one pod stands out, check its probes, logs and node, and fix the root cause, for example a wrong readiness port or a crashing container.
</details>
