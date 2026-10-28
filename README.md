# DevOps Observability Stack — Prometheus, Grafana, Loki, Tempo, OpenTelemetry

An exact, end-to-end plan and working scaffold for a metrics + logs + traces observability stack, runnable two ways:

1. **Local dev** — Docker Compose (fast inner-loop, no cluster needed).
2. **Kubernetes** — a local [minikube](https://minikube.sigs.k8s.io/) cluster (the one you already have installed and running), installed via Helm, fully automated by **GitHub Actions** on every push (build → spin up an ephemeral minikube in the runner → deploy stack → smoke-test).

This is a "signals in, dashboards out, alerts to Slack" reference stack: a demo app is instrumented with the OpenTelemetry SDK, ships metrics/traces/logs to an OpenTelemetry Collector, which fans them out to Prometheus (metrics), Tempo (traces), and Loki (logs) — all visualized and cross-linked in Grafana across five dashboards, with two independent alerting paths (Prometheus/Alertmanager and Grafana-native) both posting to Slack.

## 1. Architecture

```
                         ┌─────────────────────────────┐
                         │        Demo App (Flask)      │
                         │  OTel SDK: metrics/traces/logs│
                         └───────────────┬──────────────┘
                                         │ OTLP gRPC :4317 / HTTP :4318
                                         ▼
                         ┌─────────────────────────────┐
                         │   OpenTelemetry Collector    │
                         │ receivers: otlp              │
                         │ processors: batch, resource  │
                         │ exporters: prometheus, otlp,  │
                         │            loki               │
                         └───┬──────────┬───────────┬───┘
                             │          │           │
                     scrape  │   traces │     logs  │
                             ▼          ▼           ▼
                       ┌──────────┐ ┌────────┐  ┌────────┐
                  ┌───▶│Prometheus│ │ Tempo  │  │  Loki  │
                  │    └────┬─────┘ └───┬────┘  └───┬────┘
      remote_write│         │           │           │
   (span/service   │        │    ┌──────┘           │
    graph metrics) └────────┤    │ metrics-generator │
                             │    │ (service-graphs,  │
                             │    │  span-metrics)    │
                             │    └───────────────────┘
                             │           │           │
                             └─────┬─────┴─────┬─────┘
                                  ▼            
                            ┌───────────┐          ┌──────────────┐
                            │  Grafana  │          │ Alertmanager │
                            │ 5 dashboards,         │ (Prometheus  │
                            │ trace<->log<->metric  │  alerts)     │
                            │ correlation, + its own│              │
                            │ Loki-based alert rule └──────┬───────┘
                            └───────────┬───────────       │
                                        │                   │
                                        ▼                   ▼
                                     Slack              Slack
                              (#observability-alerts, two independent paths)
```

Signal flow, exactly:

- **Metrics**: app → OTel SDK → OTel Collector (OTLP) → Collector exposes a `/metrics` endpoint → Prometheus scrapes it (pull model). Prometheus also scrapes its own targets, node/cAdvisor style exporters, and the Collector's own internal telemetry.
- **Traces**: app → OTel SDK → OTel Collector (OTLP) → Collector exports via `otlp` exporter to Tempo's OTLP receiver (push model).
- **Trace-derived metrics** (the correlation layer): Tempo's metrics-generator turns every ingested trace into span-latency and service-graph metrics, and `remote_write`s them straight into Prometheus — so a Prometheus alert or Grafana panel can key off trace data without any extra app instrumentation. See §9 "Correlation".
- **Logs**: app → OTel SDK log bridge (or container stdout, scraped by Promtail in Compose / Loki's Kubernetes-native scraping via the Loki Helm chart in K8s) → Loki.
- **Grafana**: one Grafana instance, three datasources (Prometheus, Loki, Tempo) with fixed UIDs, provisioned as code so dashboards and alert rules work on first boot with no manual clicking, plus trace-to-logs, trace-to-metrics, and metric-to-trace (exemplar) correlation enabled.
- **Alerting**: two independent engines, deliberately - Alertmanager handles every Prometheus-metric-based alert (including the trace-derived ones), Grafana's own alerting engine handles the one alert that needs to query Loki directly (log volume), since Alertmanager can't query Loki. Both post to Slack. See §8 "Alerting".

## 2. Repository layout

```
observability-stack/
├── README.md                          # this file — the exact plan
├── docker/                            # Phase 1: local dev via Docker Compose
│   ├── docker-compose.yml
│   ├── prometheus/
│   │   ├── prometheus.yml
│   │   └── alert-rules.yml            # Prometheus alert rules -> Alertmanager
│   ├── alertmanager/
│   │   ├── alertmanager.yml           # routes alerts to Slack
│   │   └── secrets/slack_url.example  # real slack_url file is gitignored
│   ├── otel-collector/otel-collector-config.yaml
│   ├── loki/loki-config.yaml
│   ├── tempo/tempo.yaml               # + metrics-generator (service-graphs, span-metrics)
│   ├── promtail/promtail-config.yaml
│   ├── demo-app/ (Dockerfile, app.py, requirements.txt)
│   └── grafana/provisioning/
│       ├── datasources/datasources.yaml
│       ├── dashboards/
│       │   ├── dashboards.yaml
│       │   └── json/                  # 5 dashboards, see §7 "Dashboards"
│       │       ├── otel-collector-overview.json
│       │       ├── demo-app-golden-signals.json
│       │       ├── otel-collector-health.json
│       │       ├── traces-service-graph.json
│       │       └── logs-overview.json
│       └── alerting/
│           ├── contactpoints.yaml.example  # real file is gitignored
│           ├── policies.yaml
│           └── rules.yaml             # the one Loki-based alert rule
├── k8s/                                # Phase 2: Kubernetes via minikube + Helm
│   ├── namespace.yaml
│   ├── prometheus-rules.yaml           # PrometheusRule CR, same rules as Compose
│   ├── grafana-dashboards/             # ConfigMaps wrapping the same 5 dashboards
│   ├── helm-values/
│   │   ├── kube-prometheus-stack-values.yaml  # + Alertmanager Slack config
│   │   ├── loki-values.yaml
│   │   ├── tempo-values.yaml           # + metrics-generator (best-effort, see file)
│   │   └── otel-collector-values.yaml
│   └── demo-app/ (deployment.yaml, service.yaml)
├── .github/workflows/                  # Phase 3: CI/CD
│   ├── ci-build.yml                    # build & push demo-app image
│   └── deploy-observability.yml        # minikube cluster + helm install + smoke test
└── scripts/
    ├── setup-minikube-cluster.sh       # + Slack secret + PrometheusRule + dashboards
    └── verify-stack.sh
```

## 3. Exact component versions (pin these — verify before `helm install` since charts move fast)

| Component | Delivery | Version pinned in this repo | Source |
|---|---|---|---|
| Prometheus | Docker image (Compose) | `prom/prometheus:v3.14.0` | github.com/prometheus/prometheus |
| kube-prometheus-stack | Helm chart (K8s) | `91.5.2` | prometheus-community/helm-charts |
| Grafana | Docker image (Compose) | `grafana/grafana:11.3.0` | hub.docker.com/r/grafana/grafana |
| Loki | Docker image (Compose) | `grafana/loki:3.3.0` | grafana/loki |
| Loki | Helm chart (K8s) | `7.3.0` | grafana/helm-charts |
| Tempo | Docker image (Compose) | `grafana/tempo:2.6.0` | grafana/tempo |
| Tempo | Helm chart (K8s), monolithic mode | `1.24.4` (`grafana/tempo`) | grafana/helm-charts |
| OTel Collector Contrib | Docker image (Compose) | `otel/opentelemetry-collector-contrib:0.113.0` | hub.docker.com |
| OTel Collector | Helm chart (K8s) | `0.173.1` | open-telemetry/opentelemetry-helm-charts |
| Promtail | Docker image (Compose only) | `grafana/promtail:3.3.0` | grafana/loki |
| Alertmanager | Docker image (Compose) | `prom/alertmanager:v0.34.0` | github.com/prometheus/alertmanager |
| Alertmanager | Bundled in kube-prometheus-stack (K8s) | pinned by chart `91.5.2` | prometheus-community/helm-charts |
| minikube | Local CLI (already installed on your machine) | `v1.38.0`+ (whatever you have running) | github.com/kubernetes/minikube |
| minikube (CI only) | GitHub Actions | `medyagh/setup-minikube@v0.0.21`, `minikube-version: v1.38.0`, `kubernetes-version: v1.31.0` | github.com/medyagh/setup-minikube |

**Before you run this for real**: chart and image versions move every few weeks. Run `helm search repo <name> --versions` and check Docker Hub tags right before you deploy, and bump the pins in this table and in the values files below.

## 4. Phase 1 — Local dev with Docker Compose (do this first)

Goal: prove every signal path — including alerts to Slack — works on your laptop before touching Kubernetes.

1. Set up the two Slack integrations first (five minutes, one-time): see §8 "Alerting" below for how to create a Slack Incoming Webhook, then:
   ```
   cp docker/alertmanager/secrets/slack_url.example docker/alertmanager/secrets/slack_url
   # edit that file - it must contain ONLY the webhook URL, nothing else
   cp docker/grafana/provisioning/alerting/contactpoints.yaml.example docker/grafana/provisioning/alerting/contactpoints.yaml
   # edit the `url:` field inside it
   ```
   If you skip this, the stack still comes up fine — Alertmanager/Grafana just won't be able to reach Slack until you fill these in (Grafana will log a provisioning error for the alerting rule/policy referencing the missing contact point; harmless, fix it whenever you're ready to test alerting).
2. `cd docker`
3. `docker compose up -d --build`
4. Generate traffic against the demo app so it emits telemetry: `curl http://localhost:8000/work` a few times (or `for i in $(seq 20); do curl -s http://localhost:8000/work >/dev/null; done`). ~8% of `/work` calls fail on their own by design, so the error-rate panels/alerts have something to show without any manual action.
5. Open Grafana at `http://localhost:3000` (default login `admin` / `admin`, forced change on first login — this is dev-only, never reuse in production).
6. Confirm all three datasources exist under Connections → Data sources (Prometheus, Loki, Tempo) — they are provisioned automatically from `docker/grafana/provisioning/`, no manual setup.
7. Open the five dashboards under Dashboards → "Observability Stack" folder — see §7 for what each one shows.
8. Explore tab: query `{service_name="demo-app"}` against Loki to see logs, run a PromQL query like `http_server_duration_milliseconds_count` against Prometheus, and search Tempo by service name `demo-app` to pull a trace. Click a trace span's "Logs for this span" link to confirm the trace→log correlation works.
9. Trip an alert on demand: `for i in $(seq 20); do curl -s http://localhost:8000/error >/dev/null; done` pushes the error rate over both the 20% and 50% thresholds within a couple of minutes — watch it arrive in Slack (see §8 for exactly what fires and when).
10. `docker compose down -v` to tear down.

## 5. Phase 2 — Kubernetes via minikube + Helm

Goal: the same stack, deployed the way it would be on a real cluster, using the minikube you already have installed and running locally.

1. Prerequisites: `minikube`, `kubectl`, `helm` (you already have all three, and minikube is already running — nothing to install or start).
2. Point kubectl at it: `kubectl config use-context minikube`. (If it's ever stopped, `minikube start` brings it back with the same profile/driver you already configured — this repo never assumes a specific driver.)
3. Create the namespace: `kubectl apply -f k8s/namespace.yaml`.
4. Create the Alertmanager Slack secret (see §8 for how to get a webhook URL):
   ```
   export SLACK_WEBHOOK_URL="https://hooks.slack.com/services/..."
   kubectl create secret generic alertmanager-slack-webhook \
     --namespace observability \
     --from-literal=slack_url="$SLACK_WEBHOOK_URL"
   ```
   Skip this and the stack still deploys — Alertmanager's Secret mount just has a placeholder URL and posts nowhere until you create the real one (re-run the command above any time; `kubectl create secret` fails if it already exists, use `--dry-run=client -o yaml | kubectl apply -f -` to update it, which is exactly what `scripts/setup-minikube-cluster.sh` does automatically).
5. Add Helm repos:
   ```
   helm repo add prometheus-community https://prometheus-community.github.io/helm-charts
   helm repo add grafana https://grafana.github.io/helm-charts
   helm repo add open-telemetry https://open-telemetry.github.io/opentelemetry-helm-charts
   helm repo update
   ```
6. Install kube-prometheus-stack (this brings Prometheus, Alertmanager pre-wired to Slack, and a Grafana instance with all three datasources pre-wired):
   ```
   helm install kube-prometheus-stack prometheus-community/kube-prometheus-stack \
     --namespace observability --version 91.5.2 \
     -f k8s/helm-values/kube-prometheus-stack-values.yaml
   ```
7. Install Loki (single-binary mode, filesystem storage — fine for a dev/demo cluster):
   ```
   helm install loki grafana/loki \
     --namespace observability --version 7.3.0 \
     -f k8s/helm-values/loki-values.yaml
   ```
8. Install Tempo (monolithic mode, with the metrics-generator enabled):
   ```
   helm install tempo grafana/tempo \
     --namespace observability --version 1.24.4 \
     -f k8s/helm-values/tempo-values.yaml
   ```
9. Install the OpenTelemetry Collector (deployment mode, receives OTLP from apps, fans out to Prometheus/Loki/Tempo):
   ```
   helm install otel-collector open-telemetry/opentelemetry-collector \
     --namespace observability --version 0.173.1 \
     -f k8s/helm-values/otel-collector-values.yaml
   ```
10. Apply the alert rules and the extra dashboards:
    ```
    kubectl apply -f k8s/prometheus-rules.yaml
    kubectl apply -f k8s/grafana-dashboards/
    ```
11. Deploy the demo app: `kubectl apply -f k8s/demo-app/`.
    - The manifest pulls `ghcr.io/OWNER/REPO-demo-app:latest` from the registry (see Phase 3). If you'd rather iterate locally without pushing to GHCR every time, either run `eval $(minikube docker-env)` before `docker build` so the image lands directly in minikube's own Docker daemon, or build normally and run `minikube image load <your-tag>` to copy it in — then point `k8s/demo-app/deployment.yaml`'s `image:` at that local tag with `imagePullPolicy: IfNotPresent`.
12. Verify: `kubectl get pods -n observability` — everything should reach `Running`/`1/1`. Then either `kubectl port-forward -n observability svc/kube-prometheus-stack-grafana 3000:80`, or `minikube service kube-prometheus-stack-grafana -n observability` to have minikube open it in a browser directly, and confirm Grafana the same way as Phase 1 (all five dashboards should already be under Dashboards, since step 10 applied the ConfigMaps the Grafana sidecar auto-discovers).
13. Nothing to tear down — this is your persistent local minikube, not an ephemeral cluster. To remove just this stack: `helm uninstall kube-prometheus-stack loki tempo otel-collector -n observability && kubectl delete namespace observability`. Only run `minikube delete` if you want to wipe minikube itself (this affects anything else you run on it too).

`scripts/setup-minikube-cluster.sh` and `scripts/verify-stack.sh` automate steps 2–12 (safely — the setup script only calls `minikube start` if it finds minikube *not* already running, it never touches an existing cluster otherwise) and are the exact scripts GitHub Actions calls in Phase 3, against its own separate, ephemeral CI minikube.

## 6. Phase 3 — GitHub Actions CI/CD

Two workflows, deliberately separate:

### `ci-build.yml` — runs on every push/PR touching `docker/demo-app/**`
1. Checkout.
2. `docker/build-push-action` builds the demo app image.
3. Trivy scan of the built image (fail the build on HIGH/CRITICAL — swap or drop this step if you don't have a scanner set up yet).
4. Push to GHCR (`ghcr.io/<owner>/<repo>-demo-app:<sha>`), authenticated with the built-in `GITHUB_TOKEN` — no extra secrets needed for GHCR.

### `deploy-observability.yml` — runs on every push to `main` (and manually via `workflow_dispatch`)
1. Checkout.
2. `medyagh/setup-minikube` spins up an ephemeral minikube **inside the runner** — this is a *different* minikube from the one running on your laptop; a GitHub-hosted runner cannot reach your local machine, so CI always builds and tests against its own throwaway cluster.
3. Add the three Helm repos and `helm repo update`.
4. `helm install`/`helm upgrade --install` the four releases (kube-prometheus-stack, loki, tempo, otel-collector) using the pinned chart versions and the values files in `k8s/helm-values/`, waiting on each (`--wait --timeout 5m`).
5. Apply `k8s/demo-app/`.
6. Run `scripts/verify-stack.sh`, which polls `kubectl get pods -n observability` until everything is `Running`, then curls the demo app through a port-forward and asserts a 200 response — this is the smoke test that proves the whole signal path (app → collector → all three backends) actually works, not just that pods started.
7. On failure, dump `kubectl describe`/`kubectl logs` for every pod in the namespace as a build artifact, so a broken CI run is debuggable without re-running it locally.
8. Because this targets an ephemeral **CI-only minikube** created fresh inside the same job, there is nothing to tear down — the runner is destroyed at the end of the job. **This is a validation pipeline, proving the manifests/values deploy cleanly — it is not, by itself, deploying to a persistent environment, and it does not touch the minikube on your own machine.** See §10 for what changes when you point this at a real cluster.

Both workflows are provided below with exact, pinned action versions.

## 7. Dashboards

Five dashboards, all under the "Observability Stack" folder in Grafana, provisioned as code (`docker/grafana/provisioning/dashboards/json/`, mirrored into Kubernetes as ConfigMaps under `k8s/grafana-dashboards/`):

1. **Observability Stack Overview** (`otel-collector-overview.json`) — the original quick-look dashboard: `/work` request rate, accepted spans, and a raw demo-app logs panel. Good as a single "is anything moving" check.
2. **demo-app - Golden Signals (RED)** (`demo-app-golden-signals.json`) — Rate/Errors/Duration: request rate, error rate % with red/orange/green thresholds, errors broken out by `error_type`, p50/p95/p99 latency, plus four stat tiles (current error rate, current p95, total requests/errors in 24h). This is the dashboard to have open while `HighErrorRate`/`HighLatencyP95` are firing.
3. **OTel Collector - Health** (`otel-collector-health.json`) — pipeline health rather than app health: accepted vs. refused spans/metric points/log records per signal, export failures per signal (should be a flat zero line), and average batch size from the batch processor. This is what you check first if data looks like it's simply not arriving anywhere.
4. **Traces - Service Graph & Span Metrics** (`traces-service-graph.json`) — the correlation dashboard: request rate and failure rate by service-to-service edge, and p95 latency / call volume by service+operation, all sourced from Tempo's metrics-generator output (`traces_service_graph_request_total`, `traces_spanmetrics_latency_bucket`, `traces_spanmetrics_calls_total`) rather than from any app-level metric. For the interactive graphical node graph (boxes and arrows, not just numbers), use Grafana's Explore view against the Tempo datasource → Service Graph tab, which reads the same underlying data.
5. **Logs Overview** (`logs-overview.json`) — total log lines/sec and ERROR-lines/sec for demo-app, an error-only log panel (click a line → "TraceID" derived field → jumps straight to that trace in Tempo), and a raw all-logs panel.

## 8. Alerting (Slack)

Two independent alerting engines are wired up here, on purpose — they cover different data and there's no single engine in this stack that can query all three signal types:

| Engine | Evaluates | Alert rules live in | Notifies |
|---|---|---|---|
| **Alertmanager** (Compose: standalone; K8s: bundled in kube-prometheus-stack) | Prometheus metrics only (including Tempo's trace-derived metrics, since those land in Prometheus too — see §9) | `docker/prometheus/alert-rules.yml` / `k8s/prometheus-rules.yaml` | `#observability-alerts` (warning) and `#observability-alerts-critical` (critical), via two Slack receivers |
| **Grafana-native alerting** | Anything Grafana can query, including Loki directly — this is the only way to alert on raw log volume in this stack, since neither Prometheus nor Alertmanager can see log data | `docker/grafana/provisioning/alerting/rules.yaml` (Compose only — see note below) | `#observability-alerts` via its own Slack contact point |

### Creating a Slack Incoming Webhook (needed for both engines — can be the same one or two different ones)
1. Go to https://api.slack.com/apps → **Create New App** → **From scratch**, give it a name, pick your workspace.
2. Left sidebar → **Incoming Webhooks** → toggle **Activate Incoming Webhooks** on → **Add New Webhook to Workspace** → pick a channel (e.g. `#observability-alerts`) → **Allow**.
3. Copy the generated URL — looks like `https://hooks.slack.com/services/T000/B000/XXXXXXXXXXXXXXXXXXXXXXXX`. Repeat for a second channel if you want warning/critical or Alertmanager/Grafana alerts visually separated.

### Wiring it in (Compose)
- Alertmanager: `cp docker/alertmanager/secrets/slack_url.example docker/alertmanager/secrets/slack_url`, then replace the placeholder — **that file must contain only the URL**, Alertmanager reads the whole file as the secret, no YAML/comments.
- Grafana: `cp docker/grafana/provisioning/alerting/contactpoints.yaml.example docker/grafana/provisioning/alerting/contactpoints.yaml`, then edit the `url:` field inside (this one's a normal YAML file, comments are fine).
- Both files are gitignored so the real webhook never gets committed.

### Wiring it in (Kubernetes)
- Alertmanager only — there's no separate Grafana-native alert rule shipped for K8s (see note below): create the secret as shown in Phase 2 step 4 (`kubectl create secret generic alertmanager-slack-webhook --from-literal=slack_url=...`), or export `SLACK_WEBHOOK_URL` before running `scripts/setup-minikube-cluster.sh`, which creates/updates it for you. In CI, set a repository secret named `SLACK_WEBHOOK_URL` and `deploy-observability.yml` passes it through automatically (optional — the ephemeral CI cluster deploys fine without it).

> **Note on the Grafana-native rule and Kubernetes**: `docker/grafana/provisioning/alerting/rules.yaml`/`policies.yaml`/`contactpoints.yaml.example` are Compose-only in this repo — kube-prometheus-stack's bundled Grafana provisions alerting differently (via its own sidecar/ConfigMap mechanism, not a bind-mounted `provisioning/` folder), so porting the Loki-based `ErrorLogSpike` rule to K8s needs an extra ConfigMap wired through `grafana.sidecar.alerts` in the Helm values, which isn't included here. The Prometheus/Alertmanager-based alerts (the ones that matter most) are fully wired on both platforms via `k8s/prometheus-rules.yaml`.

### What fires, and how to trigger each one on demand
| Alert | Engine | Fires when | Trigger it manually with |
|---|---|---|---|
| `DemoAppNotReporting` | Alertmanager | No `demo_app_work_requests_total` samples for 10m | Stop the demo-app container/pod |
| `HighErrorRate` / `HighErrorRateCritical` | Alertmanager | >20% / >50% of requests fail over 5m | `for i in $(seq 20); do curl -s http://localhost:8000/error; done` |
| `HighLatencyP95` | Alertmanager | p95 latency >500ms for 5m | `for i in $(seq 20); do curl -s 'http://localhost:8000/work?slow=1'; done` |
| `OtelCollectorDown` / `OtelCollectorExportFailures` | Alertmanager | Collector unreachable, or accepting but failing to export | Stop the collector container, or point an exporter at a wrong port |
| `HighServiceGraphErrorRate` | Alertmanager | Same as HighErrorRate, but computed purely from Tempo's trace-derived metrics — fires alongside HighErrorRate as a cross-check (see §9) | Same as HighErrorRate |
| `ErrorLogSpike` | Grafana-native (Compose only) | >5 ERROR-level log lines from demo-app in 5m | Same as HighErrorRate |

Alertmanager's `inhibit_rules` suppress `HighErrorRate` while `HighErrorRateCritical` is already firing for the same service, so you get one Slack message, not two, for the same underlying spike.

## 9. Correlation

The point of running all three signal types together instead of three separate tools: every panel and alert above can be traced back to the others.

- **Trace → Logs**: Loki's datasource config includes a `derivedFields` regex that pulls `trace_id=<...>` out of each log line (the OTel logging bridge in `app.py` stamps every log record with the active trace ID) and turns it into a clickable link back to that trace in Tempo.
- **Trace → Metrics / Logs → Trace**: Tempo's datasource config sets `tracesToLogsV2` (jump from a span to its logs) and `tracesToMetrics` (jump from a span to related metrics); the Loki panel in the Logs Overview dashboard uses the same derived field to jump the other way, log → trace.
- **Metric → Trace (exemplars)**: Prometheus runs with `--enable-feature=exemplar-storage`, and its datasource config sets `exemplarTraceIdDestinations`, so a metric sample recorded while a trace was active can carry that trace's ID as an exemplar — shown as a small diamond on a graph that links straight to the trace. Whether a given sample actually has one depends on the OTel SDK's exemplar filter default for your SDK version; if you don't see exemplar diamonds on the latency panel, this is the first thing to check, not a sign the wiring is broken.
- **Traces → Metrics → Alerts (the big one)**: Tempo's metrics-generator (`docker/tempo/tempo.yaml` / `k8s/helm-values/tempo-values.yaml`) turns every ingested trace into `service-graphs` and `span-metrics` output and `remote_write`s it directly into Prometheus. This means Prometheus alert rules and Grafana panels can be written purely in PromQL against trace-derived data (`traces_service_graph_request_total`, `traces_spanmetrics_latency_bucket`) with zero extra app instrumentation — see the "Traces - Service Graph & Span Metrics" dashboard and the `HighServiceGraphErrorRate` alert, which is deliberately the same underlying signal as `HighErrorRate` computed a completely different way. When both fire together, that's strong confirmation it's a real regression rather than a bug in one signal's instrumentation.
- **Logs → Alerts**: the one place metrics/traces can't reach — Grafana's native alerting queries Loki directly for the `ErrorLogSpike` rule, since neither Prometheus nor Alertmanager can see log data at all.

## 10. Moving from this local/CI setup to a real persistent cluster (EKS/GKE/AKS/on-prem)

This scaffold intentionally targets `minikube` — locally because you already have it running, and in CI as a free, self-contained ephemeral cluster inside the runner. To point it at a real cluster instead:

- Replace the `medyagh/setup-minikube` step in `deploy-observability.yml` with a cloud auth step (`aws-actions/configure-aws-credentials` for EKS, `google-github-actions/auth` + `get-gke-credentials` for GKE, `azure/login` + `aks-set-context` for AKS) and drop the "Start minikube" step entirely — everything after `helm repo update` stays identical.
- Switch storage: Loki and Tempo values files here use `filesystem`/`emptyDir`-backed storage for zero-dependency local dev. For a real cluster, change `storage.type` to `s3` (or GCS/Azure Blob) in both values files and point at a real bucket + credentials (via a Kubernetes `Secret`, referenced from the values file — never hardcode keys in the YAML).
- Add persistent volumes: set `prometheus.prometheusSpec.storageSpec` in the kube-prometheus-stack values to a `PersistentVolumeClaim` backed by your cluster's real StorageClass (minikube's default `standard` class, from its `storage-provisioner` addon, is node-local storage on your machine — fine for local dev, not for production retention or anything that needs to survive `minikube delete`).
- Add an Ingress + TLS in front of Grafana (and lock down Prometheus/Loki/Tempo so they're cluster-internal only) instead of `kubectl port-forward`.
- Turn `helm install` into `helm upgrade --install` with a real GitHub Environment (with required reviewers) gating the job, so deploys to production need manual approval.
- Alerting is already wired to Slack (§8) — for production, also add a PagerDuty/Opsgenie receiver for the critical route in `kube-prometheus-stack-values.yaml`'s `alertmanager.config.receivers`, and get the Slack webhook and any PagerDuty routing key from a real secrets manager (Vault, AWS Secrets Manager, External Secrets Operator) instead of `kubectl create secret --from-literal`.

## 11. Troubleshooting checklist

- **Grafana shows a datasource but queries return nothing**: check the OTel Collector logs (`kubectl logs -n observability deploy/otel-collector-opentelemetry-collector` or `docker compose logs otel-collector`) — almost always a receiver/exporter mismatch (wrong endpoint, wrong port) between the app, the Collector config, and the backend.
- **App can't reach the Collector**: in Compose, the app must point at `http://otel-collector:4317` (service name, not `localhost`). In K8s, use the Collector's Service DNS name (`otel-collector-opentelemetry-collector.observability.svc.cluster.local:4317`).
- **Loki rejects logs ("entry too far behind")**: clock skew or you're replaying old logs after a restart — bump `limits_config.reject_old_samples_max_age` in `loki-config.yaml` for a dev box, never in production.
- **Tempo shows no traces**: confirm the Collector's `otlp` exporter endpoint matches Tempo's OTLP receiver port (`4317` gRPC) and that the app is actually sampling/exporting spans (check `OTEL_TRACES_SAMPLER` isn't set to `always_off`).
- **minikube fails to come up in CI**: almost always a resource limit on the GitHub-hosted runner — reduce replica counts / resource requests in the values files for CI use (already done in this repo's values files, see `resources:` blocks).
- **Works in CI but the demo app can't reach anything on your local minikube**: check `kubectl config current-context` is actually `minikube` and not left pointed at a leftover context from something else, and confirm `minikube status` shows `Running` before re-running `scripts/setup-minikube-cluster.sh`.
- **No Slack message despite an alert clearly firing**: check Alertmanager's own UI (`docker compose exec` port `9093`, or `kubectl port-forward svc/kube-prometheus-stack-alertmanager 9093:9093`) to confirm the alert reached Alertmanager at all — if it's there but nothing arrived in Slack, the webhook file/secret almost certainly still has the placeholder URL, or has extra whitespace/comments in it (the Compose `slack_url` file must contain *only* the URL).
- **Grafana logs a provisioning error mentioning a missing contact point on startup**: `contactpoints.yaml` doesn't exist yet — `docker/grafana/provisioning/alerting/rules.yaml` and `policies.yaml` reference it by name. Copy the `.example` file and fill in a real (or even placeholder) URL; Grafana picks up provisioning changes without a restart.
- **`traces_service_graph_request_total` / `traces_spanmetrics_*` never appear in Prometheus**: confirm Tempo actually has `metrics_generator.storage.remote_write` pointed at a *reachable* Prometheus URL with `--web.enable-remote-write-receiver` set (Compose) or `prometheus.prometheusSpec.enableRemoteWriteReceiver: true` (K8s) — `docker compose logs tempo` / `kubectl logs -n observability sts/tempo` will show remote-write errors if the receiver flag is missing on the Prometheus side.
