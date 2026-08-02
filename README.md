<!-- Purpose: front page of the repository, written as a landing page. It shows what
     the stack is, shows it working, states what you get and what it deliberately
     does not do, and points at the document that answers each next question. The
     detail lives under docs/, one document per question, so the front page stays
     a map rather than accreting into a manual.
     @agents-index: Repository front page as a landing page: what the stack is, the screenshots, what you get, the one-command start, the map of the documentation under docs/, and the boundaries. -->

# Agent Observability Stack

This project is a local-first observability stack for coding agents: one command
turns a fresh clone into a working telemetry plane that stores metrics, log
events, and traces on your machine and nowhere else. It answers what an agent
such as Claude Code or pi did, what it cost, how long it took, which tools it
called, and what it was asked. Any local application that speaks OpenTelemetry is
a workload here too, so the stack reads an agent and the service it is editing
side by side.

![The provisioned Coding Agent Observability dashboard showing populated panels across every row: cost, token, session, and active-time stats at the top, cost and token rates by model and type, per-repository cost, lines of code and tool decisions, commit and pull-request counts, the readable conversation and tool log stream, and the recent trace list.](docs/images/dashboard.png)

![A coding-agent conversation opened in the MLflow interface, showing the user turn, two assistant turns, and a tool call as spans, with the trace status, latency, and the git.org demo-seed tag.](docs/images/mlflow-conversation.png)

A short silent walkthrough of the working product, from the dashboard, into one
log line, and into one conversation in MLflow:

<video src="docs/images/walkthrough.mp4" controls muted playsinline width="100%"></video>

If the video does not play inline where you are reading this, open
[`docs/images/walkthrough.mp4`](docs/images/walkthrough.mp4) directly.

Every image and video in this repository is captured from a synthetic demo
dataset by `scripts/demo.seed.sh` and the capture scripts, so no real prompt and
no real identity ever appears in a committed picture.

## What you get

* A dashboard for both agents across all three signals: cost, tokens, sessions,
  active time, tool decisions, lines of code, commits, and pull requests, plus a
  readable conversation stream and a trace list.
* A readable conversation view in MLflow, where one agent session becomes a
  trace and each turn and tool call becomes a span with its tokens, cost, and
  latency.
* A single OpenTelemetry endpoint on one loopback port that accepts metrics,
  logs, and traces from any local sender, agent or application.
* Query recipes and clickable deep links that let a capable agent read the
  stored telemetry itself, over shell or over a read-only MCP server.
* A one-command demo mode that fills every view with synthetic data so you can
  see the stack working before you wire anything to it.

## Start it

Docker with the Compose v2 plugin is the only prerequisite. From the repository
root:

```console
$ docker compose up -d
```

Then fill every view with synthetic data and open the dashboard at
`http://localhost:24317/d/agent-observability`. The recommended install instead
lets your own coding agent do the whole thing, including wiring the agent to the
stack and proving telemetry arrived. Both paths, and the port change when `24317`
is taken, are in [Install](docs/install.md).

## Documentation

The front page is a map. Each document below answers one question and is the
single home for its answer.

| Document | Answers |
|----------|---------|
| [Install](docs/install.md) | What do I need, how do I start it, how do I wire my agent, and how do I see it populated before wiring anything? |
| [Read your data](docs/reading-data.md) | Where is the dashboard, how do I query the stores, where is the conversation view, and how does an agent read them itself? |
| [Privacy](docs/privacy.md) | What is stored, what leaves the machine, what is off by default, and how do I redact or delete it? |
| [Other things to point at it](docs/use-cases.md) | What else can send here, how do I use the agent instruction file in my own project, and where does the pi extension fit? |
| [How it fits together](docs/architecture.md) | Which services run, what does the single port route to, which versions are pinned, and what survives a teardown? |
| [Troubleshooting](docs/troubleshooting.md) | It is not working. What is the cause and what is the fix? |
| [Contributing](docs/contributing.md) | What does `make ci` check, where does a file belong, and how are the screenshots regenerated? |

Two files at the repository root are read rather than run:
[`AGENTS.md`](AGENTS.md) teaches an agent this stack in prose and is written to be
copied into the repository you actually work in, and [`.mcp.json`](.mcp.json)
gives an MCP-capable agent read-only typed tools with no token to paste.

Read [Privacy](docs/privacy.md) before you run the stack. Telemetry here is
stored in plaintext on your machine, and that document is the single, complete
statement of what that means.

## What this is not

* It is a single-user local stack, not a multi-tenant deployment.
* It has no alerting.
* It has no retention policy: data stays until you delete it.
* Conversation tracing covers Claude Code only, not pi.
* It is not a hosted service, and it publishes only a loopback port.

A reader who needs any of those learns it here in ten seconds instead of an hour.

## License

This project is licensed under the Apache License 2.0. See [`LICENSE`](LICENSE).
