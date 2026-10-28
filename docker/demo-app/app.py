"""
Minimal Flask app instrumented with the OpenTelemetry SDK.

Emits:
  - traces:  one span per request (auto-instrumented) + a manual child span
             around the simulated "work" for /work / /error, marked as
             errored (with an exception event) when the request fails
  - metrics: request count/duration (auto-instrumented), plus explicit
             custom instruments used by the dashboards and alert rules in
             this repo (deliberately NOT relying on OTel semconv metric
             names, which vary across SDK/collector versions - these three
             are stable, hand-defined signals):
               - demo_app_work_requests_total   (counter)
               - demo_app_errors_total          (counter, by error_type)
               - demo_app_request_duration_seconds (histogram)
  - logs:    stdlib logging, bridged into OTel so log records carry the
             active trace_id/span_id (used for Grafana's trace->logs link
             and for the "high error log rate" Grafana alert rule)

All three signals go to the OTel Collector over OTLP (endpoint set via the
OTEL_EXPORTER_OTLP_ENDPOINT env var in docker-compose.yml / k8s manifests).

Endpoints:
    GET /             - service index with links to the available endpoints
  GET /healthz       - liveness/readiness probe target
  GET /work          - normal traffic. ~8% of calls fail (500) on their own
                       so the error-rate dashboards/alerts have something to
                       show without any manual action.
                       Add ?slow=1 to force a ~700-900ms response, useful for
                       manually tripping the HighLatencyP95 alert.
  GET /error         - always fails (500), useful for manually tripping the
                       HighErrorRate alert / ErrorLogSpike Grafana rule on
                       demand: `for i in $(seq 20); do curl -s :8000/error; done`
"""

import logging
import random
import time

from flask import Flask, jsonify, request
from opentelemetry import metrics, trace
from opentelemetry.instrumentation.flask import FlaskInstrumentor
from opentelemetry.instrumentation.logging import LoggingInstrumentor
from opentelemetry.trace import Status, StatusCode

LoggingInstrumentor().instrument(set_logging_format=True)
logging.basicConfig(level=logging.INFO)
log = logging.getLogger("demo-app")

app = Flask(__name__)
FlaskInstrumentor().instrument_app(app)

tracer = trace.get_tracer("demo-app")
meter = metrics.get_meter("demo-app")

work_counter = meter.create_counter(
    "demo_app_work_requests_total",
    description="Number of /work requests handled",
)
error_counter = meter.create_counter(
    "demo_app_errors_total",
    description="Number of requests that failed, by error_type",
)
duration_histogram = meter.create_histogram(
    "demo_app_request_duration_seconds",
    unit="s",
    description="Duration of simulated work, in seconds",
)


class SimulatedFailure(Exception):
    """Raised to simulate a downstream/business-logic failure."""


def _do_work(force_slow: bool, force_fail: bool):
    """Shared logic for /work and /error. Returns duration_ms on success,
    raises SimulatedFailure on (simulated) failure."""
    with tracer.start_as_current_span("simulate-work") as span:
        if force_slow:
            duration_ms = random.randint(700, 900)
        else:
            duration_ms = random.randint(20, 250)
        span.set_attribute("work.duration_ms", duration_ms)
        span.set_attribute("work.forced_slow", force_slow)
        time.sleep(duration_ms / 1000)
        duration_histogram.record(duration_ms / 1000)

        if force_fail or random.random() < 0.08:
            error_counter.add(1, {"error_type": "simulated_failure"})
            span.set_status(Status(StatusCode.ERROR, "simulated failure"))
            span.record_exception(SimulatedFailure("downstream dependency failed"))
            log.error(
                "simulated downstream failure while handling request",
                exc_info=False,
            )
            raise SimulatedFailure("downstream dependency failed")

        if duration_ms > 500:
            log.warning("slow response: %sms", duration_ms)

        return duration_ms


@app.route("/healthz")
def healthz():
    return jsonify(status="ok")


@app.route("/")
def index():
    return jsonify(
        service="demo-app",
        endpoints={
            "health": "/healthz",
            "work": "/work",
            "error": "/error",
        },
    )


@app.route("/work")
def work():
    work_counter.add(1)
    log.info("handling /work request")
    try:
        duration_ms = _do_work(force_slow=request.args.get("slow") == "1", force_fail=False)
    except SimulatedFailure as exc:
        return jsonify(status="error", detail=str(exc)), 500
    return jsonify(status="done", duration_ms=duration_ms)


@app.route("/error")
def error():
    work_counter.add(1)
    log.info("handling /error request (always fails)")
    try:
        _do_work(force_slow=False, force_fail=True)
    except SimulatedFailure as exc:
        return jsonify(status="error", detail=str(exc)), 500
    # Unreachable - _do_work always raises when force_fail=True - but keep a
    # sane fallback rather than an implicit None response.
    return jsonify(status="done"), 200


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8000)
