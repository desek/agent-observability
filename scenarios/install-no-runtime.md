---
date: 2026-08-02
source: cr
surface: cli
outcome: reproduced
runs: "2 of 2 passed, last run 2026-08-02"
---

# Container runtime absent

## Goal

On a machine where the container runtime does not answer, the install path must
stop before it proposes any plan, name the missing prerequisite and its fix, and
not show a raw runtime error on its own.

## Preconditions

* `docker` was shadowed on the `PATH` with a stub that prints a not found
  message and exits non zero, so `docker compose version` fails. No software was
  removed. This exercises the prerequisite gate, not a machine with the runtime
  physically deleted.
* A scratch project directory with no settings file.

## Steps at the user surface

1. Give a real Claude Code turn the skill and ask it to install, with `docker`
   shadowed by the failing stub.
2. Read the agent report and the scratch directory afterwards.

## Success condition

The agent stops before any plan. It names the fix, install Docker Desktop or the
`docker-compose-plugin` package. No file is created.

## Run log

* Attempt 1, passed. The agent reported that a container runtime with the Docker
  Compose v2 plugin is required, that the legacy `docker-compose` v1 script does
  not work, and that Docker Desktop is present in `/Applications` and should be
  started. It said it does not install the runtime. It also gave the manual path
  for later. Zero files were created.
* Attempt 2, passed. The agent again stopped at the gate, named the
  `docker-compose-plugin` fix and Docker Desktop, and created no file.
