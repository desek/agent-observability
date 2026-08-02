<!--
@agents-index: Operator and reviewer documentation for the in-repo pi-opentelemetry pi
extension — the complete emitted signal inventory (metrics, events, spans), the
configuration variables that govern it, and the headless verification recipe used
to prove Claude Code telemetry parity against the local Grafana stack.
-->

# pi pi-opentelemetry extension

An in-repo [pi](https://github.com/earendil-works/pi) extension that instruments
pi's lifecycle events and emits all three OpenTelemetry signals — metrics, log
events, and traces — with names and attributes at parity with Claude Code's
built-in telemetry, exported over **OTLP gRPC to the local HAProxy edge proxy on
`localhost:24317`** (the single-port frontend that fans out to the Grafana Alloy
receiver — the same transport and endpoint Claude Code uses).

pi-namespaced signal names drop Claude Code's `claude_code.` prefix in favour of
`pi.` so the two services stay distinguishable in one backend while preserving
structure and attributes. Both services share the `service.name` dimension
(`pi-coding-agent` vs `claude-code`) so they are comparable yet separable.

## How it is loaded

pi is wired to this extension through the `packages` array in `.pi/settings.json`,
which references this package as a local source:

```json
"packages": ["npm:pi-subagents", "npm:pi-mcp-adapter", "./packages/pi-opentelemetry"]
```

pi resolves local `packages` paths relative to the project config dir (`.pi/`). pi
then reads this package's `package.json` `pi.extensions`
manifest (`["./src/index.ts"]`) to discover the entry module. A path under the
top-level `extensions` key is likewise resolved against `.pi/` and only toggles the
enabled state of auto-discovered `.pi/extensions/*` entries, so it does not load a
package living at the repo root — use the `packages` reference above.

The third-party `npm:@the-agency/pi-observability` package (one span per turn,
OTLP HTTP 4318) has been removed; the existing `npm:pi-subagents` and
`npm:pi-mcp-adapter` packages are preserved.

Runtime dependencies (the OpenTelemetry JS SDK plus the three OTLP gRPC exporters)
are declared and pinned in `package.json` / `package-lock.json`. Run
`npm install` inside `packages/pi-opentelemetry/` so `node_modules/` is present;
that directory is gitignored. Unit tests run with `npm test`
(`node --experimental-strip-types --test 'src/*.test.ts'`).

## Master switch

The extension is a hard no-op — it initializes no exporter and emits no signal —
unless `PI_OTEL_ENABLE` is set to a truthy value. This mirrors Claude Code's
`CLAUDE_CODE_ENABLE_TELEMETRY`.

```bash
set -a && . observability/pi-otel.env && set +a   # OTLP gRPC via proxy :24317, service name
export PI_OTEL_ENABLE=1
pi -p "say hi"
```

The repository `.envrc` (direnv) additionally exports `OTEL_RESOURCE_ATTRIBUTES`
with git-provenance labels (`git.org`, `git.repo`, `git.branch`, `git.path`); run
`direnv allow` so the extension stamps pi telemetry with the same provenance that
Loki and Mimir promote for Claude Code.

## Emitted signal inventory

### Metrics (8 instruments, `pi.` namespace)

| Instrument | Kind | Attributes | Source lifecycle event |
|------------|------|------------|------------------------|
| `pi.session.count` | counter | `start_type` | `session_start` |
| `pi.token.usage` | counter | `type` (`input`/`output`/`cacheRead`/`cacheCreation`), `model` | `message_end` |
| `pi.cost.usage` | counter (USD) | `model` | `message_end` |
| `pi.lines_of_code.count` | counter | `type` (`added`/`removed`) | `tool_result` (edit/write) |
| `pi.code_edit_tool.decision` | counter | `decision`, `tool_name`, `language` | `tool_call`, `tool_result` |
| `pi.commit.count` | counter | — | `tool_result` (bash `git commit` heuristic) |
| `pi.pull_request.count` | counter | — | `tool_result` (bash `gh pr create` heuristic) |
| `pi.active_time.total` | counter (seconds) | — | turn/agent timing |

In Mimir the OTel dot-names are Prometheus-normalized (dots to underscores, a
`_total` suffix on monotonic counters), e.g. `pi_session_count_total`,
`pi_token_usage_tokens_total`, `pi_cost_usage_total`.

Metric-attribute cardinality is gated (default off when the variable is unset) by
`OTEL_METRICS_INCLUDE_SESSION_ID`, `_VERSION`, `_ACCOUNT_UUID`, `_ENTRYPOINT`, and
`_RESOURCE_ATTRIBUTES`.

### Log events (`pi.` namespace)

| Event | Content field (gating flag) | Source lifecycle event |
|-------|-----------------------------|------------------------|
| `pi.user_prompt` | `prompt` (`OTEL_LOG_USER_PROMPTS`); `prompt_length` always | `before_agent_start` |
| `pi.assistant_response` | `response` (`OTEL_LOG_ASSISTANT_RESPONSES`); `model`, `response_length` | `message_end` |
| `pi.tool_result` | `tool_input`/`tool_parameters` (`OTEL_LOG_TOOL_DETAILS`); `tool_name`, `success`, `duration_ms` | `tool_result` |
| `pi.api_request` | `model`, `cost_usd`, `duration_ms`, token counts, `response_id` | `message_end` |
| `pi.api_error` | `model`, `error`, `status_code`, `duration_ms` | `after_provider_response` |
| `pi.api_refusal` | `model`, `finish_reason` | `message_end` finish reason |
| `pi.tool_decision` | `tool_name`, `decision`, `source` | `tool_call` |
| `pi.api_request_body` | `body`/`body_ref` (`OTEL_LOG_RAW_API_BODIES`) | `before_provider_request` |
| `pi.api_response_body` | `body`/`body_ref` (`OTEL_LOG_RAW_API_BODIES`) | `after_provider_response` |
| `pi.compaction` | `trigger`, `success`, `pre_tokens`, `post_tokens` | `session_compact` |

All events carry `service.name = pi-coding-agent`. Content-bearing fields are
omitted unless their opt-in flag is set. `observability/alloy/config.alloy`
rewrites these `pi.<event>` bodies into human-readable one-line summaries in Loki
(e.g. `[api_request] model=... in=... out=...`) at parity with the
`claude_code.*` transform, while all original attributes remain queryable as
structured metadata.

### Spans (`pi.` namespace)

| Span | Parent | Source lifecycle event |
|------|--------|------------------------|
| `pi.interaction` | root (one per user prompt) | `agent_start` to `agent_end` |
| `pi.llm_request` | `pi.interaction` | provider-request start to `message_end` |
| `pi.tool` | `pi.interaction` | `tool_execution_start` to `tool_execution_end` |
| `pi.tool.execution` | `pi.tool` | execution portion of a tool call |

Spans carry `gen_ai.*` and `pi.*` attributes. The interaction prompt text is
gated by `OTEL_LOG_USER_PROMPTS`; tool input/output span events by
`OTEL_LOG_TOOL_CONTENT`.

## Configuration variables

| Variable | Behaviour |
|----------|-----------|
| `PI_OTEL_ENABLE` | Master switch; extension no-ops unless truthy |
| `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` / `OTEL_TRACES_EXPORTER` | `otlp` (default) selects the OTLP gRPC exporter; `none` disables that signal |
| `OTEL_EXPORTER_OTLP_PROTOCOL` / `OTEL_EXPORTER_OTLP_ENDPOINT` / `OTEL_EXPORTER_OTLP_HEADERS` | Honoured; default `grpc` and `http://localhost:24317` (the HAProxy edge proxy) |
| `OTEL_EXPORTER_OTLP_{METRICS,LOGS,TRACES}_{ENDPOINT,PROTOCOL}` | Per-signal overrides |
| `OTEL_METRIC_EXPORT_INTERVAL` / `OTEL_LOGS_EXPORT_INTERVAL` / `OTEL_TRACES_EXPORT_INTERVAL` | Export intervals on the respective reader/processor |
| `OTEL_SERVICE_NAME` / `OTEL_RESOURCE_ATTRIBUTES` | Applied to the OTel `Resource` (service name default `pi-coding-agent`) |
| `OTEL_LOG_USER_PROMPTS` / `OTEL_LOG_ASSISTANT_RESPONSES` / `OTEL_LOG_TOOL_DETAILS` / `OTEL_LOG_TOOL_CONTENT` / `OTEL_LOG_RAW_API_BODIES` | Content gates (default off when unset) |
| `OTEL_METRICS_INCLUDE_SESSION_ID` / `_VERSION` / `_ACCOUNT_UUID` / `_ENTRYPOINT` / `_RESOURCE_ATTRIBUTES` | Metric-attribute cardinality gates (default off when unset) |

## Headless verification (parity against Claude Code)

OTLP export is batched, so allow 15 to 30 seconds after the process exits before
querying (the extension also flushes on `session_shutdown`). The backend query
APIs below are reached through the single HAProxy port `http://localhost:24317`
: Mimir under `/prometheus`, Loki under `/loki`, Tempo under `/tempo`
(the `/tempo` prefix is stripped by the proxy). Confirm the routing against
`observability/haproxy/haproxy.cfg`.

Drive pi once with the extension loaded and telemetry enabled:

```bash
set -a && . observability/pi-otel.env && set +a
export PI_OTEL_ENABLE=1
pi -p "Print the word telemetry and nothing else."
```

**Metrics in Mimir:**

```bash
curl -sG http://localhost:24317/prometheus/api/v1/query \
  --data-urlencode 'query=pi_token_usage_tokens_total' | jq '.data.result'
```

**Events/logs in Loki:**

```bash
curl -sG http://localhost:24317/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="pi-coding-agent"}' | jq '.data.result | length'
```

**Traces in Tempo:**

```bash
curl -sG http://localhost:24317/tempo/api/search \
  --data-urlencode 'q={ resource.service.name = "pi-coding-agent" }' | jq '.traces | length'
```

Then drive Claude Code the same way and diff the two inventories service by
service against the Parity Matrix:

```bash
claude -p "Print the word telemetry and nothing else."
```

Compare `pi_*` counters against their `claude_code_*` counterparts in Mimir,
`{service_name="pi-coding-agent"}` against `{service_name="claude-code"}` in Loki,
and `{ resource.service.name = "pi-coding-agent" }` against the claude-code
equivalent in Tempo. Every non-N/A Parity Matrix signal should have an observable
pi equivalent, including the git-provenance labels (`git_branch`, `git_repo`, …)
the extension stamps via `OTEL_RESOURCE_ATTRIBUTES`.
