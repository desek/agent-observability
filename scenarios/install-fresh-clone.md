---
date: 2026-08-02
source: cr
surface: cli
outcome: reproduced
runs: "1 of 1 passed, run 2026-08-02"
---

# Fresh clone, stack never started

## Goal

A user opens a coding agent in a fresh clone where the stack is not running, and
asks the agent to install observability. The agent must run the whole path:
check the runtime, ask before it starts the stack, start it with the repository
script, verify the stack, configure the agent, and then prove telemetry with one
real turn.

## Preconditions

* The stack under test, compose project `agent-observability`, was stopped.
* `EDGE_PORT` is `24417`. The other stack on `24317` stays untouched.
* A scratch project directory with no settings file.

## Steps at the user surface

1. Stop the stack with `docker compose -p agent-observability stop`.
2. Give a real Claude Code turn the skill and this situation. The user consents
   to start the stack and to configure the project. The turn starts from the
   stack check.
3. After the turn, drive one turn and assert the signals with
   `EDGE_PORT=24417 scripts/agent.verify.sh claude-code --drive`.

## Success condition

The stack is started by the repository start script, not by a hand written
docker command. The stack passes verification. The project settings file pins
the endpoint to `24417`. One driven turn puts a metric, a log, and a trace on
`24417`.

## Run log

* Attempt 1, passed. The agent found `http://localhost:24417/api/health` gave no
  answer. It started the stack with `EDGE_PORT=24417 ./scripts/stack.up.sh`,
  which reported the stack ready, and it ran no docker command by hand. It ran
  `./scripts/stack.verify.sh`, which passed every check. It wrote
  `.claude/settings.json` with the ten telemetry keys, including
  `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE=cumulative`, and set the
  endpoint to `http://localhost:24417`. It set the four content flags to `0` to
  keep content logging off against the global inheritance. It placed `.mcp.json`
  with the port rewritten to `24417`. It did not touch the global settings file.
  The final drive asserted a metric, a log, and a trace on `24417`: PASS.
* The configure and observe half of this path is corroborated by
  `install-fresh-claude-code.md`, which reached the same end state twice from an
  already running stack.
