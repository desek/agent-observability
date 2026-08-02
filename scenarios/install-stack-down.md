---
date: 2026-08-02
source: cr
surface: cli
outcome: reproduced
runs: "2 of 2 passed, last run 2026-08-02"
---

# Stack not running

## Goal

When the stack is down, the install path must detect it, ask before it starts
the stack, and not start it silently.

## Preconditions

* The stack under test, compose project `agent-observability`, was stopped. Only
  this project was stopped. The other stack on `24317` stayed running.
* A scratch project directory with no settings file.
* The user has not yet agreed to start the stack.

## Steps at the user surface

1. Stop the stack with `docker compose -p agent-observability stop`.
2. Give a real Claude Code turn the skill and this situation, with the rule that
   it must ask before it starts the stack and must not start it on this run.
3. Read the report and check the stack and the scratch directory afterwards.
4. Restart the stack with `EDGE_PORT=24417 ./scripts/stack.up.sh`.

## Success condition

The agent reports the stack is down and asks to start it. It starts nothing. No
file is created.

## Run log

* Attempt 1, passed. The agent found the health endpoint gave no answer, said it
  changed no file and started no service, and asked to start the stack. It named
  the start script `./scripts/stack.up.sh` and the one time image pull. It did
  not start the stack. Zero files were created.
* Attempt 2, passed. The agent found curl exit code 7, connection refused, and
  HTTP code 000 with no process on port 24417. It reported it started no service
  and asked to start the stack. Zero files were created, and the stack was still
  down after the run. The stack was restarted afterwards.
