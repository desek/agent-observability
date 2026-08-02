---
date: 2026-08-02
source: cr
surface: cli
outcome: reproduced
runs: "2 of 2 passed, last run 2026-08-02"
---

# Second run changes nothing

## Goal

On a machine already configured by the install path, a second run must change no
file and must say the configuration is already in place.

## Preconditions

* The stack under test is running on `EDGE_PORT=24417`.
* A scratch project already configured by a prior run: `.claude/settings.json`
  holds the telemetry keys and `.mcp.json` holds the tools entry.
* The user consents to project scope.

## Steps at the user surface

1. Record a hash of `.claude/settings.json` and `.mcp.json`.
2. Give a real Claude Code turn the same skill and situation.
3. Record the hash again and compare.

## Success condition

The two files are unchanged. The agent states the configuration is already in
place.

## Run log

* Attempt 1, passed. The agent read every higher precedence level, confirmed no
  key it planned was blocked, and found every planned key already held its
  planned value. It reported that it created or changed no file and applied the
  idempotence rule. The config hash was identical before and after.
* Attempt 2, passed. The config hash was again identical before and after the
  second run.
