---
date: 2026-08-02
source: cr
surface: cli
outcome: reproduced
runs: "2 of 2 passed, last run 2026-08-02"
---

# Existing settings file with unrelated content

## Goal

When a settings file already holds unrelated content, the install path must
preserve that content, add the telemetry keys to the `env` block, take a backup,
and leave a valid file.

## Preconditions

* The stack under test is running on `EDGE_PORT=24417`.
* A scratch project `.claude/settings.json` holds `"model": "opus"`, an `env`
  block with `MY_EXISTING_VAR=keep-me` and `EDITOR=vim`, and a `permissions`
  block allowing `Bash(git status)`.
* The user consents to project scope.

## Steps at the user surface

1. Give a real Claude Code turn the skill and this situation.
2. Compare the settings file before and after.

## Success condition

The pre existing keys survive. The telemetry keys are added to the `env` block.
A backup file exists. The result is valid JSON.

## Run log

* Attempt 1, passed. After the run, `model` was still `opus`, `MY_EXISTING_VAR`
  was still `keep-me`, `EDITOR` was still `vim`, and the `permissions` block was
  unchanged. The ten telemetry keys were added to the `env` block, with the
  endpoint at `24417` and the temporality key `cumulative`. A backup file
  `settings.json.bak` held the pre install state. The file parsed as valid JSON.
* Attempt 2, passed. Same end state: `MY_EXISTING_VAR=keep-me` and `model=opus`
  survived, the endpoint `http://localhost:24417` was added, and the file was
  valid JSON.
