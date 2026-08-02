---
name: observability-install
description: Install this repository's local coding-agent observability stack and wire the user's own coding agent into it, from a fresh clone to verified working telemetry. Use when a user asks their agent to "install observability", "set up telemetry", "wire me into the stack", or run the /observability-install entry point. Checks prerequisites, offers to start the stack, verifies it, configures Claude Code or pi with consent, then proves the result with one real turn. Also holds the uninstall path.
---

# Install the observability stack and wire this agent into it

You are installing a local telemetry stack for a coding agent, then wiring the
user's own agent into it. You take the machine from a fresh clone to telemetry
you have seen arrive. You call this repository's scripts for every step that must
not vary. You change nothing until the user agrees to a plan.

Read the whole skill before you act. The user may open this file to see what you
will do, so keep to what it says.

## The rules that bind you

These rules hold for every step. Do not break one to finish faster.

* You MUST NOT change any file that is not named in the plan the user accepted.
* You MUST NOT write any change before the user accepts the plan.
* You MUST back up a settings file before you write to it. You MUST validate the
  file after you write it. You MUST restore the backup if validation fails.
* You MUST merge new keys into an existing settings file. You MUST NOT replace
  the file or its `env` block.
* You MUST NOT enable content logging unless the user makes that choice
  explicitly. Content logging is off by default.
* You MUST NOT overwrite an existing value without showing the user that value
  first and asking.
* You MUST NOT ask before you start or stop the stack. You MUST ask first.
* You MUST NOT report success before you have seen a metric, a log, and a trace
  arrive in the stack.
* You MUST call a repository script for a step when one exists. Do not improvise
  an equivalent.
* When you cannot finish a step, you MUST name the manual command that does the
  same thing, so the user is never stuck.

## Step 1: Resolve the port and find the repository

Every address in this stack comes from one port. Resolve it once.

* Read `EDGE_PORT` from the shell environment first. If it is not set, read the
  `EDGE_PORT` line from the repository's `.env` file. If neither is set, the
  port is `24317`.
* Build the base address as `http://localhost:<EDGE_PORT>`. Never write a literal
  port into a settings file or a command. Always derive it from `EDGE_PORT`.

Run this skill from the root of this repository, or from the project the user
wants to configure. Find the repository root so you can call its scripts by path.

## Step 2: Detect the situation

Work out the situation before you propose anything. Do not change a thing in this
step.

Determine each of these:

* **The container runtime.** Run `docker compose version`. A working Compose v2
  plugin answers with a version. If the command is missing or fails, stop here.
  See Step 3.
* **Which agent you are.** You are Claude Code or pi, or another agent. If you do
  not know, ask the user which agent to configure.
* **The scope.** Ask whether the user wants to configure this project only, or
  the whole machine. Prefer the project scope. See Step 6 for why.
* **Whether the stack is running.** Query the readiness of the stack through the
  port. See Step 5.
* **Whether telemetry is already configured**, and whether it points somewhere
  else. Read the settings the agent already has. See Step 6.

## Step 3: The prerequisite gate

If `docker compose version` did not answer, stop before you propose any plan. Do
not show the user a raw runtime error alone.

Tell the user plainly:

* A container runtime with the Docker Compose v2 plugin is required.
* Install Docker Desktop, or Docker Engine with the `docker-compose-plugin`
  package. The legacy `docker-compose` v1 script does not work.
* After they install it, they run `docker compose version` to confirm, then run
  this path again.

Do not try to install the runtime yourself. That is out of scope.

## Step 4: Offer to start the stack

Check whether the stack is running. Query `http://localhost:<EDGE_PORT>/api/health`.
A running stack answers 200.

If the stack is not running:

* Tell the user the stack is down and that you can start it.
* Tell them the first start pulls about 1 GB of images and needs network access
  once.
* Ask before you start it. You MUST ask.
* When the user agrees, start it by calling the repository's start script:

  ```bash
  ./scripts/stack.up.sh
  ```

  The script blocks until every service answers. Do not run `docker compose up`
  by hand instead; the script waits for readiness and names the port fix on a
  bind failure.
* If the user declines, stop and say what you skipped.

## Step 5: Verify the stack

Before you configure any agent, verify the stack. Never wire an agent to a stack
that is not working. Call the repository's verification script:

```bash
./scripts/stack.verify.sh
```

It exits non-zero and names the fix on the first failure. If it fails, stop,
show the user the failure, and do not configure anything until the stack passes.

## Step 6: Build the plan

Now build a plan. Show it to the user in full. Change nothing yet.

### Which settings file, for Claude Code

Claude Code reads settings in a fixed order, highest precedence first:

1. a managed policy file,
2. command line arguments,
3. `.claude/settings.local.json` in the project,
4. `.claude/settings.json` in the project,
5. the user's global `~/.claude/settings.json`.

