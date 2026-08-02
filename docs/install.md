<!-- Purpose: the first-run document. It carries the reader from a fresh clone to a
     running, verified stack: what Docker version is needed, the recommended
     agent-driven install, the manual equivalent for a reader who wants no agent
     touching their configuration, how to move the single published port, and how
     to fill every view with synthetic data before wiring anything real.
     @agents-index: Install document: prerequisites, the agent-driven install, the manual install, the EDGE_PORT change, and the demo seed that populates every view. -->

# Install

[Back to the front page](../README.md)

## Prerequisites

Docker is the only prerequisite for a user. You need Docker with the Docker
Compose v2 plugin, which you invoke as `docker compose`. The legacy
`docker-compose` v1 script does not work: the compose file uses the Compose
Specification, including a top-level project `name` and long-form `depends_on`
conditions, which only v2 provides. Check your version:

```bash
docker compose version
```

The first start pulls roughly 1 GB of images and builds one thin MLflow image,
so you need network access on the first run only.

Regenerating the screenshots and the walkthrough additionally needs
[`agent-browser`](https://www.npmjs.com/package/@earendil-works/agent-browser)
and [`ffmpeg`](https://ffmpeg.org/). Both are maintainer tooling for the capture
scripts under `scripts/`, and neither is needed to run the stack or to wire an
agent. See [contributing](contributing.md#regenerating-the-visual-artifacts).

## Install, the recommended way

The recommended way to install is to let your own coding agent do it. After you
clone this repository, point your agent at the installation instruction. The
agent checks the prerequisites, offers to start the stack and asks first,
verifies the stack, shows you a plan of every change, asks once, configures your
agent, and then proves the result by running one turn and confirming the data
arrived. It edits only the files in the plan, backs up each settings file before
it writes, and never turns on the recording of your prompts unless you choose it.
This path carries the machine from a fresh clone to verified telemetry.

Run the entry point for your agent:

* **Claude Code:** run the slash command `/observability-install`.
* **pi:** run the prompt template `/observability-install`.
* **Any other capable agent:** paste this sentence to it:

  > Read `skills/observability-install/SKILL.md` in this repository and follow it
  > to install the observability stack and wire this agent into it, asking me
  > before any change.

The instruction lives in one readable file,
[`skills/observability-install/SKILL.md`](../skills/observability-install/SKILL.md).
Open it to see exactly what the agent will do, what it will ask, and what it will
not do, before you run it. To reverse the install, run `/observability-uninstall`
in Claude Code or pi, which removes only the keys the install added and restores
any value it replaced.

## Install by hand

If you have no coding agent, or a policy against letting one change your
configuration, every step above has a manual equivalent. This path is for you.

Start the whole stack from the repository root:

```console
$ docker compose up -d
```

The default port needs no `.env` file. To start the stack and block until every
service answers, use the wrapper instead, so a script can depend on a ready
stack:

```bash
./scripts/stack.up.sh
```

Confirm the stack is healthy from the outside:

```bash
./scripts/stack.verify.sh
```

The script asserts that exactly one host port is published and bound to
loopback, that every readiness endpoint answers, that the three Grafana
datasources report healthy, and that no image tag floats. It exits non-zero on
the first failure and names the fix.

The edge proxy publishes port `24317` on `127.0.0.1` by default. If another
program already uses that port, set a free one in a single place. Copy the
template and edit one value:

```console
$ cp .env.example .env
```

Edit `.env`, set `EDGE_PORT` to a free port, and the stack reads it on the next
start. No other file changes. Every address in this documentation uses `24317`;
if you set `EDGE_PORT`, use your port instead.

To wire an agent by hand, set the telemetry keys the install skill documents.
Claude Code reads them from a settings `env` block; the temporality key is not
optional, and the pi extension defaults to port 4317 rather than the edge port.
The [`skills/observability-install/SKILL.md`](../skills/observability-install/SKILL.md)
file lists every key and every value, and the
[troubleshooting table](troubleshooting.md) covers the two failures those two
facts cause.

## Turn on conversation tracing, optional and off by default

Metrics and logs flow the moment an agent is wired. The MLflow conversation view,
which shows a whole session turn by turn, is a separate opt-in because it stores
the whole conversation: every prompt, every assistant response, and every tool
input and output, in plaintext in the `mlflow-data` volume. Starting the stack
never turns it on. Enable it per agent, each script states what it stores and
where and asks before it writes anything:

* **Claude Code:** `scripts/mlflow.autolog.claude.sh` enables it; it writes to
  the `claude-code` experiment.
* **pi:** `scripts/mlflow.tracing.pi.sh` enables it; it writes to the `pi`
  experiment through the `@desek/pi-mlflow-tracing` extension. By default the
  destination is the local stack, derived from the edge port, so nothing leaves
  the machine. To send conversations to a tracking server elsewhere, pass
  `--endpoint URL` (and `--tracking-uri URL` for the REST address); a
  non-loopback destination is named in the disclosure. Disable and reverse the
  change with `scripts/mlflow.tracing.pi.sh --disable`.

The [privacy document](privacy.md) states what each path stores and how to delete
stored conversations.

## See it populated, without wiring anything

A freshly started stack shows empty panels, and empty panels do not tell you
whether the stack works. One script fills every view with plausible, obviously
synthetic telemetry so you can see the whole product within a minute of cloning:

```bash
./scripts/demo.seed.sh
```

Open the dashboard at `http://localhost:24317/d/agent-observability` and every
row is populated. Every seeded series and stream carries the marker
`git_org="demo-seed"`, so you can always tell demo data from your own. When you
are done, clear it:

```bash
./scripts/demo.seed.sh --clear
```

The clear path resets the seeded metric series to zero and removes the seeded
MLflow conversation, leaving any real telemetry untouched. It names
`docker compose down -v` as the only way to wipe every store completely.

## Next

* [Read your data](reading-data.md), the dashboard, the query recipes, and the
  conversation view.
* [Privacy](privacy.md), what is stored and what never leaves the machine.
* [Troubleshooting](troubleshooting.md), when a panel stays empty.
