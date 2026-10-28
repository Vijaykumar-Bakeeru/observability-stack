#!/usr/bin/env bash
# Starts minikube (if it isn't already running) and installs the full
# observability stack via Helm. Used both locally and by
# .github/workflows/deploy-observability.yml.
#
# Locally: if you already have minikube running (the common case), this
# script leaves it exactly as-is and just points kubectl at it - it never
# stops/deletes an existing cluster.
# In CI: medyagh/setup-minikube has already started a fresh ephemeral
# minikube inside the runner before this script runs, so the "start"
# branch below is what actually fires there.

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NAMESPACE="observability"

echo "==> Checking minikube status"
if minikube status >/dev/null 2>&1; then
  echo "    minikube is already running - reusing it."
else
  echo "    minikube is not running - starting it (default driver/profile)."
  minikube start
fi

kubectl config use-context minikube

echo "==> Creating namespace"
kubectl apply -f "$REPO_ROOT/k8s/namespace.yaml"

echo "==> Creating/updating Alertmanager Slack webhook secret"
# SLACK_WEBHOOK_URL is read from the environment so the real URL is never
# written to a file in this repo. Falls back to an obvious placeholder so
# the stack still deploys cleanly (Alertmanager just won't be able to reach
# Slack) if you haven't set one up yet - see README "Alerting" section.
SLACK_WEBHOOK_URL="SLACK_WEBHOOK_URL="${SLACK_WEBHOOK_URL:?Set the webhook URL first}"
kubectl create secret generic alertmanager-slack-webhook \
  --namespace "$NAMESPACE" \
  --from-literal=slack_url="$SLACK_WEBHOOK_URL" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Adding Helm repos"
helm repo add prometheus-community https://prometheus-community.github.io/helm-charts >/dev/null
helm repo add grafana https://grafana.github.io/helm-charts >/dev/null
helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts >/dev/null
helm repo update >/dev/null

echo "==> Installing kube-prometheus-stack (Prometheus + Grafana + Alertmanager)"
helm upgrade --install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
  --namespace "$NAMESPACE" --version 91.5.2 \
  -f "$REPO_ROOT/k8s/helm-values/kube-prometheus-stack-values.yaml" \
  --wait --timeout 5m

echo "==> Installing Loki"
helm upgrade --install loki grafana/loki \
  --namespace "$NAMESPACE" --version 7.3.0 \
  -f "$REPO_ROOT/k8s/helm-values/loki-values.yaml" \
  --wait --timeout 5m

echo "==> Installing Tempo"
helm upgrade --install tempo grafana/tempo \
  --namespace "$NAMESPACE" --version 1.24.4 \
  -f "$REPO_ROOT/k8s/helm-values/tempo-values.yaml" \
  --wait --timeout 5m

echo "==> Installing OpenTelemetry Collector"
helm upgrade --install otel-collector open-telemetry/opentelemetry-collector \
  --namespace "$NAMESPACE" --version 0.173.1 \
  -f "$REPO_ROOT/k8s/helm-values/otel-collector-values.yaml" \
  --wait --timeout 5m

echo "==> Applying alert rules (PrometheusRule)"
kubectl apply -f "$REPO_ROOT/k8s/prometheus-rules.yaml"

echo "==> Applying extra Grafana dashboards (ConfigMaps, auto-discovered by the Grafana sidecar)"
kubectl apply -f "$REPO_ROOT/k8s/grafana-dashboards/"

echo "==> Deploying demo app"
kubectl apply -f "$REPO_ROOT/k8s/demo-app/"
kubectl rollout status deployment/demo-app -n "$NAMESPACE" --timeout=120s

echo "==> Stack installed. Pods:"
kubectl get pods -n "$NAMESPACE"