The `env` block merges across these levels. A higher level overrides one key and
leaves the rest.

Three rules follow, and you MUST keep all three:

* **Prefer the least intrusive scope that works.** Write to the project file
  `.claude/settings.json`, or the local file `.claude/settings.local.json`. Do
  not write to the user's global `~/.claude/settings.json` unless the user picks
  machine-wide scope on purpose.
* **Find the level that governs each key before you write it.** Read every level.
  If a higher level already pins `OTEL_EXPORTER_OTLP_ENDPOINT`, a value you write
  lower down has no effect. Report which level holds that key and what value it
  holds. Ask the user how to resolve it. Do not write a value that will not take
  effect. A shell environment variable does not win over a settings file that
  pins the same key, so do not rely on one to redirect the agent.
* **Add keys to the `env` block. Do not replace the block.** The block merges, so
  add your keys next to the ones already there.

### The keys for Claude Code

Plan to add these keys to the `env` block of the chosen settings file. Derive the
endpoint from `EDGE_PORT`:

* `CLAUDE_CODE_ENABLE_TELEMETRY` = `1`
* `OTEL_METRICS_EXPORTER` = `otlp`
* `OTEL_LOGS_EXPORTER` = `otlp`
* `OTEL_TRACES_EXPORTER` = `otlp`
* `OTEL_EXPORTER_OTLP_PROTOCOL` = `grpc`
* `OTEL_EXPORTER_OTLP_ENDPOINT` = `http://localhost:<EDGE_PORT>`
* `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` = `cumulative`

The temporality key is not optional. Without it the metrics store rejects every
counter, and metrics vanish while logs and traces still arrive. You MUST include
it.

For a responsive local feedback loop you may also set short export intervals:
`OTEL_METRIC_EXPORT_INTERVAL`, `OTEL_LOGS_EXPORT_INTERVAL`, and
`OTEL_TRACES_EXPORT_INTERVAL`, each `1000`. A short interval also lets a single
non-interactive turn flush its signals before the process exits.

### The keys for pi

pi needs a package, a master switch, and an endpoint. Plan to:

* Install the published extension by its registry specifier:

  ```bash
  pi install npm:@desek/pi-opentelemetry
  ```

* Set the master switch `PI_OTEL_ENABLE` = `1`.
* Set `OTEL_EXPORTER_OTLP_ENDPOINT` = `http://localhost:<EDGE_PORT>`. The package
  defaults to the OpenTelemetry standard port 4317, not this stack's edge port,
  so you MUST point it at the edge port.
* The repository ships `agents/pi-otel.env` with the opt-in content and
  cardinality flags. Sourcing it turns content logging on. Treat it as the
  content-logging choice in the plan below, not as a default.

### The Grafana tools configuration

The repository ships `.mcp.json` at its root. It configures the read-only Grafana
MCP server for an agent, and it needs no token. Plan to place it at the chosen
scope: copy it to the project root for a project, or add its `grafana` entry to
the agent's user-scope MCP configuration for the whole machine.

### Content logging is a separate choice

Present content logging as its own question. State the consequence: with content
logging on, the stack records prompts, responses, and tool input and output. The
pipeline binds to localhost only. Default it to off. If the user does not choose
it, leave it off.

When the user chooses content logging on:

* For Claude Code, write the content flags to `.claude/settings.local.json`, which
  Claude Code keeps out of version control. You MUST NOT write a content flag into
  a committed `.claude/settings.json`, because that would record other people's
  prompts by inheritance. The flags are `OTEL_LOG_USER_PROMPTS`,
  `OTEL_LOG_ASSISTANT_RESPONSES`, `OTEL_LOG_TOOL_DETAILS`, and
  `OTEL_LOG_TOOL_CONTENT`, each `1`.
* For pi, source `agents/pi-otel.env` in the environment that launches pi.

### Show the plan and ask once

Show the user, in one plan:

* every file you will change, by path,
* every key you will add or change, with its value,
* every existing value you will replace, shown as it stands now,
* the content-logging choice and its consequence,
* the optional steps from Step 8.

Ask the user to accept the plan whole. Do not ask eleven separate questions. If
the user declines, change nothing and say what you skipped.

## Step 7: Apply the plan

Only after the user accepts, apply the plan.

* Back up each settings file you will touch. Copy it to a `.bak` file first.
* Merge your keys into the `env` block. Keep every key that is already there.
* Write the content flags only to the local settings file, and only if the user
  chose content logging.
* For pi, run the install command, set the master switch and the endpoint, and
  confirm the extension loads.
* Place `.mcp.json` at the chosen scope.
* Validate each settings file after you write it. A settings file must be valid
  JSON. If a file no longer parses, restore its backup and stop.
* Change no file that the plan did not name.

