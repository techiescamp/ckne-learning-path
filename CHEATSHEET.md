# CKNE Command Cheatsheet

> This page gives you short, one-line reminders for each tool, so you can find a command quickly during practice. If you need the full explanation and the YAML behind a command, open the study note for that domain.

## Cilium

```bash
cilium status --wait
cilium config view | grep -i <key>
cilium upgrade --reuse-values --set <key>=<value>
kubectl -n kube-system rollout restart ds/cilium deploy/cilium-operator

kubectl -n kube-system exec ds/cilium -- cilium-dbg status --verbose
kubectl -n kube-system exec ds/cilium -- cilium-dbg service list
kubectl -n kube-system exec ds/cilium -- cilium-dbg endpoint list
kubectl -n kube-system exec ds/cilium -- cilium-dbg policy get
kubectl -n kube-system exec ds/cilium -- cilium-dbg monitor --type drop
kubectl -n kube-system exec ds/cilium -- cilium-dbg bpf egress list
kubectl -n kube-system exec ds/cilium -- cilium-dbg encrypt status

cilium bgp peers
cilium bgp routes advertised ipv4 unicast
cilium clustermesh status --wait
cilium connectivity test
```

| Helm value | Feature |
|------------|---------|
| `kubeProxyReplacement=true` + `k8sServiceHost` / `k8sServicePort` | Runs Cilium without kube-proxy, so it needs the real API server address |
| `bpf.masquerade=true` | Does SNAT (masquerading) in eBPF |
| `egressGateway.enabled=true` | Turns on the egress gateway |
| `bgpControlPlane.enabled=true` | Turns on the BGP control plane |
| `encryption.enabled=true`, `encryption.type=wireguard` | Encrypts Pod traffic with WireGuard |
| `encryption.nodeEncryption=true` | Encrypts node traffic as well as Pod traffic |
| `cluster.name`, `cluster.id` | Give each cluster its own identity for Cluster Mesh |
| `gatewayAPI.enabled=true` | Lets Cilium act as the Gateway API controller |
| `cni.exclusive=false` | Lets Cilium share the node with Multus or the Istio CNI |
| `hubble.relay.enabled=true`, `hubble.ui.enabled=true` | Turns on Hubble Relay and the Hubble UI |

## Hubble

```bash
cilium hubble port-forward &
hubble observe -n <ns> --verdict DROPPED
hubble observe --from-pod <ns>/<pod> --to-pod <ns>/<pod>
hubble observe --to-service <ns>/<svc>
hubble observe --protocol http --http-status 5+
hubble observe --protocol dns
hubble observe --type policy-verdict
hubble observe -o json | jq '.flow.drop_reason_desc'
```

## Istio Ambient

```bash
istioctl install --set profile=ambient --skip-confirmation
kubectl label ns <ns> istio.io/dataplane-mode=ambient
istioctl waypoint apply -n <ns> --enroll-namespace --wait
istioctl ztunnel-config workloads
istioctl analyze -n <ns>
kubectl -n istio-system logs -l app=ztunnel | grep -iE "policy rejection|denied"
```

| Need | Resource |
|------|----------|
| Reject clients outside the mesh that send plaintext | `PeerAuthentication` `mtls.mode: STRICT` |
| Allow or deny traffic by identity and port | `AuthorizationPolicy` with `selector` (enforced by ztunnel) |
| Allow or deny traffic by HTTP method or path | `AuthorizationPolicy` with `targetRefs: Service`, which needs a waypoint |
| Write the principal (identity) in this format | `cluster.local/ns/<ns>/sa/<serviceaccount>` |

## Gateway API / Envoy Gateway

```bash
kubectl get gatewayclass,gateway,httproute -A
kubectl describe httproute <name>
kubectl -n envoy-gateway-system logs deploy/envoy-gateway
kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=<gw> -c envoy
curl -s --resolve <host>:80:<gwIP> http://<host>/<path>
curl -vk --resolve <host>:443:<gwIP> https://<host>/
openssl s_client -connect <gwIP>:443 -servername <host> </dev/null | openssl x509 -noout -subject -dates
kubectl api-resources | grep -i inference
```

## Services, Endpoints and DNS

```bash
kubectl get svc,endpointslices -n <ns>
kubectl get endpointslices -l kubernetes.io/service-name=<svc> -o wide
kubectl -n kube-system edit cm coredns
kubectl -n kube-system rollout restart deploy coredns
kubectl -n kube-system logs -l k8s-app=kube-dns
kubectl run t --rm -it --image=busybox:1.36 --restart=Never -- nslookup <name>
kubectl run t --rm -it --image=nicolaka/netshoot --restart=Never -- bash
```

## MetalLB and kube-router

```bash
kubectl -n metallb-system get ipaddresspools,l2advertisements,bgppeers,bgpadvertisements
kubectl -n metallb-system logs -l component=speaker
kubectl -n metallb-system logs -l app.kubernetes.io/component=speaker
kubectl -n kube-system exec ds/kube-router -- gobgp neighbor
kubectl -n kube-system exec ds/kube-router -- gobgp global rib
kubectl -n kube-system exec ds/kube-router -- ipvsadm -Ln
```

## Linux Networking

```bash
ip -br addr; ip route; ip route get <ip>; ip neigh
ss -lntp
nsenter -t <pid> -n <cmd>
crictl inspect <container-id> | jq .info.pid

tcpdump -i <if> -nn port <p>
tcpdump -i <if> -nn -c <count> -w /path/file.pcap port <p>
tcpdump -nn -r /path/file.pcap

iptables -t nat -L -n -v --line-numbers
iptables-save | grep <ip>
iptables -t nat -D <CHAIN> <line>
sysctl net.ipv4.ip_forward
tc qdisc show dev <if>; tc qdisc del dev <if> root
curl -o /dev/null -s -w 'connect:%{time_connect} ttfb:%{time_starttransfer} total:%{time_total}\n' <url>
```

## PromQL

```promql
up == 0
sum by (reason) (rate(hubble_drop_total[5m]))
sum by (destination_service) (rate(istio_requests_total{response_code=~"5.."}[5m]))
histogram_quantile(0.99, sum by (le, destination_service) (rate(istio_request_duration_milliseconds_bucket[5m])))
sum by (rcode) (rate(coredns_dns_responses_total[5m]))
```

## Envoy `response_flags`

When Envoy cannot complete a request, the response flag tells you why. `UH` means there was no healthy upstream, and `UF` means the connection to the upstream failed. `UT` means the upstream timed out, while `NR` means no route matched the request. `URX` means Envoy used up all its retries, `DC` means the client disconnected, and `RL` means the request was rate limited.
