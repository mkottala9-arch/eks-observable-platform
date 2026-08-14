import os
import time
from flask import Flask, Response, request
from prometheus_client import (
    Counter,
    Histogram,
    Gauge,
    generate_latest,
    CONTENT_TYPE_LATEST,
)

app = Flask(__name__)

# config comes from the environment, not the code (12-factor).
# APP_VERSION / GIT_COMMIT are baked in at docker build time via --build-arg.
# APP_ENV / FAULT_MODE are set at deploy time via the Helm chart's values.yaml.
APP_VERSION = os.environ.get("APP_VERSION", "unknown")
GIT_COMMIT = os.environ.get("GIT_COMMIT", "unknown")
APP_ENV = os.environ.get("APP_ENV", "unknown")
FAULT_MODE = os.environ.get("FAULT_MODE", "false").lower() == "true"

# ---------- metrics ----------

REQUEST_COUNT = Counter(
    "app_requests_total",
    "Total HTTP requests",
    ["method", "endpoint", "status"],
)
REQUEST_LATENCY = Histogram(
    "app_request_latency_seconds",
    "Request latency in seconds",
    ["endpoint"],
)
BUILD_INFO = Gauge(
    "app_build_info",
    "Build version info. Value is always 1, the data lives in the labels.",
    ["version", "commit", "environment"],
)
FAULT_MODE_GAUGE = Gauge(
    "app_fault_mode",
    "1 if fault mode is enabled, 0 otherwise",
)

# set once at startup, these don't change for the life of the process
BUILD_INFO.labels(
    version=APP_VERSION,
    commit=GIT_COMMIT,
    environment=APP_ENV,
).set(1)
FAULT_MODE_GAUGE.set(1 if FAULT_MODE else 0)


# ---------- request instrumentation ----------
# runs for every route automatically, so nothing has to remember to
# record metrics by hand inside each handler

@app.before_request
def start_timer():
    request.start_time = time.perf_counter()


@app.after_request
def record_metrics(response):
    latency = time.perf_counter() - request.start_time
    REQUEST_LATENCY.labels(endpoint=request.path).observe(latency)
    REQUEST_COUNT.labels(
        method=request.method,
        endpoint=request.path,
        status=response.status_code,
    ).inc()
    return response


# ---------- routes ----------

def index_response(fault_mode):
    # pulled out as its own function so it can be tested directly,
    # without needing to start a real app or fake an env var.
    if fault_mode:
        return "Internal Server Error", 500
    return "OK", 200


@app.route("/")
def index():
    return index_response(FAULT_MODE)


@app.route("/healthz")
def healthz():
    # liveness: is the process alive at all. kept intentionally dumb -
    # if this fails, kubernetes restarts the container.
    return "OK", 200


@app.route("/readyz")
def readyz():
    # readiness: should traffic be sent here. no real dependencies to
    # check in this app, so it's always ready once the process is up.
    return "Ready", 200


@app.route("/version")
def version():
    return {
        "version": APP_VERSION,
        "commit": GIT_COMMIT,
        "environment": APP_ENV,
    }, 200


@app.route("/metrics")
def metrics():
    return Response(generate_latest(), content_type=CONTENT_TYPE_LATEST)


if __name__ == "__main__":
    app.run(host="0.0.0.0", port=8080)