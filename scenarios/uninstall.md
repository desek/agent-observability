---
date: 2026-08-02
source: cr
surface: cli
outcome: reproduced
runs: "2 of 2 passed, last run 2026-08-02"
---

# Uninstall reverses install

## Goal

On a configured machine, the uninstall path must remove every key the install
added, keep every other key, remove the tools file the install placed, and leave
the agent no longer exporting to the stack under test.

## Preconditions

* The stack under test is running on `EDGE_PORT=24417`.
* A scratch project configured by the install path.
* The user consents to the uninstall.

## Steps at the user surface

1. Give a real Claude Code turn the uninstall section of the skill and this
   situation.
2. Inspect the settings file and the tools file afterwards.
3. Drive one turn with `EDGE_PORT=24417 scripts/agent.verify.sh claude-code
   --drive`. It must fail with signals missing on `24417`, which is the proof
   that export to the stack under test has stopped.

## Success condition

Every install telemetry key is removed. Every unrelated key survives. The tools
file is removed. A driven turn produces no new log and no new trace on `24417`.

## Run log

* Attempt 1, passed. On a directory that also held unrelated content, the agent
  removed the telemetry keys and kept `EDITOR=vim`, `MY_EXISTING_VAR=keep-me`,
  `model=opus`, and the `permissions` block. It removed `.mcp.json` and kept a
  backup. It took a fresh backup of the settings file and left valid JSON. The
  drive on `24417` reported the log and the trace missing, which proves export
  stopped. The turn fell back to the global settings, which point at the other
  stack.
* Attempt 2, passed. On a directory with fourteen telemetry keys, all fourteen
  were removed, the `env` block was left empty, `.mcp.json` was removed, and the
  file was valid JSON. The drive on `24417` again reported the log and the trace
  missing.

## A note on the residual metric

The drive after uninstall reports the log and the trace missing, and sometimes
still matches the metric. The metric query reads the last counter sample inside
an age based window, and each agent counter is cumulative, so an earlier sample
from a prior run inside the window can still match. The decisive proof that
export stopped is the absence of a new log and a new trace after the turn
started, since those are looked for only after the drive start marker.
