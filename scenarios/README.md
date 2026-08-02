# Install path scenarios

This directory holds the user scenarios that prove the agent driven install
path from the user seat. Each scenario drives the real install instruction with
a real coding agent and grades the end state, not the transcript. The install
path is prose run by a model, so a single good run is not proof. Each scenario
was run more than once and records how many attempts of how many reached the
success condition.

## How the scenarios were run

* **The surface.** The install instruction lives in
  `skills/observability-install/SKILL.md`. Each scenario gave a real Claude Code
  turn, or a real pi turn, the skill and one situation, then inspected the files
  and the stack afterwards.
* **The stack under test binds one port.** This machine runs two separate
  stacks. The stack under test is the compose project `agent-observability`,
  published on the loopback port that `.env` sets in `EDGE_PORT`, which is
  `24417`. A different private stack answers on `24317`. No scenario queried,
  wrote to, started, or stopped `24317`.
* **Routing.** This machine's global Claude Code settings pin the export
  endpoint to `24317`. A Claude Code settings file at project scope wins over the
  global file, so every scenario ran in a scratch project directory whose
  `.claude/settings.json` pins the endpoint to `24417`. This routing was proven
  before the scenarios ran: a driven turn in such a directory put its metric,
  its log, and its trace on `24417`, not on `24317`.
* **Signals observed.** The end to end proof used the repository script the skill
  itself calls, `scripts/agent.verify.sh <agent> --drive`. It drives one real
  turn, waits for the export interval, then asserts the metric, the log, and the
  trace on `24417`. A wait of 45 seconds was reliable for the trace.
* **No real settings changed.** No scenario wrote to the repository
  `.claude/settings.json`, to `.claude/settings.local.json`, or to the user
  global `~/.claude/settings.json`. Every write went to a scratch directory
  outside the repository. The three real files were confirmed unchanged after
  the run.

## How the missing runtime was simulated

The no runtime scenario did not remove any software. It shadowed `docker` on the
`PATH` with a stub that prints a not found message and exits non zero, so
`docker compose version` fails exactly as an absent or broken runtime makes it
fail. This exercises the skill prerequisite gate. It does not exercise a machine
with the Docker binaries physically deleted.

## Results

| Scenario | File | Attempts passed | Verdict |
|---|---|---|---|
| Fresh clone, stack never started | `install-fresh-clone.md` | 1 of 1 | reproduced |
| Container runtime absent | `install-no-runtime.md` | 2 of 2 | reproduced |
| Fresh install, no settings file | `install-fresh-claude-code.md` | 2 of 2 | reproduced |
| Existing settings, unrelated content | `install-existing-settings.md` | 2 of 2 | reproduced |
| Telemetry already pointing elsewhere | `install-conflicting-endpoint.md` | 2 of 2 | reproduced |
| Stack not running | `install-stack-down.md` | 2 of 2 | reproduced |
| Second run changes nothing | `install-idempotent.md` | 2 of 2 | reproduced |
| User declines the plan | `install-declined.md` | 2 of 2 | reproduced |
| pi install and verify | `install-pi.md` | 2 of 2 | reproduced |
| Uninstall reverses install | `uninstall.md` | 2 of 2 | reproduced |

`reproduced` here means the scenario drove the real path and the graded end
state was reached. Grading is on the end state, the files and the stack after
the run.
