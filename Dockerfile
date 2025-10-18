# ==================================
# 1. Frontend Build Stage (Using Bun)
# ==================================
FROM oven/bun:1 AS frontend-builder

WORKDIR /app

# Copy and build frontend assets
COPY lightrag_webui/ ./lightrag_webui/

RUN cd lightrag_webui \
    # 🛠️ FIX #2: Use a temporary environment setting to disable postinstall scripts
    # This prevents esbuild's problematic version check from running.
    && npm config set ignore-scripts true \
    && bun install --frozen-lockfile \
    && npm config set ignore-scripts false \
    && bun run build

# ==================================
# 2. Python Dependencies Build Stage
# ==================================
# Use a Python image with development tools (for compiling native extensions if needed)
FROM python:3.11-slim AS builder

# Set necessary environment variables
ENV PYTHONDONTWRITEBYTECODE 1
ENV PYTHONUNBUFFERED 1
ENV DEBIAN_FRONTEND noninteractive

WORKDIR /app

# Install system dependencies needed for compiling some Python packages (e.g., cryptography, numpy)
# This replaces the custom Rust/pkg-config install, relying on common build essentials.
RUN apt-get update \
    && apt-get install -y --no-install-recommends \
        build-essential \
        pkg-config \
    && rm -rf /var/lib/apt/lists/*

# Copy only dependency files first for better layer caching
COPY pyproject.toml .
COPY setup.py .
COPY requirements.txt .

# --- Dependency Installation ---
# Replace uv steps with standard pip, as pip is available by default.
# If you MUST use uv: install it here (e.g., pip install uv) and adjust the RUN command.
# Using standard pip with a virtual environment:

# Create a virtual environment
RUN python3 -m venv /opt/venv
ENV PATH="/opt/venv/bin:$PATH"

# Install dependencies
# Note: Since you use 'extra api' and 'extra offline', you need to install from source.
# We'll use a standard `requirements.txt` approach for simplicity here.
# If your project strictly requires extras, you'll need to install the project first.
# For now, let's assume a generated requirements.txt for all required packages.
RUN pip install --no-cache-dir -r requirements.txt

# --- Application Source Copy ---
# Copy application code and assets
COPY lightrag/ ./lightrag/
COPY --from=frontend-builder /app/lightrag/api/webui ./lightrag/api/webui

# --- Cache Preparation (If Necessary) ---
# If lightrag-download-cache is a critical step, keep it.
# If you don't use a venv, adjust the path:
# RUN python -m lightrag.api.lightrag_server lightrag-download-cache --cache-dir /app/data/tiktoken

# ==================================
# 3. Final Minimal Runtime Stage
# ==================================
# Use the smallest possible runtime image
FROM python:3.11-slim

WORKDIR /app

# Copy virtual environment (including all installed packages)
COPY --from=builder /opt/venv /opt/venv

# Copy source code
COPY --from=builder /app/lightrag ./lightrag
COPY pyproject.toml .
COPY setup.py .
COPY requirements.txt .

# Copy any prepared data/caches
# COPY --from=builder /app/data/tiktoken /app/data/tiktoken # Uncomment if you pre-cache tiktoken

# Set PATH to include the virtual environment
ENV PATH="/opt/venv/bin:$PATH"

# Set application-specific environment variables
ENV TIKTOKEN_CACHE_DIR=/app/data/tiktoken
ENV WORKING_DIR=/app/data/rag_storage
ENV INPUT_DIR=/app/data/inputs

# Create persistent data directories (App Runner's ephemeral storage)
RUN mkdir -p /app/data/rag_storage /app/data/inputs /app/data/tiktoken

# Expose API port (MUST match App Runner configuration: 9621)
EXPOSE 8080

# Start the application server (MUST match App Runner start command)
ENTRYPOINT ["python", "-m", "lightrag.api.lightrag_server"]
