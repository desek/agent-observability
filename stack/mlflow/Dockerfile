# stack/mlflow/Dockerfile
#
# @agents-index Thin baked MLflow image: pinned official MLflow base plus the
# single pinned prometheus-flask-exporter so `mlflow server --expose-prometheus`
# works out of the box with no install step at container start.
#
# Purpose: The official mlflow image does not ship the optional
# `prometheus-flask-exporter` extra that MLflow's Prometheus metrics endpoint
# (`--expose-prometheus`) depends on. This is the observability stack's only
# custom image build: a thin pip layer, not a source recompile. It adds exactly
# one pinned Python package on top of the pinned official base and nothing else
# (in particular NOT the client-side OTLP trace exporter, which is a client
# dependency). The base tag stays pinned and explicit (never `latest`) so
# reproducibility and the stack's no-`latest` convention hold.
FROM ghcr.io/mlflow/mlflow:v3.15.0

# Single pinned package: activates the server's /metrics Prometheus endpoint.
# Pinned to an explicit version (never floating, never latest) per the stack's
# pinned-dependency convention.
RUN pip install --no-cache-dir prometheus-flask-exporter==0.23.2
