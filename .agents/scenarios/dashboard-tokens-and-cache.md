<!-- @agents-index User scenario for the Tokens and cache row of the dashboard: the verifier passes, a period without samples is a gap, and both token bands are visible. -->

# Read the Tokens and cache row

Source: the approved change request for growth queries on the dashboard.

## Goal

A user confirms that the provisioned dashboard is correct on a stack that holds
real agent telemetry, and reads token throughput over the last 24 hours.

## Preconditions

* The stack runs (`scripts/stack.up.sh`).
* The store holds Claude Code token samples from the last 24 hours.
* The range contains a period in which the stack was down.

## Steps

1. Run `scripts/dashboard.verify.sh`.
2. Run `./scripts/deeplink.sh dashboard --var agent=claude-code --from now-24h --to now`.
3. Open the URL in a browser at 1440 pixels wide and sign in.
4. Scroll to the `Tokens and cache` row.

## Success condition

* The verifier exits 0 and its last line is `verify: all checks passed`.
* `Output tokens per second` shows no line for the period in which the stack was down.
* `Input and output tokens` shows a green band above zero and a blue band below zero.
* `Cache hit ratio` shows a percentage.

## Runs

| Date | Outcome | Attempts | Note |
|---|---|---|---|
| 2026-10-05, before the fix | reproduced | 1 of 1 failed | The verifier exited 1 on `Time by subagent type`. The throughput panel showed a zero line from 06:30 to 10:05. The output band was flat. |
| 2026-10-05, after the fix | passes | 2 of 2 succeeded | The verifier exited 0. The throughput panel showed a gap for the same period. Both bands were visible. |
