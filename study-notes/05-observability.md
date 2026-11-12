# Domain 5: Observability (15%)

> **Exam Weight: 15%**: This domain tests whether you can judge network health from metrics, follow end-to-end performance through traces, and audit traffic using logs.

Observability tasks rarely ask you to install anything. Instead, they give you a broken or misbehaving system and ask you to find *where* traffic fails, *which* backend is unhealthy, or *who* is sending bad requests. Because of this, practise reading the Hubble, Prometheus and Jaeger UIs as well as using their CLIs.

## Index

1. [Hubble: Network Flows](#1-hubble-network-flows)
2. [Prometheus: Network Health Metrics](#2-prometheus-network-health-metrics)
3. [Jaeger: End-to-end Tracing](#3-jaeger-end-to-end-tracing)
4. [Auditing Traffic with Logs](#4-auditing-traffic-with-logs)
5. [Putting It Together: Locating a Failure](#5-putting-it-together-locating-a-failure)
6. [Hands-on Checklist](#6-hands-on-checklist)

---

## 1. Hubble: Network Flows

Hubble records every flow that Cilium handles. For each flow it shows the source and destination identity, the verdict (`FORWARDED`, `DROPPED` or `AUDIT`) and the drop reason. When the traffic passes through an L7 proxy, Hubble also records the HTTP or DNS details.

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

The default output shows the readable drop reason, while the `-o json` pipeline above prints the enum name instead. The table below lists both forms, together with the usual cause of each drop.

| Drop reason (enum in JSON) | Typical cause |
|----------------------------|---------------|
| `Policy denied` (`POLICY_DENIED`) | No policy allows this identity on this port (see Domain 4) |
| `Policy denied by denylist` (`POLICY_DENY`) | An explicit `ingressDeny` or `egressDeny` rule blocks the traffic |
| `Stale or unroutable IP` (`STALE_OR_UNROUTABLE_IP`) | The endpoint is gone, for example because the pod restarted |
| `No mapping for NAT masquerade` (`NO_MAPPING_FOR_NAT_MASQUERADE`) / `Unknown L3 target address` (`UNKNOWN_L3_TARGET_ADDRESS`) | Routing or masquerading is misconfigured |
| `Service backend not found` (`SERVICE_BACKEND_NOT_FOUND`) | The Service has no ready endpoints |

> [!TIP]
> L7 fields such as the HTTP method, path and status only appear when traffic passes through Cilium's proxy, for example when an L7 policy applies to it. Otherwise, you only see L3/L4 flows.

**Hubble UI:** Once you pick a namespace, the service map shows the edges between its workloads. Dropped flows in the flow table point directly at the broken hop, and when you click a flow you can see its identity, labels and drop reason.

Reference: [Hubble Observability](https://docs.cilium.io/en/stable/observability/hubble/)

---

## 2. Prometheus: Network Health Metrics

You can query Prometheus from its UI (the Graph tab) or `curl` the API directly. Start broad by finding which service is affected, and then narrow it down to the backend and finally the pod.

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

Exact metric and label names depend on which exporters are installed, so a query from these notes may return nothing on your cluster. Before writing a query, use the metrics explorer (or `{__name__=~"hubble.*"}`) to see which metrics actually exist.

### Identifying a problematic backend

1. Find the service that shows errors or high latency by grouping with `sum by (destination_service)`.
2. Split that service's traffic by workload with `sum by (destination_workload)`. If your scrape config adds a `pod` label, you can instead split `by (pod)` with `reporter="destination"`.
3. Compare each pod against the others. If a single pod stands out, the cause is usually a bad pod, node or probe. If all pods are bad, the cause is more likely a dependency, policy or config that they share.
4. Confirm your finding with `kubectl get endpointslices`, the pod logs and the Hubble flows to that pod.

Reference: [PromQL Basics](https://prometheus.io/docs/prometheus/latest/querying/basics/) | [Istio Standard Metrics](https://istio.io/latest/docs/reference/config/metrics/)

---

## 3. Jaeger: End-to-end Tracing

A trace is a tree of **spans**, with one span for each hop (gateway → waypoint → service A → service B). Each span records its duration, tags such as the HTTP status, peer address and upstream cluster, and the trace ID that ties all the spans of one request together.

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

In ambient mode, spans come from **waypoints** and gateways, which work at L7, and not from ztunnel. In addition, applications must propagate the trace headers (`traceparent`, `x-b3-*`) on their outgoing calls; otherwise, a trace cannot span multiple services.

### Reading a trace to find the slow hop

1. In the Jaeger UI, set **Service** to the entry point (the gateway) and click **Find Traces**. Then sort by **Longest First**, or filter with `Min Duration` or with tags such as `http.status_code=503` or `error=true`.
2. Open a trace, and the timeline shows which span takes the time. If a parent span is long while its children are short, the time is being spent **in** that service rather than downstream.
3. Look for gaps between spans, which point to network or queueing delay, repeated child spans, which point to retries, and any spans with `error=true`.
4. Check the span tags (`upstream_cluster`, `peer.address`, `node_id`) to identify the exact pod or node, and then confirm it with metrics or `tcpdump`. For example, if one node has network delay, only the spans to pods on that node are slow (see `tc netem` in Domain 1).

Reference: [Istio Distributed Tracing](https://istio.io/latest/docs/tasks/observability/distributed-tracing/) | [Jaeger Documentation](https://www.jaegertracing.io/docs/latest/)

---

## 4. Auditing Traffic with Logs

### Envoy Gateway: data-plane access logs

Envoy Gateway runs one Envoy Deployment for each Gateway in the `envoy-gateway-system` namespace. Access logs are on by default and are written as JSON to the `envoy` container, so you can read them with the commands below.

```bash
# Envoy proxy pods for a given Gateway
kubectl -n envoy-gateway-system get pods -l gateway.envoyproxy.io/owning-gateway-name=web-gw

# Raw access logs
kubectl -n envoy-gateway-system logs -l gateway.envoyproxy.io/owning-gateway-name=web-gw -c envoy --tail=200

# Control-plane (translation / config) logs
kubectl -n envoy-gateway-system logs deploy/envoy-gateway
```

The default log format already includes the fields you need most often: `x-envoy-origin-path`, `method`, `response_code`, `response_flags`, `user-agent`, `x-forwarded-for`, `downstream_remote_address`, `upstream_host`, `duration`.

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
| `UH` | There are no healthy upstream hosts |
| `UF` | The connection to the upstream failed |
| `URX` | All retry or connect attempts were used up |
| `UT` | The upstream request timed out |
| `NR` | No route is configured, because the route or host match failed |
| `UAEX` | External authorization denied the request |
| `RL` | The request was rate limited |
| `DC` | The downstream client closed the connection |

### Other logs that matter

| Component | Command | What you get |
|-----------|---------|--------------|
| Istio waypoint (Envoy) | `kubectl -n <ns> logs deploy/waypoint` | L7 access logs, once you enable them through the Telemetry API (`accessLogging: [{providers: [{name: envoy}]}]`) |
| ztunnel | `kubectl -n istio-system logs -l app=ztunnel` | L4 connections with `src.identity` and `dst.identity`, plus policy denials |
| Cilium agent | `kubectl -n kube-system logs ds/cilium` | Datapath, policy and BGP errors |
| CoreDNS | `kubectl -n kube-system logs -l k8s-app=kube-dns` | The query log when the `log` plugin is on, plus upstream errors |
| Hubble | `hubble observe -o json` | A per-flow audit trail, including verdicts |

Reference: [Envoy Gateway Proxy Observability](https://gateway.envoyproxy.io/docs/tasks/observability/proxy-observability/) | [Envoy Access Log Format](https://www.envoyproxy.io/docs/envoy/latest/configuration/observability/access_log/usage)

---

## 5. Putting It Together: Locating a Failure

When a symptom is reported, each question you ask about it maps to one tool, as the diagram below shows.

```text
Symptom reported
   │
   ├─ Which service? ───────────► Prometheus: error rate / latency by service
   ├─ Which hop is slow? ───────► Jaeger: longest span, gaps, retries
   ├─ Is traffic dropped? ──────► Hubble: --verdict DROPPED, drop reason
   ├─ Who sent it / what path? ─► Envoy access logs: path, status, user-agent, client IP
   └─ Packet-level proof ───────► tcpdump on the node / pod interface (Domain 1)
```

1. **Scope:** First work out whether the problem affects one client, one service or everything, and whether it happens on one node or on all of them.
2. **Layer:** A timeout points at L3/L4 (policy, routing or encryption), while a 4xx/5xx response points at L7 (policy, route or backend).
3. **Locate:** Use the tool that answers that layer's question, as mapped in the diagram above.
4. **Fix and verify:** After the fix, re-run the same query and confirm that the symptom is gone.

---

## 6. Hands-on Checklist

- [ ] Use the Hubble CLI to list the dropped flows in a namespace and read their drop reasons
- [ ] Use the Hubble UI service map to spot a broken edge between two workloads
- [ ] Filter Hubble flows by pod, label, port, HTTP status and DNS
- [ ] In Prometheus, find the service with the highest error rate and the one with the slowest p99 latency
- [ ] Narrow an error spike down to a single unhealthy backend pod
- [ ] Open a trace in Jaeger and identify which hop adds the latency
- [ ] Read the Envoy Gateway access logs and explain what a `response_flags` value means
- [ ] For a given URL path, find the user agent and client IP that are sending failing requests
- [ ] Follow a denied request through the ztunnel or waypoint logs
