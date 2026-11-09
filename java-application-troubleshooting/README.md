# Project 01: Troubleshoot a Java App Latency Incident

## Project Overview

This is a troubleshooting scenario.

We have an application called **Staff Registry**. It is a Java app that stores its data in a database. When you run the setup script, the application is deployed in your cluster, and it is **slow**.

Users complain that pages take several seconds to load. The Pods are running and the logs show no errors.

You will find out why. We do not tell you the cause. You will find it yourself, with packets.

- Is it the **network**?
- Is it the **database**?
- Is it the **app itself**?

All outputs in this project are real, from a test run. Your Pod IPs, ports and exact timings will be a little different. The pattern will be the same.

## What You Will Do

1. Run one command to start the scenario.
2. Act like the end user: feel the slowness and measure it.
3. Use `tcpdump` to find the slow part. For every command you run, you will see **why** you run it and **how to read** the output.
4. Name the cause, apply the fix, and prove it with numbers.

## One Important Limitation

**Start tcpdump before you send the request.** If you start late, you will miss the packets. A packet capture only records what happens while it is running. You cannot go back in time.

> Packets show where the time goes. They don't show why the code is slow.

## Environment

- A Kubernetes cluster with 3 nodes (1 control plane + 2 workers)
- `kubectl` 1.27 or higher (needed for `kubectl debug --profile=netadmin`)
- `helm` 3 or higher
- Nodes can pull images from Docker Hub

Check your cluster first. A wrong kubectl context is the most common mistake:

```bash
kubectl version
kubectl config current-context
kubectl get nodes
```

Set the project location once. All commands below use it:

```bash
export LAB=https://raw.githubusercontent.com/techiescamp/ckne/main/java-application-troubleshooting
```

---

## Step 1: Start the Scenario

One command:

```bash
curl -fsSL $LAB/scripts/setup.sh | bash
```

It installs the Staff Registry Helm chart, creates a small `client` Pod, waits until everything is ready, and starts the incident. It takes about a minute.

Real output:

```
Cluster context: <your-cluster>
Release "staff-registry" does not exist. Installing it now.
NAME: staff-registry
STATUS: deployed
...
Waiting for the Java app to start (20 to 30 seconds)...

NAME                                  READY   STATUS    RESTARTS   AGE   IP           NODE
client                                1/1     Running   0          23s   10.244.3.3   worker
staff-registry-app-54c45b444c-lppr9   1/1     Running   0          33s   10.244.3.2   worker
staff-registry-postgres-0             1/1     Running   0          33s   10.244.1.2   worker2

Scenario ready.
Users report that the Staff Registry page is very slow. Find out why.
```

You now have:

| What | Name |
|---|---|
| The Java app | Deployment `staff-registry-app` (Service `staff-registry-app-svc`, port 80) |
| The database | Pod `staff-registry-postgres-0` |
| A test client that plays the end user | Pod `client` |

The incident is running.

---

## Step 2: Feel the Problem, Then Look Closer

### 2.1 Reproduce it and put a number on it

**Why:** never trust "it feels slow". Measure it, so you can later prove the fix. A simple page like this should answer in a few milliseconds.

```bash
kubectl exec client -- curl -s -o /dev/null \
  -w "Total time: %{time_total}s\n" \
  http://staff-registry-app-svc/api/dashboard/status
```

```
Total time: 4.009443s
```

**How to read it:** the problem is real. You will see between 3 and 4 seconds, which is far too slow.

### 2.2 Check the cheap things first

**Why:** most incidents are simple. Rule out crashes and errors before you capture packets.

```bash
kubectl get pods
kubectl logs deploy/staff-registry-app --tail=20
```

```
NAME                                  READY   STATUS    RESTARTS   AGE
client                                1/1     Running   0          38s
staff-registry-app-54c45b444c-lppr9   1/1     Running   0          48s
staff-registry-postgres-0             1/1     Running   0          48s
```

**How to read it:** all Pods are `Running`, `1/1`, with 0 restarts. The logs show no error. So Kubernetes says "healthy" while users feel "slow". This is the typical latency incident: nothing is broken, it is just slow. We need evidence from the wire.

### 2.3 Split the time into parts

**Why:** `curl` can tell us which phase is slow: finding the address, connecting, or waiting for the answer.

```bash
kubectl exec client -- curl -s -o /dev/null \
  -w "DNS lookup:  %{time_namelookup}s\nTCP connect: %{time_connect}s\nFirst byte:  %{time_starttransfer}s\nTotal:       %{time_total}s\n" \
  http://staff-registry-app-svc/api/dashboard/status
```

```
DNS lookup:  0.000405s
TCP connect: 0.000477s
First byte:  4.006668s
Total:       4.006708s
```

**How to read it:**

- DNS is fast (under 1 ms).
- Connecting is fast (under 1 ms).
- The **first byte** comes after 4 seconds.

So the server accepted our connection quickly, then took seconds to start answering. The problem is **after the connection is made**. But curl only sees the client side. To see what happens inside, we capture packets on the app Pod.

