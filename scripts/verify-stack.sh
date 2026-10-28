#!/usr/bin/env bash
# Smoke test: waits for every pod in the observability namespace to be
# Ready, then port-forwards the demo app and asserts /healthz and /work
# both return 200. This is what actually proves the signal path works,
# not just that pods started - if the OTel Collector config or a Helm
# values file is wrong, pods can still be "Running" while the app can't
# reach the collector, so this is a deliberately weak proxy for that too:
# it does NOT assert data landed in Prometheus/Loki/Tempo (see the README
# troubleshooting section for how to check that manually / extend this
# script to query each backend's API directly).

set -euo pipefail

NAMESPACE="observability"
TIMEOUT=180

echo "==> Waiting for all pods in $NAMESPACE to be Ready (timeout ${TIMEOUT}s)"
if ! kubectl wait --for=condition=Ready pod --all -n "$NAMESPACE" --timeout="${TIMEOUT}s"; then
  echo "!! Some pods never became Ready. Dumping state for debugging:"
  kubectl get pods -n "$NAMESPACE" -o wide
  kubectl describe pods -n "$NAMESPACE"
  exit 1
fi

echo "==> Port-forwarding demo-app"
kubectl port-forward -n "$NAMESPACE" svc/demo-app 8000:8000 >/tmp/port-forward.log 2>&1 &
PF_PID=$!
trap 'kill $PF_PID 2>/dev/null || true' EXIT
sleep 3

echo "==> Checking /healthz"
curl --fail --silent --show-error http://localhost:8000/healthz

echo "==> Generating a few requests against /work"
for _ in $(seq 1 5); do
  curl --fail --silent --show-error http://localhost:8000/work >/dev/null
done

echo "==> Confirming /error responds 500 as designed (feeds the error-rate dashboards/alerts)"
status=$(curl --silent --output /dev/null --write-out "%{http_code}" http://localhost:8000/error)
if [ "$status" != "500" ]; then
  echo "!! Expected /error to return 500, got $status"
  exit 1
fi

echo "==> Smoke test passed: demo-app is reachable, serving requests, and its error path works."
