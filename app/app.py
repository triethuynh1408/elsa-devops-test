"""quote-api: tiny HTTP service for the ELSA DevOps take-home.

Endpoints:
  GET /healthz    liveness  - process is alive
  GET /readyz     readiness - ready to receive traffic (false while shutting down)
  GET /metrics    Prometheus metrics
  GET /api/quote  random quote, burns ~100ms of CPU per request
"""
import os
import random
import signal
import time

from flask import Flask, Response, g, jsonify, request
from prometheus_client import CONTENT_TYPE_LATEST, Counter, Histogram, generate_latest

QUOTES = [
    "Simplicity is prerequisite for reliability. - Edsger Dijkstra",
    "Hope is not a strategy. - Google SRE book",
    "Everything fails, all the time. - Werner Vogels",
    "Make it work, make it right, make it fast. - Kent Beck",
    "If it hurts, do it more often. - Martin Fowler",
    "The best way to predict the future is to invent it. - Alan Kay",
]

# CPU budget per /api/quote request (seconds of CPU time, not wall time).
CPU_WORK_SECONDS = float(os.getenv("CPU_WORK_SECONDS", "0.1"))
VERSION = os.getenv("APP_VERSION", "dev")

REQUESTS = Counter(
    "http_requests_total", "HTTP requests handled", ["method", "path", "status"]
)
LATENCY = Histogram(
    "http_request_duration_seconds",
    "HTTP request latency",
    ["path"],
    buckets=(0.05, 0.1, 0.15, 0.2, 0.3, 0.5, 0.75, 1, 2, 5),
)
QUOTES_SERVED = Counter("quotes_served_total", "Quotes returned by /api/quote")

app = Flask(__name__)
state = {"ready": True}


_previous_sigterm = signal.getsignal(signal.SIGTERM)


def _on_sigterm(signum, frame):
    # Fail readiness first so Kubernetes stops routing traffic to us, then hand
    # over to the previous handler (gunicorn's graceful shutdown) - replacing it
    # would leave the worker running until it gets SIGKILLed.
    state["ready"] = False
    if callable(_previous_sigterm):
        _previous_sigterm(signum, frame)
    else:
        raise SystemExit(0)


signal.signal(signal.SIGTERM, _on_sigterm)


def burn_cpu(seconds):
    """Busy-loop until this thread has consumed `seconds` of CPU time.

    thread_time() counts CPU actually used, so under CPU throttling
    (k8s limits) the work stays constant and wall-clock latency grows,
    which is exactly what a real CPU-bound handler would do.
    """
    start = time.thread_time()
    x = 0
    while time.thread_time() - start < seconds:
        x += sum(i * i for i in range(1000))
    return x


@app.before_request
def _start_timer():
    g.start = time.perf_counter()


@app.after_request
def _record_metrics(response):
    # Use the matched route (not the raw URL) to keep label cardinality bounded.
    path = request.url_rule.rule if request.url_rule else "unmatched"
    REQUESTS.labels(request.method, path, str(response.status_code)).inc()
    LATENCY.labels(path).observe(time.perf_counter() - g.start)
    return response


@app.get("/healthz")
def healthz():
    return jsonify(status="ok")


@app.get("/readyz")
def readyz():
    if not state["ready"]:
        return jsonify(status="shutting down"), 503
    return jsonify(status="ready")


@app.get("/metrics")
def metrics():
    return Response(generate_latest(), mimetype=CONTENT_TYPE_LATEST)


@app.get("/api/quote")
def quote():
    burn_cpu(CPU_WORK_SECONDS)
    QUOTES_SERVED.inc()
    return jsonify(quote=random.choice(QUOTES), version=VERSION, host=os.uname().nodename)


if __name__ == "__main__":
    # Local dev only; the container runs gunicorn (see Dockerfile).
    # Loopback by default so the dev server is never exposed on the network.
    app.run(host=os.getenv("HOST", "127.0.0.1"), port=int(os.getenv("PORT", "8080")))
