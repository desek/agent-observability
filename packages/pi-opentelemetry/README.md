<!--
@agents-index: Public README for @desek/pi-opentelemetry, the pi coding-agent
OpenTelemetry extension. Documents what it emits, how to install and enable it,
every configuration variable and its source-verified default, the operational
contract, a verification recipe, and a troubleshooting list for a reader who has
never seen this repository.
-->

# @desek/pi-opentelemetry

An OpenTelemetry extension for the [pi](https://github.com/earendil-works/pi)
coding agent. It instruments pi's lifecycle and exports all three OpenTelemetry
signals, metrics, log events, and traces, over OTLP gRPC to any OpenTelemetry
collector. The signal names and attributes match Claude Code's built-in
telemetry, with the `claude_code.` prefix replaced by `pi.`, so pi and Claude
Code stay distinguishable in one backend while remaining comparable.

The extension is safe to install anywhere. It emits nothing until you enable it,
it stays silent when no collector is reachable, and a telemetry fault can never
crash, block, or slow the agent. See [Operational contract](#operational-contract).

## Install

```bash
pi install npm:@desek/pi-opentelemetry
```

This registers the extension with pi. It stays dormant until you enable it.

### Peer dependency

The extension declares `@opentelemetry/api` as a peer dependency (range
`^1.9.0`). pi and most host environments already provide it. If your project
pins its own copy of `@opentelemetry/api`, keep it on a compatible version. Two
different copies of `@opentelemetry/api` in one process break instrumentation
registration silently, which looks like a broken collector rather than a
dependency clash. See [Troubleshooting](#troubleshooting).

## Enable

The extension is a hard no-op unless one of two conditions is met:

1. `PI_OTEL_ENABLE` is set to a truthy value (the explicit master switch), or
2. `PI_OTEL_ENABLE` is unset and the extension finds a target: either
   `OTEL_EXPORTER_OTLP_ENDPOINT` is set, or a local collector answers a health
   probe. This is the dynamic default. It lets a machine that runs a collector
   export with no configuration, while a machine that runs no collector stays
   silent.

The simplest explicit setup, exporting to a collector on the standard OTLP gRPC
port:

```bash
export PI_OTEL_ENABLE=1
pi -p "say hi"
```

By default the extension exports to `http://localhost:4317`, the standard OTLP
gRPC receiver address. A plain OpenTelemetry Collector, or Grafana Alloy with
its default `otelcol.receiver.otlp`, listens there, so no endpoint configuration
is needed for the common case.

### If you run the agent-observability edge-proxy stack

The companion observability stack does not publish the standard OTLP ports. It
fronts every backend behind a single edge port (default `24317`). A collector
behind a non-standard address is not found by the default endpoint or the health
probe, so installing the extension alongside that stack exports nothing until
you point it at the edge port:

```bash
export PI_OTEL_ENABLE=1
export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:24317
pi -p "say hi"
```

If you see no telemetry with the stack running, this is the first thing to
check. See [Troubleshooting](#troubleshooting).

## Operational contract

These four guarantees are what let you trust the extension in every pi session.
Each is enforced in `src/index.ts` and `src/config.env.ts`.

1. **Off by default.** The extension emits no signal and constructs no exporter
   unless its master switch `PI_OTEL_ENABLE` is truthy, or the health-gated
   dynamic default enables it.
2. **Silent when the collector is absent.** With neither the switch nor an
   endpoint set, the extension probes the collector and stays silent when the
   collector does not answer, so installing it on a machine without a stack costs
   nothing.
3. **Content is opt-in.** Every content-logging flag defaults to off. Prompts,
   responses, tool content, and raw request and response bodies are never
   exported unless you set the matching flag explicitly.
4. **It never breaks the agent.** An export failure, an unreachable collector,
   or a malformed configuration is swallowed. No telemetry fault raises into the
   agent, blocks a turn, or changes agent behaviour.

## Configuration variables

Every variable the extension reads, with its default and effect. Defaults are
taken from `src/config.env.ts` and `src/health.alloy.ts`.

### Switch and endpoint

| Variable | Default | Effect |
|----------|---------|--------|
| `PI_OTEL_ENABLE` | unset | Master switch. Truthy enables export, a false value (`0`, `false`, `no`, `off`, empty) disables it, unset defers to the dynamic default. |
| `OTEL_EXPORTER_OTLP_ENDPOINT` | `http://localhost:4317` | Shared OTLP endpoint for all signals. When set while `PI_OTEL_ENABLE` is unset, it also enables export without a health probe. |
| `OTEL_EXPORTER_OTLP_PROTOCOL` | `grpc` | Shared OTLP protocol for all signals. |
| `OTEL_EXPORTER_OTLP_HEADERS` | none | Comma-separated `key=value` headers applied to every exporter. |

### Per-signal exporter selection and overrides

| Variable | Default | Effect |
|----------|---------|--------|
| `OTEL_METRICS_EXPORTER` / `OTEL_LOGS_EXPORTER` / `OTEL_TRACES_EXPORTER` | `otlp` | `otlp` selects the OTLP gRPC exporter for that signal; `none` disables that signal. Any value other than `none` is treated as `otlp`. |
| `OTEL_EXPORTER_OTLP_{METRICS,LOGS,TRACES}_ENDPOINT` | shared endpoint | Per-signal endpoint override. |
| `OTEL_EXPORTER_OTLP_{METRICS,LOGS,TRACES}_PROTOCOL` | shared protocol | Per-signal protocol override. |
| `OTEL_METRIC_EXPORT_INTERVAL` | SDK default | Metric reader export interval, in milliseconds. |
| `OTEL_LOGS_EXPORT_INTERVAL` | SDK default | Log processor export interval, in milliseconds. |
| `OTEL_TRACES_EXPORT_INTERVAL` | SDK default | Span processor export interval, in milliseconds. |

### Resource identity

| Variable | Default | Effect |
|----------|---------|--------|
| `OTEL_SERVICE_NAME` | `pi-coding-agent` | `service.name` on the OpenTelemetry Resource. |
| `OTEL_RESOURCE_ATTRIBUTES` | none | Comma-separated `key=value` Resource attributes. The extension also derives git provenance (`git.org`, `git.repo`, `git.branch`, `git.path`) from the launch directory; values you set here win over the derived ones. |

### Content logging (default off)

Each flag is off unless set to a truthy value. See [Content logging and
privacy](#content-logging-and-privacy) for exactly what each records.

| Variable | Records |
|----------|---------|
| `OTEL_LOG_USER_PROMPTS` | The full user prompt text on `pi.user_prompt` events and interaction spans. |
| `OTEL_LOG_ASSISTANT_RESPONSES` | The full assistant response text on `pi.assistant_response` events. |
| `OTEL_LOG_TOOL_DETAILS` | Tool input and parameters on `pi.tool_result` events. |
| `OTEL_LOG_TOOL_CONTENT` | Tool input and output as span events on tool spans. |
| `OTEL_LOG_RAW_API_BODIES` | Raw provider request and response bodies on `pi.api_request_body` and `pi.api_response_body` events. |

### Metric-attribute cardinality (default off)

Each flag is off unless set to a truthy value. Enabling one adds a
high-cardinality attribute to metric series, which increases storage cost in the
backend.

| Variable | Adds |
|----------|------|
| `OTEL_METRICS_INCLUDE_SESSION_ID` | The session id as a metric attribute. |
| `OTEL_METRICS_INCLUDE_VERSION` | The pi version as a metric attribute. |
| `OTEL_METRICS_INCLUDE_ACCOUNT_UUID` | The account uuid as a metric attribute. |
| `OTEL_METRICS_INCLUDE_ENTRYPOINT` | The entrypoint as a metric attribute. |
| `OTEL_METRICS_INCLUDE_RESOURCE_ATTRIBUTES` | Resource attributes as metric attributes. |

## Content logging and privacy

Every content-logging flag is off by default, so out of the box no prompt,
response, tool content, or raw body ever leaves the process. When you enable a
flag, the content is exported over OTLP to whatever collector you configured and
is stored wherever that collector sends it. If your collector writes to a local
log store such as Loki, that content lands on disk on the machine that runs the
store. Enable these flags only when you understand where the content will be
kept and who can read it.

Non-content fields are always present when export is on: prompt length, response
length, model, token counts, cost, durations, and outcome flags. These carry no
prompt or response text.

## Emitted signal inventory

### Metrics (8 instruments, `pi.` namespace)

| Instrument | Kind | Attributes | Source lifecycle event |
|------------|------|------------|------------------------|
| `pi.session.count` | counter | `start_type` | `session_start` |
| `pi.token.usage` | counter | `type` (`input`/`output`/`cacheRead`/`cacheCreation`), `model` | `message_end` |
| `pi.cost.usage` | counter (USD) | `model` | `message_end` |
| `pi.lines_of_code.count` | counter | `type` (`added`/`removed`) | `tool_result` (edit/write) |
| `pi.code_edit_tool.decision` | counter | `decision`, `tool_name`, `language` | `tool_call`, `tool_result` |
| `pi.commit.count` | counter | none | `tool_result` (bash `git commit` heuristic) |
| `pi.pull_request.count` | counter | none | `tool_result` (bash `gh pr create` heuristic) |
| `pi.active_time.total` | counter (seconds) | none | turn/agent timing |

A Prometheus-compatible backend normalizes the OTel dot-names (dots to
underscores, a `_total` suffix on monotonic counters), for example
`pi_session_count_total`, `pi_token_usage_tokens_total`, `pi_cost_usage_total`.

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
omitted unless their opt-in flag is set.

### Spans (`pi.` namespace)

| Span | Parent | Source lifecycle event |
|------|--------|------------------------|
| `pi.interaction` | root (one per user prompt) | `agent_start` to `agent_end` |
| `pi.llm_request` | `pi.interaction` | provider-request start to `message_end` |
| `pi.tool` | `pi.interaction` | `tool_execution_start` to `tool_execution_end` |
| `pi.tool.execution` | `pi.tool` | execution portion of a tool call |

Spans carry `gen_ai.*` and `pi.*` attributes. The interaction prompt text is
gated by `OTEL_LOG_USER_PROMPTS`; tool input and output span events by
`OTEL_LOG_TOOL_CONTENT`.

## Verify it is exporting

Export is batched, so allow 15 to 30 seconds after the process exits before
querying. The extension force-flushes at the end of every agent loop and again
on session shutdown, so a headless one-shot delivers its signals reliably.

Drive one pi turn with telemetry enabled:

```bash
export PI_OTEL_ENABLE=1
# Set OTEL_EXPORTER_OTLP_ENDPOINT here if your collector is not on localhost:4317.
pi -p "Print the word telemetry and nothing else."
```

Then query your backend. The examples below assume a Grafana LGTM stack; adjust
the base URLs to your own collector's query APIs.

Metrics (Prometheus-compatible API):

```bash
curl -sG http://localhost:4317/prometheus/api/v1/query \
  --data-urlencode 'query=pi_token_usage_tokens_total' | jq '.data.result'
```

Log events (Loki):

```bash
curl -sG http://localhost:4317/loki/api/v1/query_range \
  --data-urlencode 'query={service_name="pi-coding-agent"}' | jq '.data.result | length'
```

Traces (Tempo):

```bash
curl -sG http://localhost:4317/tempo/api/search \
  --data-urlencode 'q={ resource.service.name = "pi-coding-agent" }' | jq '.traces | length'
```

A non-empty result for each signal confirms the extension is exporting. If the
query ports differ from the OTLP ingest port on your stack, use the query ports
your backend documents.

## Troubleshooting

The extension is installed and enabled but I see nothing.

- **The collector is not on the default endpoint.** The default is
  `http://localhost:4317`. If your collector listens elsewhere, set
  `OTEL_EXPORTER_OTLP_ENDPOINT`. This is the most common cause when running the
  agent-observability edge-proxy stack, which uses a single edge port (default
  `24317`) rather than the standard OTLP ports. Set
  `OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:24317`.
- **The dynamic default kept it off.** With `PI_OTEL_ENABLE` unset and no
  endpoint set, the extension probes a local collector at
  `http://localhost:12345/-/healthy` (Grafana Alloy's default health route) and
  stays off when nothing answers. Set `PI_OTEL_ENABLE=1` to force it on
  regardless of the probe.
- **A duplicate `@opentelemetry/api` in the process.** If two different copies
  of `@opentelemetry/api` are resolved in one process, instrumentation registers
  against one copy and the extension emits from another, so nothing arrives and
  no error is raised. This looks like a broken stack but is a dependency clash.
  Deduplicate the package (for example `npm dedupe`, or align your project's
  pinned version to the peer range `^1.9.0`) so a single copy is loaded.
- **A signal is disabled.** Check that `OTEL_METRICS_EXPORTER`,
  `OTEL_LOGS_EXPORTER`, or `OTEL_TRACES_EXPORTER` is not set to `none`.
- **You are querying too soon.** Export is batched. Wait 15 to 30 seconds after
  the process exits before querying.
- **You expected prompt or response text and see none.** Content logging is
  opt-in. Set the matching flag from
  [Content logging](#content-logging-and-privacy). The structural fields
  (lengths, models, counts, costs) are always present, so their presence with
  absent text means the content flag is simply off.

## License

Apache-2.0.
