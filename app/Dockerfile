# syntax=docker/dockerfile:1

# ---- Stage 1: build - install dependencies into an isolated virtualenv ----
FROM python:3.12-slim AS builder
ENV PIP_NO_CACHE_DIR=1 PIP_DISABLE_PIP_VERSION_CHECK=1
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
COPY requirements.txt .
RUN pip install -r requirements.txt

# ---- Stage 2: runtime - only the venv + app code, no pip cache/build tools ----
FROM python:3.12-slim AS runtime
ARG APP_VERSION=dev
ENV PATH="/opt/venv/bin:$PATH" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    APP_VERSION=${APP_VERSION}

# Numeric UID so Kubernetes `runAsNonRoot: true` can verify it.
RUN groupadd --system --gid 10001 app \
 && useradd --system --uid 10001 --gid app --no-create-home app

COPY --from=builder /opt/venv /opt/venv
WORKDIR /app
COPY --chown=root:root app.py .

USER 10001
EXPOSE 8080

# 1 worker per container: scale with pods (HPA), not processes. It also keeps
# Prometheus counters correct without multiprocess mode.
# --worker-tmp-dir /dev/shm: gunicorn's heartbeat file must live on a writable
# tmpfs because the pod runs with readOnlyRootFilesystem (Part 2).
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "1", "--threads", "4", \
     "--worker-tmp-dir", "/dev/shm", "--graceful-timeout", "20", \
     "--access-logfile", "-", "app:app"]