## Step 8: Offer the optional steps

Offer each optional step. State its consequence. Do not perform one unless the
user agrees.

* **Conversation tracing.** MLflow reads a whole session back as a browsable
  conversation. It records prompts, responses, and tool input and output locally.
  When the user agrees, enable it by calling the repository's script, so the
  script's own disclosure is the one the user sees:

  ```bash
  ./scripts/mlflow.autolog.claude.sh
  ```

  Do not reimplement it. The script needs an MLflow client at 3.14 or later and
  writes only `.claude/settings.local.json`.

* **Git provenance stamping.** Provenance labels let the user slice telemetry by
  repository and branch. Claude Code reads the labels from the environment; the
  `agents/direnvrc` helper provides a `use pi_otel` function that stamps them from
  a repository's `.envrc`. The pi extension derives the labels itself and needs no
  stamp. Explain the mechanism and offer to set it up.

## Step 9: Verify the installation

Verification is part of the install, not a follow-up. Produce one real turn and
confirm the signals arrive. Call the repository's end-to-end script with the
agent name and the drive flag, from the directory you configured:

```bash
./scripts/agent.verify.sh claude-code --drive   # or: pi --drive
```

The script drives one turn, waits for the export interval, then queries the stack
for the metric, the log, and the trace. It exits non-zero when a signal is
missing and names the causes.

You MUST NOT report success before all three signals arrive. If the script fails,
work Step 10.

## Step 10: The diagnostic list

When a signal is missing, work this fixed list in order. Do not guess.

1. **The stack is not running.** Run `./scripts/stack.verify.sh`. If it fails,
   start the stack again and re-verify.
2. **The export address is wrong.** Confirm `OTEL_EXPORTER_OTLP_ENDPOINT` points
   at `http://localhost:<EDGE_PORT>`, and that no higher-precedence settings level
   pins it elsewhere.
3. **The temporality key is missing.** Confirm
   `OTEL_EXPORTER_OTLP_METRICS_TEMPORALITY_PREFERENCE` is `cumulative`. Without it
   metrics are dropped while logs and traces still arrive, so a missing metric
   alone points here.
4. **The package is not installed** (pi only). Confirm
   `@desek/pi-opentelemetry` is installed and the master switch `PI_OTEL_ENABLE`
   is `1`.
5. **The export interval has not elapsed.** Wait longer, or set the export
   intervals to `1000`, then drive one more turn.

Fix the named cause, then run `./scripts/agent.verify.sh <agent> --drive` again.

## Step 11: The report

When all three signals have arrived, report to the user:

* what you changed, and where, by file path,
* what to run to see the data,
* clickable links, built by the repository's link script, not by hand:

  ```bash
  ./scripts/deeplink.sh dashboard --var agent=claude-code
  ./scripts/deeplink.sh logs '{service_name="claude-code"}'
  ```

  For pi, use `agent=pi` and `{service_name="pi-coding-agent"}`. If you enabled
  conversation tracing, also give the MLflow link to the session.

## Idempotence

Running this path a second time must change nothing. Before you write a key,
check whether it is already set to the value you would write. If every planned
key already holds its planned value, change nothing and tell the user the
configuration is already in place. Run the verification step to confirm the
signals still arrive.

## Uninstall

The uninstall path removes exactly what the install added. Read the plan back
from what is present, then remove it with the same consent and the same care.

Follow these rules:

* Show the user what you will remove and what you will restore, before you act.
  Ask once.
* Back up each settings file before you edit it. Validate it after. Restore the
  backup if validation fails.
* Remove only the keys this path adds. For Claude Code these are the telemetry
  keys in Step 6 and any content flags in the local settings file. Keep every
  other key in the `env` block.
* If the install replaced an existing value, restore that earlier value. The
  `.bak` file the install wrote holds it.
* For pi, unset the master switch and the endpoint you set. Remove the extension
  only if the user asks, with `pi uninstall @desek/pi-opentelemetry`.
* Turn off conversation tracing if the install turned it on, by calling the
  repository's script, so its own path clears both settings files:

  ```bash
  ./scripts/mlflow.autolog.claude.sh --disable
  ```

* Remove the `.mcp.json` you placed, if the install placed it.

Then verify that export has stopped. Drive one turn and confirm no new signal
arrives for the agent:

```bash
./scripts/agent.verify.sh <agent> --drive
```

After uninstall this MUST fail with the metric, log, and trace reported missing,
because the agent no longer exports. A failure here is the proof that uninstall
worked. Tell the user that export has stopped.

## When you cannot finish

If any step cannot complete, name the manual command that does the same work, so
the user has a way forward. The manual path is documented in the repository
README: start with `docker compose up -d`, verify with `./scripts/stack.verify.sh`,
and edit the settings keys from Step 6 by hand.
