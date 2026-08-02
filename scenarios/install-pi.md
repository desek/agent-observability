---
date: 2026-08-02
source: cr
surface: cli
outcome: reproduced
runs: "2 of 2 passed, last run 2026-08-02"
---

# pi install and verify

## Goal

For pi, the install path must install the published package by its registry
specifier, set the master switch and the endpoint, and prove telemetry with one
real turn.

## Preconditions

* The stack under test is running on `EDGE_PORT=24417`.
* A scratch project directory with no pi extension installed.
* The pi extension defaults its endpoint to `EDGE_PORT`, which defaults to
  `24317`, so the endpoint must be set to `24417` to route to the stack under
  test, not to the other stack.

## Steps at the user surface

1. Install the extension project locally with
   `pi install npm:@desek/pi-opentelemetry -l --approve`. This is the exact
   command the skill names.
2. Export the master switch `PI_OTEL_ENABLE=1` and the endpoint
   `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:24417`.
3. Drive one turn and assert the signals with
   `EDGE_PORT=24417 scripts/agent.verify.sh pi --drive`.

## Success condition

The package is installed and listed in the pi settings. One driven pi turn puts
a metric, a log, and a trace on `24417`.

## Run log

* Attempt 1, passed. `pi install npm:@desek/pi-opentelemetry -l --approve` added
  the package and wrote it into `.pi/settings.json`. A probe turn loaded the
  extension without an approval prompt and returned its output. The drive
  asserted a pi metric, a pi log, and a pi trace on `24417`: PASS.
* Attempt 2, passed. A second driven pi turn again put a metric, a log, and a
  trace on `24417`: PASS.
