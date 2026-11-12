# Certified Kubernetes Network Engineer (CKNE) Learning Path (2026)

![Kubernetes](https://img.shields.io/badge/Kubernetes-v1.37-326CE5?logo=kubernetes&logoColor=white)
![Exam](https://img.shields.io/badge/CKNE-Exam%20Prep-green)
![Passing Score](https://img.shields.io/badge/Passing%20Score-67%25-blue)
![Duration](https://img.shields.io/badge/Duration-2%20Hours-orange)
![License](https://img.shields.io/badge/License-All%20Rights%20Reserved-red)

A structured, hands-on learning path for the **Certified Kubernetes Network Engineer (CKNE)** exam from the Linux Foundation and CNCF. It follows the official curriculum domain by domain. For each topic you get the concept, working YAML, the commands to verify it and the failures you should be able to fix.

---
## Hit the Star! :star:
If you plan to use this repo as a reference, please hit the star. Thanks!

---

## CKNE Exam Coupon (40% Off Exclusive Discount)

To save a flat 40% on CKNE exam registration, use the following coupon code.
> [!IMPORTANT]
> **Coupon:** Use code **40KUBE26CT** at [kube.promo/cka](https://kube.promo/recommends/ckne/)

Use code **40KUBE26CT** to save up to 47% on the following bundles:

- CKA + CKAD: [kube.promo/cka-ckad](https://kube.promo/cka-ckad)
- CKA + CKS Bundle: [kube.promo/bundle](https://kube.promo/bundle)
- CKA + CKAD + CKS Exam bundle: [kube.promo/k8s-bundle](https://kube.promo/k8s-bundle)
- KCNA + KCSA + CKA + CKAD + CKS: [kube.promo/kubestronaut](https://kube.promo/kubestronaut)
---


## About the Exam

| Item | Detail |
|------|--------|
| **Format** | Online, proctored, performance-based tasks in a Linux remote desktop |
| **Duration** | 2 hours |
| **Passing Score** | 67% |
| **Kubernetes Version** | v1.37 |
| **Results** | Emailed within 24 hours |
| **Retake** | One retake included |
| **Eligibility** | 12 months from purchase |
| **Validity** | 2 years |
| **Simulator** | Killer.sh, 2 attempts with 36 hours of access each |

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
> **Service Networking (25%)** and **Network Security (25%)** together make up half the exam. Troubleshooting runs through every domain, so for each feature you build, also practise breaking it and fixing it.

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

## The Learning Path

The domains build on each other, so study them in this order. Every later topic assumes a working CNI, so a Cilium cluster comes first.

| Week | Focus | What you should be able to do at the end |
|:----:|-------|-------------------------------------------|
| 1 | Domain 1 | Install Cilium with kube-proxy replacement and BPF masquerading. Debug pod-to-pod traffic and DNS with `ip`, `iptables`, `tcpdump` |
| 2 | Domain 2 | Expose apps with L4 Services and MetalLB. Customise CoreDNS. Fix broken endpoints and probes. Route HTTP with Gateway API |
| 3 | Domain 4 | Write Kubernetes and Cilium L3/L4/L7 policies. Enable WireGuard. Terminate TLS on a Gateway. Secure workloads with Istio ambient |
| 4 | Domain 3 | Peer over BGP. Pin egress to a gateway node. Connect two clusters with Cluster Mesh. Route inference traffic with an InferencePool |
| 5 | Domain 5 | Find drops in Hubble, failing backends in Prometheus, slow hops in Jaeger and bad clients in Envoy access logs |
| 6 | Review | Solve the practice tasks under time pressure, then use your Killer.sh sessions |

---

## Repository Contents

| File | Purpose |
|------|---------|
| [study-notes/](./study-notes/) | One file per exam domain: concepts, YAML, verification and troubleshooting |
| [PRACTICE_QUESTIONS.md](./PRACTICE_QUESTIONS.md) | Exam-style scenario tasks with hidden solutions |
| [CHEATSHEET.md](./CHEATSHEET.md) | One-page command reference for every tool on the exam |
| [EXAM_GUIDE.md](./EXAM_GUIDE.md) | Exam environment, exam-day strategy and FAQs |

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

Corrections and additions are welcome. See [CONTRIBUTING.md](./CONTRIBUTING.md).

> ⭐ If this guide helped you, please star the repo!
