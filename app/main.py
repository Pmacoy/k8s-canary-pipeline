"""
A deliberately tiny app whose only job is to be a good canary subject: it
reports its own version and health, and exposes Prometheus metrics that an
Argo Rollouts AnalysisTemplate can query to decide, automatically, whether a
canary revision is behaving well enough to keep receiving traffic.

FAIL_RATE (0.0-1.0, default 0) is the whole point of this file: bump it in a
"bad" version's Deployment to simulate a regression, and the rollout's
automated analysis (success-rate query against error_total/request_total)
will catch it and abort the rollout on its own -- no human watching a
dashboard required. That's the thing this repo exists to demonstrate.
"""
import os
import random
import socket
import time

from flask import Flask, Response, jsonify
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

app = Flask(__name__)

APP_VERSION = os.environ.get("APP_VERSION", "v1")
FAIL_RATE = float(os.environ.get("FAIL_RATE", "0"))
HOSTNAME = socket.gethostname()

REQUEST_COUNT = Counter(
    "shrtn_requests_total",
    "Total HTTP requests handled by this pod",
    ["path", "status", "version"],
)
REQUEST_LATENCY = Histogram(
    "shrtn_request_duration_seconds",
    "Request latency in seconds",
    ["path", "version"],
)


@app.before_request
def _start_timer():
    from flask import g

    g.start_time = time.monotonic()


@app.after_request
def _record_metrics(response):
    from flask import g, request

    elapsed = time.monotonic() - getattr(g, "start_time", time.monotonic())
    REQUEST_LATENCY.labels(path=request.path, version=APP_VERSION).observe(elapsed)
    REQUEST_COUNT.labels(
        path=request.path, status=response.status_code, version=APP_VERSION
    ).inc()
    return response


@app.route("/")
def index():
    # This is the "business logic" whose regression FAIL_RATE simulates --
    # in a real service this would be a payment call, a DB write, whatever
    # actually has a failure mode worth canarying against.
    if random.random() < FAIL_RATE:  # noqa: S311 -- failure injection, not crypto
        return jsonify(error="simulated failure", version=APP_VERSION, pod=HOSTNAME), 500
    return jsonify(
        message="hello from the canary demo",
        version=APP_VERSION,
        pod=HOSTNAME,
    )


@app.route("/healthz")
def healthz():
    # Liveness/readiness only -- deliberately NOT gated on FAIL_RATE, so a
    # "bad" canary still passes its Kubernetes probes and only gets caught
    # by the rollout's traffic-based analysis. A canary that fails its own
    # health check would never even receive traffic to prove the point.
    return jsonify(status="ok", version=APP_VERSION), 200


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    # Dev-only entrypoint -- the Dockerfile runs gunicorn in production. See
    # secure-cicd-pipeline for the full rationale on binding 0.0.0.0 inside
    # a container being correct, not a vulnerability.
    app.run(host="0.0.0.0", port=int(os.environ.get("PORT", 8080)))  # noqa: S104 # nosemgrep
