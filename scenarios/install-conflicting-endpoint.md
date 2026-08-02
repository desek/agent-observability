---
date: 2026-08-02
source: cr
surface: cli
outcome: reproduced
runs: "2 of 2 passed, last run 2026-08-02"
---

# Telemetry already configured to a different address

## Goal

When the settings file already points telemetry at a different address, the
install path must show the existing value, ask before it replaces it, and change
nothing without consent.

## Preconditions

* The stack under test is running on `EDGE_PORT=24417`.
* A scratch project `.claude/settings.json` pins
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://otel-collector.corp.internal:4317`.
* The user has not authorized replacing any value.

## Steps at the user surface

1. Give a real Claude Code turn the skill and this situation, with the rule that
   it must show and ask before it replaces any value, and must not replace the
   endpoint on this run.
2. Compare the settings file before and after, and read the report.

## Success condition

The existing endpoint value is shown to the user. It is not replaced. The
settings file is byte for byte the same after the run.

## Run log

* Attempt 1, passed. The agent reported the existing value
  `http://otel-collector.corp.internal:4317`, named it a corporate collector,
  and stated the value it would set instead, `http://localhost:24417`. It did
  not replace it. It offered two options, replace in the committed file, or
  override for this user in `.claude/settings.local.json`, and asked the user to
  choose. The settings file was identical before and after.
* Attempt 2, passed. The agent again showed the `corp.internal` value, did not
  replace it, and the settings file was identical before and after.
