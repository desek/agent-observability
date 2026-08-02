---
date: 2026-08-02
source: cr
surface: cli
outcome: reproduced
runs: "2 of 2 passed, last run 2026-08-02"
---

# Fresh install, no settings file

## Goal

On a machine with a running stack and no Claude Code settings file, the install
path must write a valid settings file with the telemetry keys, place the tools
configuration, write no content flag, and prove telemetry with one real turn.

## Preconditions

* The stack under test is running on `EDGE_PORT=24417`.
* A scratch project directory with no `.claude` directory.
* The user consents to project scope. Content logging is not chosen.

## Steps at the user surface

1. Give a real Claude Code turn the skill and this situation. The turn starts
   from the plan step, since the stack is already up and verified.
2. Inspect the settings file and the tools file.
3. Drive one turn and assert the signals with
   `EDGE_PORT=24417 scripts/agent.verify.sh claude-code --drive`.

## Success condition

`.claude/settings.json` holds the endpoint `http://localhost:24417` and the
temporality key `cumulative`. No content flag is written by the install. One
driven turn puts a metric, a log, and a trace on `24417`.

## Run log

* Attempt 1, passed. The agent wrote `.claude/settings.json` with the ten
  telemetry keys, the endpoint at `24417`, and the temporality key. It placed
  `.mcp.json` with the port rewritten from the template `24317` to `24417`. It
  wrote no content flag. It reported the subtle fact that the global settings
  file carries content flags that merge into the project by inheritance, and it
  did not change the global file. The drive asserted a metric, a log, and a
  trace on `24417`: PASS.
* Attempt 2, passed. The agent again wrote the endpoint at `24417` and the
  temporality key `cumulative`, with no content flag. End state graded PASS on
  the settings keys.
