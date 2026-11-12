# CKNE Exam Guide: Environment, Strategy and FAQ

> This guide explains what the CKNE exam environment looks like, how to spend your 2 hours, and the answers to questions candidates often ask.

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

The points below are a summary of the official [Important Instructions: CKNE](https://docs.linuxfoundation.org/tc-docs/certification/important-instructions-ckne):

- You work in a **Linux remote desktop** that runs inside the PSI Secure Browser. The desktop gives you a terminal, Firefox, VSCodium and a virtual keyboard.
- Every task names a **designated host** where the work must be done. An infobox in the task shows the `ssh <host>` command to reach it. When you finish the task, run `exit` to go back to `base` before you start the next one, because nested SSH sessions are not supported.
- On any task host, `sudo -i` gives you a root shell.
- The task hosts already have `kubectl` (with the `k` alias and shell completion), `yq`, `curl`, `wget` and `man` installed. The `base` machine has none of these, so always run your commands on the task host.
- The cluster runs **Kubernetes v1.37**.
- Tools that may appear in tasks include **Istio, Cilium, Envoy, Gateway API, Hubble, Prometheus, Helm, Jaeger and cert-manager**. Deep knowledge of one specific tool is only tested when the exam domains and competencies call for it.
- Never reboot `base`. Rebooting it does not restart your exam environment, so it only costs you time.

The remote desktop uses some keyboard shortcuts that differ from a normal machine:

| Action | Shortcut |
|--------|----------|
| Copy / paste in the **terminal** | `Ctrl+Shift+C` / `Ctrl+Shift+V` (or use right-click) |
| Copy / paste in **other apps** | `Ctrl+C` / `Ctrl+V` |
| `Ctrl+W` inside the remote desktop (e.g. delete a word in the terminal) | Use `Ctrl+Alt+W`, because plain `Ctrl+W` closes the browser tab |

For the list of documentation you may open during the exam, see [Resources Allowed](https://docs.linuxfoundation.org/tc-docs/certification/certification-resources-allowed). It allows the Kubernetes docs and blog, the Cilium docs, the Istio docs, and the task-specific links in each task's **Quick Reference** box.

---

## 2. What Candidates Should Expect

The exam has a few characteristics that are worth preparing for in advance.

**Observability tools are already running.** The environment gives you browser access to the **Prometheus, Hubble and Jaeger** UIs. You are expected to *use* these tools to find problems, not to install them. So practice moving around each UI quickly. In Prometheus, that means the graph and query view. In Hubble, it means the service map and flow table. In Jaeger, it means trace search and the timeline view.

**Tasks tell you how they will be checked.** Most tasks that involve connectivity or TLS include `curl` or `openssl` style commands that prove the result. Run these commands once **before** you change anything, so you see the failure. Then run them again **after** your change to confirm the fix. If a test is provided, use it instead of writing your own.

**Documentation links come with each task.** Every task has a **Quick Reference** box with the relevant documentation links. Open those links instead of searching, because they usually point to the exact page with the YAML you need.

**There is an on-screen scratchpad.** The exam console includes a scratchpad for notes and drawings. Paper and physical whiteboards are not allowed, because you may not write on anything outside the exam console. Before you start a multi-hop task, sketch the traffic path in the scratchpad. For example: client → gateway → route → policy → service → pod, or pod → egress node → external. Then mark the point where the task says it breaks.

**Breaks are possible but limited.** You may take a small number of short breaks (about three).

---

## 3. First Minutes of the Exam

The `k` alias and completion already exist on the task hosts. Because each task starts in a fresh SSH session, keep any extra setup short enough to fit on one line that you can retype on each host:

```bash
export do="--dry-run=client -o yaml" now="--force --grace-period=0"
```

```bash
# vim settings for YAML (once per host if you edit a lot)
printf 'set tabstop=2 shiftwidth=2 expandtab\n' >> ~/.vimrc
```

Next, skim **all** the tasks and note the weight of each one. Network tasks vary a lot in effort. For example, a CoreDNS forward is a 3-minute fix, while Cluster Mesh or BGP can take 15 minutes, so knowing this up front helps you decide what to do first.

---

## 4. Time Management

The suggested time for each domain follows its weight in the exam:

| Domain | Weight | Suggested time |
|--------|:------:|:--------------:|
| Service Networking and DNS | 25% | ~30 min |
| Network Security and Policy | 25% | ~30 min |
| Advanced Traffic Management | 20% | ~24 min |
| Core Infrastructure and CNI | 15% | ~18 min |
| Observability | 15% | ~18 min |

A good approach is to work through the exam in **three passes:**

1. **Pass 1 (~60 min):** Collect the quick wins first, such as CoreDNS, Services, probes, NetworkPolicies, Gateway routes and observability lookups.
2. **Pass 2 (~45 min):** Then move on to the multi-step builds: BGP, egress gateway, Cluster Mesh, Istio policies and inference routing.
3. **Buffer (~15 min):** Finally, use the remaining time to re-run every provided verification command.

If a task has taken more than ~8 minutes without visible progress, flag it and move on, because that time is better spent on tasks you can finish.

---

## 5. Per-task Workflow

Follow the same sequence for every task:

```text
1. ssh <designated-host>                       (from the task infobox)
2. Read the whole task. Note namespace, names, ports, IPs, CIDRs, file paths
3. Run the provided check → see the failure
4. Sketch the path on the scratchpad if more than two hops are involved
5. Fix / build, using the linked docs
6. Run the provided check → see it pass
7. exit
```

**Read for exact values.** Scoring is automatic, and tasks often depend on precise names, namespaces, packet counts, output file paths, ASNs or IPs. So a working solution with the wrong name can still fail the check.

---

## 6. Common Traps

These are the mistakes that most often cost points, together with how to avoid each one:

| Trap | Prevention |
|------|-----------|
| Working on the wrong host | Check the hostname in your prompt before every change |
| A default-deny policy breaks DNS | When you deny egress, always also allow UDP+TCP 53 to `kube-dns` |
| A Cilium setting was changed but not applied | After Helm/CLI changes, run `rollout restart ds/cilium` (and restart the operator too) |
| A hand-written EndpointSlice is ignored | It is missing the `kubernetes.io/service-name` label, or its port name does not match |
| Cluster Mesh never connects | Look for a duplicate `cluster.id`, overlapping pod CIDRs, or a missing shared CA |

---

## 7. FAQ

**Q: Do I need the CKA first?**

A: No. The CKNE has no prerequisites. However, it assumes CKA-level Kubernetes skills. So you should be as comfortable with `kubectl`, Pods, Deployments and Services as a CKA holder.

**Q: What is the passing score?**

A: The passing score is 67%, and results are emailed to you within 24 hours.

**Q: How many simulator attempts do I get?**

A: You get two Killer.sh attempts per exam registration. Each one gives you 36 hours of access from the moment you activate it. It is best to save them for the last week, after you have worked through the practice tasks.

**Q: Is there a retake?**

A: Yes, one retake is included with the exam. Keep in mind that you must take the exam within 12 months of purchase, and once you pass, the certification is valid for 2 years.

For more official answers, see [Frequently Asked Questions: CKNE](https://docs.linuxfoundation.org/tc-docs/certification/frequently-asked-questions-ckne).
