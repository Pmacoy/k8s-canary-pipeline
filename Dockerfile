# syntax=docker/dockerfile:1
FROM python:3.13-slim AS base

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

# Same reasoning as secure-cicd-pipeline's Dockerfile: pull Debian's own
# security-patched OS packages at build time without bumping the base tag.
RUN apt-get update && apt-get upgrade -y && rm -rf /var/lib/apt/lists/*

WORKDIR /app

# hadolint ignore=DL3013
RUN pip install --no-cache-dir --upgrade pip setuptools

COPY app/requirements.txt ./app/requirements.txt
RUN pip install --no-cache-dir -r app/requirements.txt

# Same rationale as secure-cicd-pipeline: pip/setuptools/ensurepip have no
# runtime purpose in a container that only ever runs gunicorn, and leaving
# them in ships their own (unfixable-by-upgrade) CVEs along for the ride.
RUN pip uninstall -y pip setuptools wheel || true \
    && rm -rf /usr/local/lib/python3.13/ensurepip \
              /usr/local/lib/python3.13/site-packages/pip* \
              /usr/local/lib/python3.13/site-packages/setuptools* \
              /usr/local/lib/python3.13/site-packages/wheel* \
              /usr/local/lib/python3.13/site-packages/pkg_resources \
              /usr/local/bin/pip*

COPY app/ ./app/

RUN groupadd --system canary && useradd --system --gid canary --no-create-home canary
# hadolint ignore=DL3066
USER canary

EXPOSE 8080

# hadolint ignore=DL3025
HEALTHCHECK --interval=10s --timeout=3s --start-period=5s --retries=5 \
    CMD python -c "import urllib.request as u; u.urlopen('http://localhost:8080/healthz', timeout=2)" || exit 1

# --access-logfile - keeps request logs on stdout, which is what lets the
# canary-e2e workflow's log dump show real traffic during the demo.
CMD ["gunicorn", "--bind", "0.0.0.0:8080", "--workers", "2", "--access-logfile", "-", "app.main:app"]
