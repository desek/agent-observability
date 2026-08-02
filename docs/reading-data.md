<!-- Purpose: the document a reader opens once the stack holds data. It names the
     four ways to read that data, the provisioned dashboard, the query recipes and
     the deep links, the conversation view in MLflow, and the typed tools an agent
     uses, and gives the verification command for each.
     @agents-index: Reading document: the provisioned dashboard, the query recipes and deep links, the MLflow conversation view, and how an agent reads the stack over shell or MCP. -->

# Read your data

[Back to the front page](../README.md)

## The dashboard

The stack ships one provisioned dashboard, **Coding Agent Observability**, at the
stable identifier `agent-observability`. It appears in Grafana automatically on
start, with no import step:

```
http://localhost:24317/d/agent-observability
```

It covers all three signals for both agents: cost, token, session, and
active-time stats from Mimir; the readable conversation and tool log stream from
Loki; and the trace list from Tempo. Template variables narrow every panel by
agent, repository, branch, and model. No panel displays a user identity label,
so the dashboard is safe to share. It is provisioned read-only from
`stack/grafana/dashboards/agent-observability.json`, so that committed file is
the source of truth. To prove every panel executes against its datasource, run:

```bash
./scripts/dashboard.verify.sh
```

## The query recipes

The address of every backend, the real metric names, and a worked query for
Mimir, Loki, Tempo, and MLflow live in [`AGENTS.md`](../AGENTS.md), which is
written to be copied into the repository you actually work in. A useful answer
ends in a link the reader can click, and that link format is easy to get subtly
wrong, so it lives in one script rather than in prose:

```bash
./scripts/deeplink.sh --self-check
```

`scripts/deeplink.sh` builds the four link kinds (dashboard, metrics, logs, and
trace) and its self-check asserts each one still resolves, so a Grafana upgrade
that changes the format fails a check rather than silently pointing at the wrong
view.

## The conversation view

MLflow answers the one question the log queries answer badly: what happened in a
single session, turn by turn. A session becomes a trace, each turn and tool call
becomes a span carrying its input and output, and the MLflow interface renders it
as a conversation with tokens, cost, and latency attached. It is reached through
the single port under `/mlflow/`:

```
http://localhost:24317/mlflow/
```

The stack provisions a `claude-code` experiment and a `pi` experiment the moment
MLflow reports healthy. Conversation tracing is off on both paths until you turn
it on, and each enable script names what it changes, states what gets stored, and
asks before it writes:

* **Claude Code:** `scripts/mlflow.autolog.claude.sh`, writing to the
  `claude-code` experiment.
* **pi:** `scripts/mlflow.tracing.pi.sh`, which installs the
  `@desek/pi-mlflow-tracing` extension's switch file, writing to the `pi`
  experiment. By default it sends to the local stack through the edge port;
  pass `--endpoint URL` (and `--tracking-uri URL`) to point it at a tracking
  server elsewhere.

The [privacy document](privacy.md) covers what tracing stores, how to send it
elsewhere, and how to remove it.

## How an agent reads them

[`AGENTS.md`](../AGENTS.md) teaches an agent the stack in prose, and `CLAUDE.md`
is a symbolic link to it, so Claude Code and any AGENTS.md-aware agent read the
same content. An MCP-capable agent can instead query the stack with typed,
read-only tools: the Grafana MCP server runs as one more internal service behind
the same single port and holds the Grafana login itself, so the example
[`.mcp.json`](../.mcp.json) at the repository root is copied verbatim with no
token to paste. Confirm it is reachable, read-only, and internal:

```bash
./scripts/mcp.verify.sh
```

## Next

* [Use cases](use-cases.md), what else to point at the same port.
* [Architecture](architecture.md), how the services fit together.
* [Privacy](privacy.md), before you share anything you read here.
