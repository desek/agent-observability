# Changelog

All notable changes to `@desek/pi-opentelemetry` are recorded here. The format
follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/), and the project
follows [Semantic Versioning](https://semver.org/spec/v2.0.0.html). The newest
version heading always matches the `version` field in `package.json`.

## 0.1.0 - 2026-08-02

First published release. The extension was already functionally complete inside
a private repository; this release makes it installable by any pi user.

### Added

- Public `@desek/pi-opentelemetry` package, licensed Apache-2.0, discoverable in
  the pi package gallery through the `pi-package` keyword.
- OpenTelemetry export at parity with Claude Code's built-in telemetry: the eight
  `pi.` metric instruments, the `pi.` log-event family, and the interaction,
  model-request, tool, and tool-execution span hierarchy, all over OTLP gRPC.
- Safe-by-default operation: the extension emits nothing unless its master switch
  is truthy or a health-gated dynamic default enables it, stays silent when no
  collector is reachable, never propagates an exception into the agent, and keeps
  every content-logging flag off until an explicit opt-in.

### Changed

- The default OTLP endpoint is now the OpenTelemetry standard `localhost:4317`,
  and the default health-probe target is Grafana Alloy's native
  `localhost:12345/-/healthy`, replacing the private stack's single-port edge
  address. A consumer who fronts the collector behind a different address points
  the extension at it through `OTEL_EXPORTER_OTLP_ENDPOINT`.
- The OpenTelemetry API package is now a peer dependency rather than an ordinary
  dependency, because two copies of the API package in one process silently break
  instrumentation registration. Consumers who previously loaded the extension by
  local path must now resolve `@opentelemetry/api` in their host project.
