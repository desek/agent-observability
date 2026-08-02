# Changelog

All notable changes to `@desek/pi-mlflow-tracing` are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The newest
version heading always matches the `version` field in `package.json`.

This package is prepared for publication but is not published by the change that
created it. Its first release reaches a registry only through the repository's
release automation, which also produces the released entry below.

## 0.1.0 - Unreleased

First prepared release. The extension reconstructs each pi agent loop as an
MLflow-readable conversation and exports it to a configurable MLflow tracking
server, defaulting to this project's local stack.

### Added

- Public `@desek/pi-mlflow-tracing` package, licensed Apache-2.0, discoverable in
  the pi package gallery through the `pi-package` keyword.
- Safe-by-default operation: the extension records nothing and opens no
  connection unless its master switch `PI_MLFLOW_ENABLE` is truthy, and a
  telemetry fault can never crash, block, or slow the agent.
