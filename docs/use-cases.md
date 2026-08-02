<!-- Purpose: the document that widens the coding-agent framing. It states what else
     a reader can point at the same single port, what the stack does not collect
     and why, how to adopt the agent instruction file in another repository, and
     where the pi telemetry extension fits.
     @agents-index: Use-cases document: any local OpenTelemetry application as a workload, the agent-and-application view, learning observability, adopting AGENTS.md elsewhere, and the pi telemetry extension. -->

# Other things to point at it

[Back to the front page](../README.md)

The coding-agent framing is the headline, but what runs here is a general local
telemetry plane, and the agents are one workload on it. The same single port and
the same stores serve more:

* **Any local application that exports OpenTelemetry.** This works today and
  needs no change to the stack. An application points its exporter at the same
  single port, in any language, and its metrics, log events, and traces land in
  the same stores as the agent telemetry, queryable side by side. Set the
  standard exporter variables and give the service a distinct name, so its
  telemetry is easy to select apart from every other sender:

  ```console
  $ export OTEL_EXPORTER_OTLP_ENDPOINT=http://localhost:24317
  $ export OTEL_EXPORTER_OTLP_PROTOCOL=grpc
  $ export OTEL_SERVICE_NAME=my-billing-api
  # then start your instrumented application as usual
  ```

  The distinct-service-name convention is the one rule that makes the data
  useful: give each application its own `OTEL_SERVICE_NAME`, so a query for
  `{service_name="my-billing-api"}` returns that service and nothing else.

* **A single view across an agent and the application it is working on.** This is
  the combination the stack is unusually good at. A user debugging a local
  service while an agent edits it sees both in one place, correlated by time, and
  an agent taught the query recipes reads the application's own telemetry rather
  than guessing from source.

* **Learning observability with a laboratory that costs one command.** Metrics,
  logs, and traces, with a real collector, real storage, and real query
  languages, running locally with no account and no bill. A person or an agent
  can learn what a trace is by producing one, and the demo seed exists for
  exactly this.

Telemetry reaches the stack because an application sends it. Container standard
output is not collected automatically: a service that writes to stdout but does
not export OpenTelemetry produces nothing here. Collecting container logs would
need Docker service discovery and a container log source in the collector, which
is a change to the pipeline and is deliberately out of scope.

## Use it in your own project

`AGENTS.md` is written to be copied into the repository you actually work in.
Copy it, then change only the repository name in its example queries (the
`git_repo="agent-observability"` filter) to your own. Every address in it is
derived from `EDGE_PORT`, so nothing else changes when you copy it or move the
stack to another port. Place `.mcp.json` at that project's root to share the
read-only Grafana tools with everyone who clones it, or add its `grafana` entry
to your agent's user-scope configuration for the whole machine.

## The pi telemetry extension

The stack renders pi's signals, but pi emits none on its own. The
`@desek/pi-opentelemetry` package exports pi's metrics, log events, and traces
over OTLP at parity with Claude Code's built-in telemetry. It lives at
`packages/pi-opentelemetry/` and is published to npm; its own
[README](../packages/pi-opentelemetry/README.md) is the full reference for every
configuration variable and every emitted signal, and the posture that governs
what it records is stated in the [privacy document](privacy.md).

## Next

* [Read your data](reading-data.md), once a second sender is exporting.
* [Architecture](architecture.md), what the single port routes to.
