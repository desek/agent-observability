<!--
@agents-index: Public README for @desek/pi-mlflow-tracing, the pi coding-agent
MLflow conversation-tracing extension. Documents what it records, how to switch
it on and off, where the conversation is stored, the operational contract, and
its safe-by-default posture, for a reader who has never seen this repository.
-->

# @desek/pi-mlflow-tracing

An MLflow conversation-tracing extension for the
[pi](https://github.com/earendil-works/pi) coding agent. It turns each pi agent
loop into an OpenTelemetry span tree and exports it to an MLflow tracking server,
so a pi session becomes readable turn by turn: a root span holds the prompt and
the final response, a child span holds each turn with its model and token counts,
and a child span holds each tool call under the turn that made it.

The extension is safe to install anywhere. It records nothing until you enable
it, it stays silent when no tracking server is reachable, and a telemetry fault
can never crash, block, or slow the agent. See
[Operational contract](#operational-contract).

## Install

```bash
pi install npm:@desek/pi-mlflow-tracing
```

This registers the extension with pi. It stays dormant until you enable it.

Install a version later than `0.0.1`. That first version was a one-time bootstrap
publish, needed only to create the package on the registry so trusted publishing
could name it, and it is the only version of this package published without build
provenance. Every version after it comes from the repository's release automation
and carries provenance, so a plain install (which takes the latest version) is
correct and only an explicit pin to `0.0.1` should be avoided.

## Enable

The extension is a hard no-op until you set its master switch. Enabling it is
always a deliberate act, because it records conversation content:

```bash
export PI_MLFLOW_ENABLE=1
pi -p "say hi"
```

With `PI_MLFLOW_ENABLE` unset, or set to a false value (`0`, `false`, `no`,
`off`, or empty), the extension registers no handler, constructs no exporter, and
opens no connection.

By default the export goes to this project's local observability stack, reached
through its single edge port, and lands in the `pi` experiment. A user who runs
that stack sets nothing but the switch. A user whose tracking server lives
elsewhere points the extension at it through the environment rather than a code
change.

## Disable

Unset the switch, and the extension is a no-op again on the next session:

```bash
unset PI_MLFLOW_ENABLE
```

## What it records

When enabled, every prompt, every assistant response, and every tool input and
result of the session is exported to the configured tracking server and stored
there until you delete it. This is the most sensitive data the extension
touches, which is why it is off by default and why the default destination is the
local machine.

Conversation content leaves the machine only if you configure a destination that
is not a loopback address. When you do, the extension names that destination once
at session start, so sending content off the machine is never silent.

## Operational contract

These guarantees are what let you trust the extension in every pi session.

1. **Off by default.** With the master switch unset the extension records
   nothing, constructs no exporter, and opens no connection.
2. **Silent when the server is absent.** With tracing enabled but no reachable
   tracking server, the extension stays silent rather than retrying into a dead
   endpoint, so installing it on a machine without a stack costs nothing.
3. **Content stays local by default.** The default destination is the local
   tracking server; a destination off the machine is a deliberate configuration
   and is named to you when it is used.
4. **It never breaks the agent.** An export failure, an unreachable server, or a
   malformed configuration is swallowed. No telemetry fault raises into the
   agent, blocks a turn, or changes agent behaviour.

## License

Apache-2.0.
