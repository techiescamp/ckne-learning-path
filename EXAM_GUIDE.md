# CKNE Exam Guide: Environment, Strategy and FAQ

> What the CKNE exam environment looks like, how to spend your 2 hours, and answers to common questions.

## Index

1. [The Exam Environment](#1-the-exam-environment)
2. [What Candidates Should Expect](#2-what-candidates-should-expect)
3. [First Minutes of the Exam](#3-first-minutes-of-the-exam)
4. [Time Management](#4-time-management)
5. [Per-task Workflow](#5-per-task-workflow)
6. [Common Traps](#6-common-traps)
7. [FAQ](#7-faq)

---

## 1. The Exam Environment

From the official [Important Instructions: CKNE](https://docs.linuxfoundation.org/tc-docs/certification/important-instructions-ckne):

- You work in a **Linux remote desktop** inside the PSI Secure Browser, with a terminal, Firefox, VSCodium and a virtual keyboard.
- Every task names a **designated host**. An infobox gives the `ssh <host>` command. Do the task there and `exit` back to `base` afterwards. Nested SSH is not supported.
- `sudo -i` gives root on any task host.
- Task hosts come with `kubectl` (with the `k` alias and completion), `yq`, `curl`, `wget` and `man`. The `base` machine has none of these.
- The cluster runs **Kubernetes v1.37**.
- Tools that may appear: **Istio, Cilium, Envoy, Gateway API, Hubble, Prometheus, Helm, Jaeger, cert-manager**. Deep tool-specific knowledge is only tested where the curriculum references it.
- Never reboot `base`. Doing so does not restart your exam environment.

| Action | Shortcut |
|--------|----------|
| Copy / paste in the **terminal** | `Ctrl+Shift+C` / `Ctrl+Shift+V` (or right-click) |
| Copy / paste in **other apps** | `Ctrl+C` / `Ctrl+V` |
| `Ctrl+W` inside the remote desktop (e.g. delete word in the terminal) | `Ctrl+Alt+W`. Plain `Ctrl+W` closes the browser tab |
| Locate the mouse cursor | `Ctrl+Alt+K` |
| Vim insert mode | `i` (the INSERT key is disabled) |

Allowed documentation: [Resources Allowed](https://docs.linuxfoundation.org/tc-docs/certification/certification-resources-allowed).

---

## 2. What Candidates Should Expect

Prepare for these characteristics of the exam.

**Observability tools are already running.** Browser access to the **Prometheus, Hubble and Jaeger** UIs is part of the environment. You will be expected to *use* them to find problems, not to install them. Get comfortable navigating each UI quickly: the Prometheus graph and query view, the Hubble service map and flow table, and Jaeger trace search and timeline.

**Tasks tell you how they will be checked.** Most tasks that involve connectivity or TLS include the `curl` / `openssl` style commands that prove the result. Run them once **before** you change anything, to see the failure, and again **after**, to confirm the fix. Don't invent your own test when one is provided.

**Documentation links come with each task.** Each task has a **Quick Reference** box with the relevant documentation links. Open those instead of searching. They usually point to the exact page with the YAML you need.

**There is an on-screen scratchpad.** A scratchpad for notes and drawings is available inside the exam console. Paper and physical whiteboards are not allowed. Sketch the traffic path before multi-hop tasks (client → gateway → route → policy → service → pod, or pod → egress node → external) and mark where the task says it breaks.

**Breaks are possible but limited.** You may take a small number of short breaks (about three). The timer keeps running, so plan them between tasks rather than in the middle of one.

**The remote desktop can be sluggish.** Expect the occasional UI glitch, and **copy/paste does not always work reliably**. Plan for it:

- Be able to type the common commands and YAML skeletons from memory. Do not depend on copying long blocks from the docs.
- When a paste fails, try the right-click menu, or paste into `vim` (`:set paste` first) instead of directly into the shell.
- Keep YAML small: `kubectl create ... --dry-run=client -o yaml`, then edit, beats pasting a 60-line manifest.
- If the desktop freezes, wait a few seconds before clicking repeatedly.

---

## 3. First Minutes of the Exam

The `k` alias and completion already exist on task hosts. Each task is on a fresh SSH session, so keep any extra setup to one line you can retype:

```bash
export do="--dry-run=client -o yaml" now="--force --grace-period=0"
```

```bash
# vim settings for YAML (once per host if you edit a lot)
printf 'set tabstop=2 shiftwidth=2 expandtab\n' >> ~/.vimrc
```

Skim **all** tasks first and note the weight of each. Network tasks vary a lot in effort: a CoreDNS forward is a 3-minute fix, while Cluster Mesh or BGP can take 15.

---

## 4. Time Management

| Domain | Weight | Suggested time |
|--------|:------:|:--------------:|
| Service Networking and DNS | 25% | ~30 min |
| Network Security and Policy | 25% | ~30 min |
| Advanced Traffic Management | 20% | ~24 min |
| Core Infrastructure and CNI | 15% | ~18 min |
| Observability | 15% | ~18 min |

**Three passes:**

1. **Pass 1 (~60 min):** quick wins: CoreDNS, Services, probes, NetworkPolicies, Gateway routes, observability lookups.
2. **Pass 2 (~45 min):** the multi-step builds: BGP, egress gateway, Cluster Mesh, Istio policies, inference routing.
3. **Buffer (~15 min):** re-run every provided verification command.

If a task has eaten more than ~8 minutes without visible progress, flag it and move on.

---

## 5. Per-task Workflow

```text
1. ssh <designated-host>                       (from the task infobox)
2. Read the whole task. Note namespace, names, ports, IPs, CIDRs, file paths
3. Run the provided check → see the failure
4. Sketch the path on the scratchpad if more than two hops are involved
5. Fix / build, using the linked docs
6. Run the provided check → see it pass
7. exit
```

**Read for exact values.** Many tasks are graded on precise names, namespaces, packet counts, output file paths, ASN numbers or IPs. A correct solution with the wrong name scores zero.

---

## 6. Common Traps

| Trap | Prevention |
|------|-----------|
| Working on the wrong host | Check the hostname in your prompt before every change |
| Default-deny breaks DNS | Always allow UDP+TCP 53 to `kube-dns` alongside egress deny |
| Cilium setting changed but not applied | `rollout restart ds/cilium` (and the operator) after Helm/CLI changes |
| Testing a Gateway without the right host | Use `curl --resolve host:port:IP` or `-H "Host: ..."` |
| L7 policy "does nothing" | Cilium: no `rules.http`. Istio ambient: no waypoint or wrong `targetRefs` |
| tcpdump hangs | Add `-nn`, and `-c <count>` when a count is requested |
| Corefile edit silently ignored | Syntax error: check CoreDNS logs right after editing |
| Hand-written EndpointSlice ignored | Missing `kubernetes.io/service-name` label or port name mismatch |
| Cluster Mesh never connects | Duplicate `cluster.id`, overlapping pod CIDRs, or no shared CA |

---

## 7. FAQ

**Q: Do I need the CKA first?**

A: No. The CKNE has no prerequisites, but it assumes CKA-level comfort with `kubectl`, Pods, Deployments and Services.

**Q: What is the passing score?**

A: 67%. Results are emailed within 24 hours.

**Q: Is it all Cilium?**

A: Cilium is the central CNI, but tasks also involve Istio ambient, Envoy and Envoy Gateway, Gateway API, CoreDNS, MetalLB, kube-router and plain Linux networking (`ip`, `iptables`, `tcpdump`). The study notes cover each one where the curriculum needs it.

**Q: Will I have to install Prometheus, Hubble or Jaeger?**

A: Expect to use them, not set them up. Spend your practice time on queries, filters and reading traces.

**Q: How many simulator attempts do I get?**

A: Two Killer.sh attempts per registration, each with 36 hours of access. Save them for the last week, after you have worked through the practice tasks.

**Q: Is there a retake?**

A: Yes, one retake is included with the exam. The exam must be taken within 12 months of purchase, and the certification is valid for 2 years.

More official answers: [Frequently Asked Questions: CKNE](https://docs.linuxfoundation.org/tc-docs/certification/frequently-asked-questions-ckne).
