<!--
@agents-index: Example agent instruction file that teaches an agent this local telemetry stack: backend addresses through one port, the real metric names, the query recipes, the deep-link script, and the privacy and ask-first rules.
-->

# Agent guide to the local observability stack

**This file is an example. Copy it into the project you actually work in.**
Most of what an agent needs to know about this telemetry stack is the same in
every repository, so keep this file and change only these three things on copy:

1. The example queries filter on `git_repo="agent-observability"`. Change that
   value to your own repository name so a query returns your telemetry.
2. The dashboard variable examples pass `agent=claude-code`. Keep it, or set the
   agent you run.
3. If you moved the stack to a different machine or port, nothing here changes:
   every address is derived from `EDGE_PORT`, not written as a literal.

Read this file at the start of a session. The facts come first, the reasons
after.

## What the stack is

A local, single-tenant telemetry plane for coding agents. It stores metrics
(Mimir), logs (Loki), and traces (Tempo), shows them in Grafana, and tracks
agent conversations in MLflow. Everything runs in Docker on this machine and
nothing leaves it: only one loopback port is published, bound to `127.0.0.1`.

## First, resolve the port and check the stack is running

Every command below uses `$B` as the base URL. Run this block once; it derives
the port from `EDGE_PORT` (or `.env`, or the default) and never hard-codes it.

```bash
EDGE_PORT="${EDGE_PORT:-$(grep -E '^[[:space:]]*EDGE_PORT[[:space:]]*=' .env 2>/dev/null | cut -d= -f2 | tr -d '[:space:]')}"
EDGE_PORT="${EDGE_PORT:-24317}"
B="http://localhost:${EDGE_PORT}"
curl -sf "$B/api/health" >/dev/null && echo "stack is up at $B" || echo "stack is down; start it with scripts/stack.up.sh"
```

The published port defaults to `24317`. Set `EDGE_PORT` in `.env` to change it.

## Backend addresses, all through the one port

| Backend | Reached at | Readiness |
|---------|-----------|-----------|
| Grafana UI and API | `$B/` | `$B/api/health` |
| Mimir, metrics, Prometheus API | `$B/prometheus/...` | `$B/prometheus/ready` |
| Loki, logs | `$B/loki/...` | `$B/loki/ready` |
| Tempo, traces | `$B/tempo/...` | `$B/tempo/ready` |
| MLflow, conversations | `$B/mlflow/` | `$B/mlflow/health` |
| Grafana MCP server | `$B/grafana-mcp/mcp` | over the MCP handshake |

## The real metric names

These are the only metric names on the stack. Do not invent others. Both
families are counters, so every name ends in `_total`.

| Question | Claude Code | pi |
|----------|-------------|----|
| Sessions started | `claude_code_session_count_total` | `pi_session_count_total` |
| Tokens used | `claude_code_token_usage_tokens_total` | `pi_token_usage_tokens_total` |
| Cost in US dollars | `claude_code_cost_usage_USD_total` | `pi_cost_usage_USD_total` |
| Active time in seconds | `claude_code_active_time_seconds_total` | (not emitted by pi) |

The token metric splits by a `type` label. Its values are `input`, `output`,
`cacheRead`, `cacheCreation` (from Claude Code) and `cli` (from pi). Sum over
`type` for a total, or group by it to see the cache split.

Both families also carry the four git provenance labels `git_org`, `git_repo`,
`git_branch`, and `git_path`, so you can select one repository's telemetry.

### The one query fact that matters most

Query these counters with `last_over_time`, never with `rate` or `increase`.
Each agent session is a short-lived series that reports a cumulative total and
then stops, so `rate` and `increase` see no growth and return zero. `sum by
(type) (last_over_time(claude_code_token_usage_tokens_total[24h]))` returns the
per-type totals; `sum(rate(claude_code_token_usage_tokens_total[5m]))` returns
an empty result on this data shape.

## Query recipes, one worked example each

### Mimir, a metric question

```bash
curl -s --data-urlencode 'query=sum by (type) (last_over_time(claude_code_token_usage_tokens_total[24h]))' "$B/prometheus/api/v1/query" | python3 -m json.tool
```

Returns the token total per `type`. Swap the metric name for cost or session
count. Add a label to the selector, for example `{git_repo="agent-observability"}`,
to scope it to one repository.

### Loki, a log question

