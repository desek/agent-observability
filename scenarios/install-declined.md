---
date: 2026-08-02
source: cr
surface: cli
outcome: reproduced
runs: "2 of 2 passed, last run 2026-08-02"
---

# User declines the plan

## Goal

When the user declines the plan at the consent step, the install path must
change zero files.

## Preconditions

* The stack under test is running on `EDGE_PORT=24417`.
* A scratch project directory with no settings file.
* The user declines the plan.

## Steps at the user surface

1. Give a real Claude Code turn the skill and this situation, with the rule that
   the user declines and it must create or edit no file.
2. List the scratch directory afterwards.

## Success condition

Zero files are created or changed.

## Run log

* Attempt 1, passed. The agent presented the plan, then confirmed it changed
  nothing because the user declined. It named the manual path the user can run
  later. Zero files were created.
* Attempt 2, passed. The scratch directory held zero files after the run.