### 2.4 Make sure there is only one app replica

**Why:** with several replicas, requests are spread across different Pods. You could capture on one Pod while your request goes to another. This setup runs one replica. Make sure:

```bash
kubectl scale deploy/staff-registry-app --replicas=1
```

### 2.5 Save the client IP and the app Pod name

**Why:** we filter the capture by the client IP, so we see only our test traffic and not the Kubernetes health-check traffic.

```bash
CLIENT_IP=$(kubectl get pod client -o jsonpath='{.status.podIP}')
POD=$(kubectl get pods -l app=staff-registry-app -o name | head -1)
echo $CLIENT_IP $POD
```

```
10.244.3.3 pod/staff-registry-app-54c45b444c-lppr9
```

---

## Step 3: Start tcpdump

**Why on the app Pod:** the app is the middle of the chain. From here we can see both sides: the user side (port 8080) and the side where the app gets its data (port 5432).

```
client  --8080-->  app Pod  --5432-->  database
```

The app container has no `tcpdump`. We attach a temporary debug container that has it:

```bash
kubectl debug -it $POD \
  --image=nicolaka/netshoot \
  --profile=netadmin \
  --target=staff-registry-app \
  -- tcpdump -i eth0 -nn -ttt "tcp port 8080 and host $CLIENT_IP"
```

| Option | Meaning |
|---|---|
| `--profile=netadmin` | Gives the debug container the permission to capture packets |
| `--target=staff-registry-app` | Shares the network of the app container |
| `-i eth0` | Listen on the Pod's network interface |
| `-nn` | Do not resolve names. Faster and cleaner |
| `-ttt` | Show the **time since the previous packet**. This is the key option for latency |
| `tcp port 8080 and host $CLIENT_IP` | Only our client talking to the app port |

Wait until you see `listening on eth0`.

> **Start tcpdump before sending the request.** Otherwise you will miss the packets that show where the delay happened.

---

## Step 4: Send a Test Request

Open a **second terminal** and send one request:

```bash
kubectl exec client -- curl -s -o /dev/null \
  -w "Total time: %{time_total}s\n" \
  http://staff-registry-app-svc/api/dashboard/status
```

```
Total time: 4.007814s
```

When it finishes, go back to the tcpdump terminal and press **Ctrl+C**.

---

## Step 5: Read the Result (client to app)

Real output. Long TCP options are removed for easy reading:

```
00:00:00.000000 IP 10.244.3.3.40200 > 10.244.3.2.8080: Flags [S],  length 0
00:00:00.000009 IP 10.244.3.2.8080 > 10.244.3.3.40200: Flags [S.], length 0
00:00:00.000011 IP 10.244.3.3.40200 > 10.244.3.2.8080: Flags [.],  ack 1, length 0
00:00:00.000036 IP 10.244.3.3.40200 > 10.244.3.2.8080: Flags [P.], length 106: HTTP: GET /api/dashboard/status HTTP/1.1
00:00:00.000002 IP 10.244.3.2.8080 > 10.244.3.3.40200: Flags [.],  ack 107, length 0
00:00:04.007062 IP 10.244.3.2.8080 > 10.244.3.3.40200: Flags [P.], length 237: HTTP: HTTP/1.1 200
00:00:00.000043 IP 10.244.3.3.40200 > 10.244.3.2.8080: Flags [.],  ack 238, length 0
00:00:00.000271 IP 10.244.3.3.40200 > 10.244.3.2.8080: Flags [F.], length 0
00:00:00.000452 IP 10.244.3.2.8080 > 10.244.3.3.40200: Flags [F.], length 0
00:00:00.000023 IP 10.244.3.3.40200 > 10.244.3.2.8080: Flags [.],  ack 239, length 0
```

**How to read it:** look at the **left column**. It is the time since the previous packet.

| What you see | Time | What it means |
|---|---|---|
| Handshake (`S`, `S.`, `.`) | 9 to 11 microseconds | Connecting is instant |
| `GET` goes out, the Pod ACKs it | 2 microseconds | The request arrived fine |
| **Gap before `HTTP/1.1 200`** | **4.01 seconds** | **This is the only line that matters** |
| Closing (`F.`) | under 0.5 ms | Network is healthy again |

**Conclusion 1:** the request reached the Pod instantly, but the response came late. So the network between the client and the app is **healthy**. Suspect 1, the network, is cleared. The delay is inside the app, or in something the app waits for.

---

## Check What the App Waits For

**Why:** the app needs data to build this page. It gets the data from the database on port 5432. We follow the request to the next hop.

> **Real-world detail:** the app also checks the database by itself every few seconds, in the background. If you capture only port 5432, you may see packets that are **not** from your request. They use other source ports. So capture port 8080 and port 5432 **together**, with absolute time (`-tt`). Then look only at the packets between the `GET` and the `200`.

Start the capture (again **before** the request):

