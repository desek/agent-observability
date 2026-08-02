<!-- @agents-index: Measured values for the CR-0002 dashboard panels on this repository's stack, recorded because a finalization pass cited figures from a different stack. -->

# Measured panel values, recorded for the audit trail

The finalization pass reported a total cost of 6212.26 United States dollars and
6900826759 tokens as its evidence that the counter panels return a non-zero
value. Those figures do not come from this repository's stack.

Measured with the dashboard's own committed expression:

| Stack | Window | Total cost |
|---|---|---|
| This repository, compose project `agent-observability` | 24h, 7d, 30d, 90d | 0.4317235 |
| A different private stack, compose project `observability`, port 24317 | 24h | 634.12891515 |
| The same private stack | 30d | 6213.0037462 |

The reported figure matches the private stack over a 30 day window, so the
finalization pass measured the wrong system.

The conclusion it drew still holds. This repository's stack returns 0.4317235
for the cost panel, which is non-zero, so the requirement that a counter panel
must return a true value rather than zero is met. Only the cited evidence was
wrong, and no incorrect figure reached any committed file.

The lesson is worth keeping: two stacks run on this machine, they answer the
same query with different numbers, and a query that names no port answers from
whichever one the shell last had in scope. Any measurement recorded as evidence
must state the port it was taken on.
