#!/bin/bash
# Applies the fix for the scenario.
# Usage: curl -fsSL $LAB/scripts/fix.sh | bash
kubectl get pod staff-registry-postgres-0 >/dev/null 2>&1 || { echo "ERROR: Pod staff-registry-postgres-0 not found."; exit 1; }

kubectl debug -i --quiet staff-registry-postgres-0 \
  --image=nicolaka/netshoot \
  --target=postgres \
  --profile=netadmin \
  -- tc qdisc del dev eth0 root </dev/null >/dev/null 2>&1

echo "Fix applied. Checking the app..."
kubectl exec client -- curl -s -o /dev/null -w "Total time: %{time_total}s\n" http://staff-registry-app-svc/api/dashboard/status