```bash
kubectl debug -it $POD \
  --image=nicolaka/netshoot \
  --profile=netadmin \
  --target=staff-registry-app \
  -- tcpdump -i eth0 -nn -tt "(tcp port 8080 and host $CLIENT_IP) or tcp port 5432"
```

From the second terminal, send the request again:

```bash
kubectl exec client -- curl -s -o /dev/null \
  -w "Total time: %{time_total}s\n" \
  http://staff-registry-app-svc/api/dashboard/status
```

```
Total time: 4.006783s
```

Press Ctrl+C. These are the packets that carry data inside the request window. The time is in seconds after the `GET` arrived. `client` = 10.244.3.3, `app` = 10.244.3.2, `postgres` = 10.244.1.2.

```
 0.000  client      > app:8080         GET /api/dashboard/status
 0.002  app:36356    > postgres:5432   query 1 sent
 0.609  postgres     > app:57392       (background check, not our request)
 1.002  postgres     > app:36356       reply 1           <-- 1.0 s later
 1.002  app:36356    > postgres:5432   query 2 sent
 2.003  postgres     > app:36356       reply 2           <-- 1.0 s later
 2.003  app:36356    > postgres:5432   query 3 sent
 3.004  postgres     > app:36356       reply 3           <-- 1.0 s later
 3.004  app:36356    > postgres:5432   query 4 sent
 4.005  postgres     > app:36356       reply 4           <-- 1.0 s later
 4.006  app:8080     > client          HTTP/1.1 200
```

**How to read it:**

1. The app sends a query, and the database answers **exactly 1.0 second later**. Four times in a row.
2. 4 queries x 1.0 s = **4.0 s**. The client measured 4.007 s. The numbers add up. The whole delay is explained. (Some runs show 3 queries and 3 seconds. The rule is the same: queries x 1.0 s.)
3. After each reply, the app sends the next query within about 1 millisecond. So the **app code is not slow**. It does almost no work between replies. It is only waiting.
4. Your request is the connection that sends the first query right after the `GET` (port 36356 here). The line on port 57392 is background noise.

```
client --(instant)--> app --query--> postgres
                       |                 |
                       |<--- 1.0 s ------|   (x 4 times)
                       v
                 answer after 4 s
```

### What we found

| Suspect | Verdict | Evidence |
|---|---|---|
| Network (client to app) | Cleared | Handshake in microseconds, request ACKed in 2 microseconds |
| Java app code | Cleared | Next query is sent within about 1 ms of each reply |
| **Database side** | **Found** | Every reply from port 5432 comes exactly 1.0 s late |

**Conclusion 2:** the app is **waiting for the database**. The slow part is on the Postgres side, not the app code and not the client network.

Be careful with your words. From the app Pod you cannot tell "PostgreSQL itself is slow" from "the path between the app and PostgreSQL is slow". Both look the same. The packets told us **where**. They did not tell us **why**.

### What you do next in a real incident

You hand the problem to the right place, with proof: "The app waits 1 s per query. The network to the app is clean." On the Postgres side you then check:

- Slow queries (slow query log, `pg_stat_statements`)
- Locks and waiting sessions (`pg_stat_activity`)
- CPU, memory and disk of the Postgres Pod and its node
- Packet loss, or a traffic delay set on the Pod's network interface (`tc qdisc show dev eth0`)

---

## Step 6: Fix the Incident and Verify

In this scenario, the last check in the list above is the cause: someone put a 1 second delay on the network of the database Pod. Now you know where to look.

**Why:** a fix is only real if the number goes back to normal.

```bash
curl -fsSL $LAB/scripts/fix.sh | bash
```

```
Fix applied. Checking the app...
Total time: 0.002878s
```

Send the request a few more times:

```bash
kubectl exec client -- curl -s -o /dev/null \
  -w "Total time: %{time_total}s\n" \
  http://staff-registry-app-svc/api/dashboard/status
```

```
Total time: 0.002916s
Total time: 0.002892s
Total time: 0.002857s
```

Back to about 3 ms. This confirms the delay on the database side was the cause.

| Moment | Request time |
|---|---|
| Incident | 3 to 4 s, every time |
| After the fix | about 0.003 s |

**Clean up** (one command):

```bash
curl -fsSL $LAB/scripts/cleanup.sh | bash
```

```
release "staff-registry" uninstalled
pod "client" deleted
Scenario removed.
```

---

## Summary: the method

1. **Measure first.** Get a "slow" number with `curl -w`.
2. **Check the cheap things.** Pods, restarts, logs.
3. **Split the time.** `time_connect` vs `time_starttransfer` tells you the delay is after the connection.
4. **One replica, one filter.** Capture on the right Pod, filter on your client IP.
5. **Start tcpdump before the request.**
6. **Use `-ttt` / `-tt`.** The time between packets is the whole point.
7. **Find the gap.** Request ACKed fast but answer late means the problem is behind the app.
8. **Follow the chain.** Capture the next hop (app to database) at the same time. Add up the waits.
9. **Do not over-claim.** Packets say where, not why.
10. **Fix and re-measure.** The number returning to normal is your proof.
