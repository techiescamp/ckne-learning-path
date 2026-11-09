#!/bin/bash
# Starts the Staff Registry troubleshooting scenario.
# Usage: curl -fsSL $LAB/scripts/setup.sh | bash
set -e

LAB="${LAB:-https://raw.githubusercontent.com/techiescamp/ckne/main/java-application-troubleshooting}"
URL="http://staff-registry-app-svc/api/dashboard/status"

echo "Cluster context: $(kubectl config current-context)"

helm upgrade --install staff-registry "$LAB/helm/staff-registry-1.0.0.tgz" --wait --timeout 5m

kubectl get pod client >/dev/null 2>&1 || kubectl run client --image=curlimages/curl --restart=Never -- sleep 86400
kubectl wait --for=condition=Ready pod/client --timeout=300s

echo "Waiting for the Java app to start (20 to 30 seconds)..."
for i in $(seq 1 100); do
  kubectl exec client -- curl -sf -o /dev/null "$URL" 2>/dev/null && break
  sleep 3
done

# Start the incident
OUT=$(kubectl debug -i --quiet staff-registry-postgres-0 \
  --image=nicolaka/netshoot \
  --target=postgres \
  --profile=netadmin \
  -- tc qdisc replace dev eth0 root netem delay 1000ms </dev/null 2>&1)
if echo "$OUT" | grep -qi "unknown\|No such file\|error"; then
  echo "ERROR: scenario setup failed:"; echo "$OUT"
  echo "If you see 'Specified qdisc kind is unknown', the node kernel has no netem module."
  exit 1
fi

# Self-check: the app must now be slow
t=$(kubectl exec client -- curl -s -o /dev/null -w '%{time_total}' "$URL")
awk -v t="$t" 'BEGIN{exit !(t+0 >= 2)}' || { echo "ERROR: scenario setup failed (the incident did not start)."; exit 1; }

echo
kubectl get pods -o wide
echo
echo "Scenario ready."
echo "Users report that the Staff Registry page is very slow. Find out why."
