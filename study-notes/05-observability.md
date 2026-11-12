# Domain 5: Observability (15%)

> **Exam Weight: 15%**: Network health from metrics, end-to-end performance from traces, traffic auditing from logs.

Observability tasks rarely ask you to install anything. They give you a broken or misbehaving system and ask *where* traffic fails, *which* backend is unhealthy or *who* is sending bad requests. Practise reading the Hubble, Prometheus and Jaeger UIs as well as their CLIs.

## Index

1. [Hubble: Network Flows](#1-hubble-network-flows)
2. [Prometheus: Network Health Metrics](#2-prometheus-network-health-metrics)
3. [Jaeger: End-to-end Tracing](#3-jaeger-end-to-end-tracing)
4. [Auditing Traffic with Logs](#4-auditing-traffic-with-logs)
5. [Putting It Together: Locating a Failure](#5-putting-it-together-locating-a-failure)
6. [Hands-on Checklist](#6-hands-on-checklist)

---

## 1. Hubble: Network Flows

Hubble records every flow Cilium handles: source/destination identity, verdict (`FORWARDED`, `DROPPED`, `AUDIT`), drop reason and, for traffic passing an L7 proxy, the HTTP/DNS details.

### Enable and connect

```bash
cilium hubble enable --ui
cilium status

cilium hubble port-forward &
hubble status
cilium hubble ui
```

### The `hubble observe` filters you will use most

```bash
hubble observe -n shop --last 50
hubble observe -n shop --follow

# Drops and why
hubble observe --verdict DROPPED
hubble observe --verdict DROPPED -o json | jq -r '.flow.drop_reason_desc' | sort | uniq -c

# Between two workloads
hubble observe --from-pod shop/frontend-7d9 --to-pod shop/api-5c8
hubble observe --from-label app=frontend --to-label app=api
hubble observe --to-service shop/api

# Ports, protocols, L7
hubble observe --port 8080 --protocol tcp
hubble observe --protocol http --http-status 5+
hubble observe --protocol http --http-path "/checkout"
hubble observe --protocol dns
hubble observe --type policy-verdict

# TCP connection problems
hubble observe --tcp-flags RST
```

The default output shows the readable reason. The `-o json` pipeline above prints the enum name instead.

| Drop reason (enum in JSON) | Typical cause |
|----------------------------|---------------|
| `Policy denied` (`POLICY_DENIED`) | No policy allows this identity/port (see Domain 4) |
| `Policy denied by denylist` (`POLICY_DENY`) | An explicit `ingressDeny`/`egressDeny` |
| `Stale or unroutable IP` (`STALE_OR_UNROUTABLE_IP`) | Endpoint gone, pod restarted |
| `No mapping for NAT masquerade` (`NO_MAPPING_FOR_NAT_MASQUERADE`) / `Unknown L3 target address` (`UNKNOWN_L3_TARGET_ADDRESS`) | Routing / masquerading misconfiguration |
| `Service backend not found` (`SERVICE_BACKEND_NOT_FOUND`) | Service with no ready endpoints |

> [!TIP]
> L7 fields (HTTP method, path, status) only appear when traffic passes through Cilium's proxy, for example when an L7 policy applies. Otherwise you see L3/L4 flows only.

**Hubble UI:** pick the namespace, and the service map shows edges between workloads. Dropped flows in the flow table point directly at the broken hop. Click a flow to see its identity, labels and drop reason.

Reference: [Hubble Observability](https://docs.cilium.io/en/stable/observability/hubble/)

---

## 2. Prometheus: Network Health Metrics

Use the Prometheus UI (Graph tab) or `curl` the API. Start broad (which service?), then narrow (which backend? which pod?).

```bash
curl -s 'http://<prometheus>:9090/api/v1/query' --data-urlencode 'query=up == 0' | jq '.data.result[].metric'
```

### Queries worth knowing

```promql
# Targets that are down
up == 0

# Hubble: drops by reason (per-namespace splits need e.g. drop:sourceContext=namespace)
sum by (reason) (rate(hubble_drop_total[5m]))

# Hubble HTTP: error rate per destination workload
# (needs httpV2 with labelsContext including destination_namespace,destination_workload)
sum by (destination_workload) (rate(hubble_http_requests_total{status=~"5.."}[5m]))

# Istio: 5xx rate per destination service
sum by (destination_service) (rate(istio_requests_total{response_code=~"5.."}[5m]))

# Istio: p99 latency per service
histogram_quantile(0.99,
  sum by (le, destination_service) (rate(istio_request_duration_milliseconds_bucket[5m])))

# Envoy Gateway: upstream 5xx per cluster
# (Istio waypoints expose these only with proxyStatsMatcher; use istio_requests_total instead)
sum by (envoy_cluster_name) (rate(envoy_cluster_upstream_rq_xx{envoy_response_code_class="5"}[5m]))

# Envoy: unhealthy hosts per upstream cluster
envoy_cluster_membership_healthy < envoy_cluster_membership_total

# CoreDNS: failing lookups
sum by (rcode) (rate(coredns_dns_responses_total{rcode=~"SERVFAIL|NXDOMAIN"}[5m]))

# Pods restarting (often the "unhealthy backend")
increase(kube_pod_container_status_restarts_total[15m]) > 0
```

Exact metric and label names depend on which exporters are installed. Use the metrics explorer (or `{__name__=~"hubble.*"}`) to see what exists before writing a query.

### Identifying a problematic backend

1. Find the service with errors or latency: `sum by (destination_service)`.
2. Split by workload: `sum by (destination_workload)`, or `by (pod)` with `reporter="destination"` if your scrape config adds a `pod` label.
3. Compare one pod against the others. A single outlier usually means a bad pod, node or probe. All pods bad usually means a dependency, policy or config.
4. Confirm with `kubectl get endpointslices`, pod logs and Hubble flows to that pod.

Reference: [PromQL Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/) | [Istio Standard Metrics](https://istio.io/latest/docs/reference/config/metrics/)

---

## 3. Jaeger: End-to-end Tracing

A trace is a tree of **spans**, one per hop (gateway → waypoint → service A → service B). Each span has a duration, tags (HTTP status, peer address, upstream cluster) and the trace ID that ties them together.

### How traces reach Jaeger (Istio)

```yaml
# meshConfig: register Jaeger as an OpenTelemetry tracing provider
meshConfig:
  extensionProviders:
  - name: jaeger
    opentelemetry:
      service: jaeger-collector.istio-system.svc.cluster.local
      port: 4317
---
# Turn tracing on mesh-wide
apiVersion: telemetry.istio.io/v1
kind: Telemetry
metadata:
  name: mesh-default
  namespace: istio-system
spec:
  tracing:
  - providers:
    - name: jaeger
    randomSamplingPercentage: 100
```

In ambient mode, spans come from **waypoints** and gateways (L7), not ztunnel. Applications must propagate trace headers (`traceparent`, `x-b3-*`) for a trace to span multiple services.

### Reading a trace to find the slow hop

1. Jaeger UI → **Service** = the entry point (gateway) → **Find Traces**. Sort by **Longest First**, or filter with `Min Duration` / tags like `http.status_code=503` or `error=true`.
2. Open a trace. The timeline shows which span takes the time. A parent span that is long while its children are short means the time is spent **in** that service, not downstream.
3. Look for gaps between spans (network or queueing delay), repeated child spans (retries) and spans with `error=true`.
4. Check the span tags (`upstream_cluster`, `peer.address`, `node_id`) to identify the exact pod or node, then confirm with metrics or `tcpdump`. Network delay on one node shows up as only the spans to pods on that node being slow (see `tc netem` in Domain 1).

Reference: [Istio Distributed Tracing](https://istio.io/latest/docs/tasks/observability/distributed-tracing/) | [Jaeger Documentation](https://www.jaegertracing.io/docs/latest/)

---

## 4. Auditing Traffic with Logs

### Envoy Gateway: data-plane access logs

Envoy Gateway runs one Envoy Deployment per Gateway in `envoy-gateway-system`. Access logs are on by default and written as JSON to the `envoy` container.

```bash
# Envoy proxy pods for a given Gateway
kubectl -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=web-gw

# Raw access logs
kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=web-gw -c envoy --tail=200

# Control-plane (translation / config) logs
kubectl -n envoy-gateway-system logs deploy/envoy-gateway
```

Useful default fields: `x-envoy-origin-path`, `method`, `response_code`, `response_flags`, `user-agent`, `x-forwarded-for`, `downstream_remote_address`, `upstream_host`, `duration`.

### Finding who is sending bad traffic to a path

```bash
LOGS=$(kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=web-gw -c envoy --tail=-1)

# Which user agents hit /api/login with 4xx/5xx, most frequent first
echo "$LOGS" | jq -R 'fromjson? | select((."x-envoy-origin-path" // "") | startswith("/api/login"))
  | select((.response_code | tonumber) >= 400) | ."user-agent"' | sort | uniq -c | sort -rn

# Which client IPs
echo "$LOGS" | jq -R -r 'fromjson? | select((."x-envoy-origin-path" // "") | startswith("/api/login"))
  | "\(.response_code) \(."x-forwarded-for" // .downstream_remote_address)"' | sort | uniq -c | sort -rn

# Without jq
echo "$LOGS" | grep '/api/login' | grep -o '"user-agent":"[^"]*"' | sort | uniq -c | sort -rn
```

### Envoy `response_flags`: why Envoy failed a request

| Flag | Meaning |
|------|---------|
| `UH` | No healthy upstream hosts |
| `UF` | Upstream connection failure |
| `URX` | Retry / connect attempts exhausted |
| `UT` | Upstream request timeout |
| `NR` | No route configured (route/host match failed) |
| `UAEX` | External authorization denied |
| `RL` | Rate limited |
| `DC` | Downstream (client) closed the connection |

### Other logs that matter

| Component | Command | What you get |
|-----------|---------|--------------|
| Istio waypoint (Envoy) | `kubectl -n <ns> logs deploy/waypoint` | L7 access logs once enabled via the Telemetry API (`accessLogging: [{providers: [{name: envoy}]}]`) |
| ztunnel | `kubectl -n istio-system logs -l app=ztunnel` | L4 connections with `src.identity` / `dst.identity`, policy denials |
| Cilium agent | `kubectl -n kube-system logs ds/cilium` | Datapath / policy / BGP errors |
| CoreDNS | `kubectl -n kube-system logs -l k8s-app=kube-dns` | Query log when the `log` plugin is on, plus upstream errors |
| Hubble | `hubble observe -o json` | Per-flow audit trail including verdicts |

Reference: [Envoy Gateway Proxy Observability](https://gateway.envoyproxy.io/docs/tasks/observability/proxy-observability/) | [Envoy Access Log Format](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage)

---

## 5. Putting It Together: Locating a Failure

```text
Symptom reported
   │
   ├─ Which service? ───────────► Prometheus: error rate / latency by service
   ├─ Which hop is slow? ───────► Jaeger: longest span, gaps, retries
   ├─ Is traffic dropped? ──────► Hubble: --verdict DROPPED, drop reason
   ├─ Who sent it / what path? ─► Envoy access logs: path, status, user-agent, client IP
   └─ Packet-level proof ───────► tcpdump on the node / pod interface (Domain 1)
```

1. **Scope:** one client, one service, or everything? One node or all?
2. **Layer:** a timeout points at L3/L4 (policy, routing, encryption). A 4xx/5xx points at L7 (policy, route, backend).
3. **Locate:** use the tool that answers that layer's question.
4. **Fix and verify:** re-run the same query and confirm the symptom is gone.

---

## 6. Hands-on Checklist

- [ ] Use the Hubble CLI to list dropped flows in a namespace and read the drop reason
- [ ] Use the Hubble UI service map to spot a broken edge between two workloads
- [ ] Filter Hubble flows by pod, label, port, HTTP status and DNS
- [ ] Find the service with the highest error rate and the slowest p99 in Prometheus
- [ ] Narrow an error spike to a single unhealthy backend pod
- [ ] Open a trace in Jaeger and identify which hop adds the latency
- [ ] Read Envoy Gateway access logs and explain a `response_flags` value
- [ ] For a given URL path, find the user agent and client IP sending failing requests
- [ ] Trace a denied request through ztunnel or waypoint logs
