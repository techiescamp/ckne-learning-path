#!/bin/bash
# Deletes everything the scenario created.
# Usage: curl -fsSL $LAB/scripts/cleanup.sh | bash
helm uninstall staff-registry 2>/dev/null || true
kubectl delete pod client --ignore-not-found
echo "Scenario removed."
