
# ==================================
# 1) Frontend Build (Bun)
# ==================================
FROM oven/bun:1 AS frontend-builder

WORKDIR /app
COPY lightrag_webui/ ./lightrag_webui/

# Build the frontend
RUN cd lightrag_webui \
    && NODE_ENV=production bun install --frozen-lockfile \
    && bun run build

# After this, we assume output is: /app/lightrag_webui/dist/

# ==================================
# 2) Python builder (venv + deps)
# ==================================
FROM python:3.11-slim AS builder

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    DEBIAN_FRONTEND=noninteractive

WORKDIR /app

# System deps that commonly help with building packages.
# Add more only if your deps need them (e.g., libpq-dev, libffi-dev, libxml2-dev)
RUN apt-get update && apt-get install -y --no-install-recommends \
    build-essential \
    gcc \
    pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Leverage layer cache
COPY requirements.txt ./
RUN python -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"
RUN pip install --upgrade pip setuptools wheel \
    && pip install --no-cache-dir -r requirements.txt

# Copy backend source
COPY lightrag/ ./lightrag/

# Place frontend build into backend's expected static dir
# Ensure destination exists
RUN mkdir -p /app/lightrag/api/webui \
    && true

# bring the built static assets from the previous stage
COPY --from=frontend-builder /app/lightrag_webui/dist/ /app/lightrag/api/webui/

# (Optional) quick import check to fail fast at build time
# RUN python -c "import lightrag, sys; print('Imported lightrag OK with', sys.version)"

# ==================================
# 3) Runtime image
# ==================================
FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PATH="/opt/venv/bin:$PATH" \
    PYTHONPATH="/app"

WORKDIR /app

# Copy the virtual env and the application
COPY --from=builder /opt/venv /opt/venv
COPY --from=builder /app/lightrag /app/lightrag

# Data dirs (App Runner’s ephemeral storage in container)
ENV TIKTOKEN_CACHE_DIR=/app/data/tiktoken \
    WORKING_DIR=/app/data/rag_storage \
    INPUT_DIR=/app/data/inputs

RUN mkdir -p /app/data/rag_storage /app/data/inputs /app/data/tiktoken

# App Runner default (or configure in service): 8080
EXPOSE 8080

# Ensure the server listens on 0.0.0.0:8080
# If your lightrag_server supports CLI args, use them; otherwise set env that it reads.
ENTRYPOINT ["python", "-m", "lightrag.api.lightrag_server", "--host", "0.0.0.0", "--port", "8080"]