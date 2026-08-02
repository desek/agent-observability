<!-- Purpose: the single, complete statement of the project's privacy posture. Every
     other document in this repository links here rather than restating it, so the
     posture cannot drift into two versions that disagree. It states what is
     stored and where, what leaves the machine, what is off by default, how to
     redact one field, and how to delete data already stored.
     @agents-index: The single statement of the privacy posture: what is stored, what never leaves the machine, what is off by default, how to redact a field, and how to delete stored data. -->

# Privacy

[Back to the front page](../README.md)

Read this document before you run the stack.

## What is stored, and where

The stack stores metrics, log events, and traces in local named volumes
(`loki-data`, `mimir-data`, `tempo-data`, `alloy-data`, `grafana-data`, and
`mlflow-data`). Content logging is enabled by default for this local posture: the
`agents/pi-otel.env` file turns on every content flag, so your agent prompts, the
assistant responses, and tool input and output are stored in plaintext in those
volumes. The log streams also carry user identity fields; expanding a single Loki
log line reveals the stream's full label set, which includes `user_email` and the
identity fields `user_id`, `user_account_id`, `user_account_uuid`, and
`organization_id`.

## What leaves the machine

Nothing. Every service binds to the internal network. Only the edge proxy
publishes a port, and it binds to `127.0.0.1` only. That loopback binding is the
load-bearing privacy control of the whole project. Do not change it to a routable
address; if you do, anyone on that network can read your prompt and tool content.

## What is off by default

Conversation tracing to MLflow is off until you enable it, on both agent paths.
Starting the stack never turns either on.

* **Claude Code:** enable with `scripts/mlflow.autolog.claude.sh`. It writes to
  the `claude-code` experiment.
* **pi:** enable with `scripts/mlflow.tracing.pi.sh`, which installs the
  `@desek/pi-mlflow-tracing` extension's switch file. It writes to the `pi`
  experiment.

When enabled, either path stores the whole conversation: every prompt, every
assistant response, and every tool input and output, in plaintext in the
`mlflow-data` volume. That is the purpose of the feature. pi tracing is driven by
its master switch `PI_MLFLOW_ENABLE`; with the switch unset the extension
registers nothing and opens no connection.

By default pi tracing sends its conversation to the local stack through the
loopback edge port, so nothing leaves the machine. To send it to a tracking
server elsewhere, point the endpoint at that server. The enable script takes
`--endpoint URL` (and `--tracking-uri URL` for the REST address), or set the
`PI_MLFLOW_ENDPOINT` and `PI_MLFLOW_TRACKING_URI` environment variables. A
configured non-loopback destination means conversation content leaves this
machine, so the extension names that destination once at session start and the
enable script names it in its disclosure.

## How to redact a field

Set its flag to `0` in `agents/pi-otel.env`, then restart the agent. Each edit
redacts one field:

| Edit in `agents/pi-otel.env` | Redacts |
|------------------------------|---------|
| `OTEL_LOG_USER_PROMPTS=0` | Your prompts to the agent. |
| `OTEL_LOG_ASSISTANT_RESPONSES=0` | The assistant responses. |
| `OTEL_LOG_TOOL_DETAILS=0` | The tool names and arguments. |
| `OTEL_LOG_TOOL_CONTENT=0` | The tool input and output content. |
| `OTEL_LOG_RAW_API_BODIES=0` | The raw API request and response bodies. |

## How to delete stored data

Redacting a flag changes only what new telemetry carries; data already in the
volumes is unchanged. To delete every conversation already stored in the
`claude-code` experiment (Claude Code) or the `pi` experiment (pi), call the
tracking server's delete-traces API against that experiment. To stop pi from
recording any further conversation, disable its tracing with
`scripts/mlflow.tracing.pi.sh --disable`, which removes the switch file and
reverses the change. To discard all stored telemetry together, tear the stack
down with `docker compose down -v`, which removes every named volume:

```console
$ docker compose down -v
```

This is the single, complete statement of the project's privacy posture. Every
other document links here rather than restating it.