Loki defaults to a one-hour window and returns nothing for older data, so pass
an explicit range. Select a stream by `service_name` (`claude-code` or
`pi-coding-agent`) and filter by the git labels.

```bash
S=$(( ( $(date +%s) - 7*24*3600 ) * 1000000000 )); E=$(( $(date +%s) * 1000000000 ))
curl -s -G "$B/loki/api/v1/query_range" \
  --data-urlencode 'query={service_name="claude-code", git_repo="agent-observability"}' \
  --data-urlencode "start=$S" --data-urlencode "end=$E" --data-urlencode 'limit=1' \
  | python3 -m json.tool
```

An empty result means no matching log fell in the window; widen the range or
drop the `git_repo` filter. See the privacy rule before you print any log line.

### Tempo, a trace question

Tempo caps a search range at 168 hours; a wider range returns a 400 that names
the cap. Search a range under the cap.

```bash
NOW=$(date +%s); curl -s "$B/tempo/api/search?start=$(( NOW - 3600 ))&end=$NOW&limit=5" | python3 -m json.tool
```

An empty `traces` array is the expected result when no agent span has landed in
the window. Fetch one trace by id with `$B/tempo/api/traces/<traceid>`.

### MLflow, a conversation question

MLflow stores agent conversations as traces under an experiment. The Claude Code
experiment is named `claude-code` with id `1`. Use the version 3 search endpoint
with a `locations` body. The version 2 path returns 405, and a bare
`experiment_ids` body returns 400.

```bash
curl -s -X POST "$B/mlflow/api/3.0/mlflow/traces/search" \
  -H 'Content-Type: application/json' \
  -d '{"locations":[{"type":"MLFLOW_EXPERIMENT","mlflow_experiment":{"experiment_id":"1"}}],"max_results":5}' \
  | python3 -m json.tool
```

An empty response is the expected result until conversation tracing is enabled
and a turn is run. Enabling it is an ask-first action; see below.

## Deep links, never hand-built

Do not assemble a Grafana URL by hand; the format is version-specific and a
wrong one loads a page that shows the wrong thing. Use the script, which records
the verified format for the pinned Grafana:

```bash
./scripts/deeplink.sh dashboard --var agent=claude-code --from now-24h --to now
./scripts/deeplink.sh metrics 'sum by (type) (last_over_time(claude_code_token_usage_tokens_total[24h]))'
./scripts/deeplink.sh logs '{service_name="claude-code", git_repo="agent-observability"}'
./scripts/deeplink.sh trace 0123456789abcdef0123456789abcdef
```

Each prints one clickable URL. An MCP-capable agent can instead call the
server's `generate_deeplink` tool, which produces the same format.

## Typed tools are available, but not required

`.mcp.json` at the repository root wires an MCP-capable agent to the Grafana MCP
server through the same port, with no token to paste. It offers read-only tools
for search, datasources, dashboards, Prometheus metrics, Loki logs, and link
generation. Every question those tools answer is also answerable by a shell
command above, so an agent without MCP support is never locked out.

## Privacy rules, not suggestions

Telemetry on this stack contains prompt and response content in plaintext, and
the log streams carry user identity fields. Expanding a single Loki log line
reveals the stream's full label set, which includes `user_email` and the other
identity fields `user_id`, `user_account_id`, `user_account_uuid`, and
`organization_id`. The full privacy posture, what is stored, where, what is off
by default, and how to delete it, is stated once in the
[README privacy section](README.md#privacy); the rules below are the agent-facing
subset.

* Never place identity fields or conversation content into a shared or public
  destination: a commit message, an issue, a pull request, a chat channel, a
  pasted transcript, or any file that leaves the machine.
* Prefer handing the user a link over quoting conversation content back. A
  `deeplink.sh` URL lets the user open the exact view themselves, so you do not
  have to reproduce their prompts or the assistant responses in your answer.
* When you must report a value, report the aggregate (a cost, a token count, a
  session count), not the content or the identity that produced it.

## Ask the user first before any of these

* Starting or stopping the stack (`docker compose up`, `down`, or `down -v`).
  `down -v` deletes all stored telemetry.
* Modifying the provisioned Grafana dashboard. It is provisioned from a
  committed file and a manual edit drifts from source.
* Enabling conversation tracing on the user's behalf
  (`scripts/mlflow.autolog.claude.sh enable`). It records full conversations to
  MLflow, which is a privacy decision that is the user's to make.
