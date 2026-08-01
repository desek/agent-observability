---
id: "CR-0004"
name: cr-mlflow-agent-conversation-tracking
description: Pre-configure the stack's MLflow tracking server for coding agents so that a user reaches browsable conversation traces with minimal friction, by auto-provisioning the agent experiments at stack start, shipping a wrapper script that configures Claude Code conversation tracing through a client resolved in a documented preference order so no Python install is required, documenting the tracking URI and the privacy consequence, and providing a reversible disable path.
status: "proposed"
date: 2026-08-01
requestor: daniel@grenemark.se
stakeholders: Repository maintainers, Claude Code users, pi users, open-source contributors
priority: "high"
target-version: "0.1.0"
source-branch: main
source-commit: none (repository has no commits yet)
---

# MLflow Pre-Configured for Coding-Agent Conversation Tracking

## Change Summary

The stack ships an MLflow tracking server, but it ships it empty and unwired. A user who opens it sees a default experiment, no runs, and no indication that it has anything to do with coding agents. Meanwhile the one capability the telemetry pipeline cannot provide, reading a whole agent conversation back as a conversation, is exactly what MLflow can provide and is not configured to.

This change pre-configures MLflow for coding agents: the agent experiments exist the moment the stack starts, one script wires Claude Code conversation tracing without requiring the user to install Python or MLflow, the tracking address is documented in one place, and disabling the whole thing is a single command.

## Motivation and Background

The Grafana side of this stack answers aggregate questions well. What did this week cost, which model, which repository, how many tool calls failed. It answers one question badly: what actually happened in that session. Log lines in Loki hold the prompts and the responses, but reading a conversation back through a log query is a poor experience. The turns interleave with tool events, the ordering depends on timestamps that batch together, and there is no notion of a thread.

MLflow's tracing model has exactly the right shape for this. A session becomes a trace, turns and tool calls become nested spans with their inputs and outputs, and the user interface renders it as a conversation with token counts, costs, and latencies attached. Claude Code has a supported integration that produces this: a single end-of-turn hook reads the session transcript once the turn finishes and reconstructs the trace from it. There is no wrapper process, no interception inside the turn, and no added latency while the agent is working.

The friction is what has kept this unused. The integration is configured by an MLflow command-line client, which means a Python environment the user may not have and does not want. The tracking address must be typed correctly, including a path prefix that is easy to get wrong. The experiment must exist or runs land somewhere unexpected. And the configuration is written into the user's Claude Code settings, which is a file people are reasonably cautious about. Every one of those is removable, and this change removes them.

The privacy consequence deserves to be stated as motivation rather than as a footnote. Conversation tracing stores the whole conversation: every prompt, every response, every tool input and output. That is the point of it, and it is also why it must be local, why it must be off until the user turns it on, and why turning it off must be one command that actually reverses the change.

## Change Drivers

* The stack cannot show a conversation back to the user today, and that is the question users most often want answered.
* MLflow is already running in the stack and already has the capability; only the configuration is missing.
* Configuring it by hand today requires a Python client, an exactly-typed address, and a hand edit of the user's agent settings.
* An empty MLflow with a default experiment gives a new user no signal that the tool is relevant to them.
* Conversation content is the most sensitive data the project touches, so the opt-in, the disclosure, and the reversal must all be deliberate.

## Current State

After CR-0001, the MLflow tracking server runs as one more container on the internal network, publishes no host port, and is reached through the single edge port under a path prefix. Its metadata lives in a database file on a named volume and its artifacts on the same volume, both served through the tracking server so clients never touch the filesystem directly. Its own server metrics are scraped into Mimir. All of this works.

What is missing:

* No experiment exists beyond MLflow's default, so a user has nothing to open and no place for runs to land.
* Nothing in the repository configures Claude Code conversation tracing. The capability is documented in the private parent's runbook as a candidate that was deliberately not enabled.
* The tracking address is documented only inside a long runbook section, not where a user configuring a client would look.
* Enabling the integration requires an MLflow client on the user's path, which the repository neither provides nor detects.
* There is no disable path, no verification that tracing is working, and no statement of what tracing stores.
* pi has no equivalent integration at all.

### Current State Diagram

```mermaid
flowchart TD
    STACK["Stack running"] --> MLFLOW["MLflow tracking server behind the single port"]
    MLFLOW --> EMPTY["Default experiment only, zero runs"]
    CC["Claude Code session"] -->|"OTLP telemetry"| LGTM["Grafana LGTM: aggregate views"]
    CC -.->|"no conversation tracing configured"| MLFLOW
    PI["pi session"] -->|"OTLP telemetry"| LGTM
    PI -.->|"no integration exists"| MLFLOW
    USER["User who wants to read a session back"] -->|"must write LogQL and read interleaved lines"| LGTM
```

## Proposed Change

Make MLflow useful for coding agents on the first run, and make enabling conversation tracing a single, reversible, well-disclosed command.

1. **Experiments exist at stack start.** A small provisioning step, run by the stack itself once MLflow is healthy, creates the agent experiments if they are absent: one for Claude Code conversations and one reserved for pi. It uses the tracking server's own interface over the internal network, is idempotent, and never overwrites an experiment a user has changed. A user who opens MLflow immediately after starting the stack sees named experiments rather than a blank page.

2. **One command wires Claude Code, with no Python prerequisite.** `scripts/mlflow.autolog.claude.sh` configures the integration. It resolves an MLflow client in a documented preference order and uses the first that is available: an `mlflow` client already on the user's path, then an ephemeral client run through a Python tool runner if one is installed, then the stack's own MLflow container as a fallback. The container fallback needs the agent transcript directory to be readable from inside the container, so the script mounts it read-only; whether the container path is viable is a question the implementer answers by testing it, and if it is not, the script says so plainly and names the two remaining options rather than failing obscurely.

3. **The hook points at this repository's wrapper, not at a bare client.** The end-of-turn hook that the integration installs is written to invoke `scripts/mlflow.autolog.hook.sh` from this repository rather than a bare `mlflow` command. That indirection is what makes the choice of client an implementation detail: the hook keeps working when the user later installs or removes a Python environment, and the resolution logic lives in one readable script instead of frozen into the user's settings file.

4. **The tracking address is documented once, and derived everywhere.** The tracking address is the single edge port plus the MLflow path prefix. Every script derives it from the same variable the rest of the stack uses, so changing the published port does not silently break tracing. The README states the address, the experiment names, and the address a non-agent MLflow client should use, in one short section.

5. **Enabling is opt-in and discloses what it does before it does it.** The script states, before making any change, exactly which file it will modify, which keys it will add, that the effect is to store every prompt, every response, and every tool input and output in a local volume, and that the change is reversed by one flag. It requires an explicit confirmation, and it supports a non-interactive flag for the agent-driven installation path of CR-0006, which is required to make the same disclosure itself.

6. **Disabling actually reverses the change.** The same script with a disable flag removes the hook entry and the added settings keys, leaving the user's settings file otherwise untouched. Because the integration matches its own hook entry when it writes, running enable twice updates rather than duplicates, and disable after two enables leaves nothing behind. The script verifies the end state rather than assuming it.

7. **Verification is a script, not a hope.** `scripts/mlflow.verify.sh` proves the tracking server end to end: it creates an experiment, a run, a parameter, and a metric through the tracking interface and reads them back. `scripts/mlflow.tracing.verify.sh` proves the agent integration specifically: after one agent turn, it asserts that a trace exists in the agent experiment and that the trace contains at least the user turn and the assistant turn. Both print usage, exit non-zero on failure, and name the fix.

8. **pi is addressed honestly, not silently.** No equivalent integration exists for pi. This change creates the pi experiment and documents the gap: pi conversation content is available today as readable log lines in Loki, and full pi conversation tracing needs an extension change that is deliberately not attempted here. Claiming parity that does not exist would be worse than stating the gap.

9. **Privacy, stated where the decision is made.** The README gains an MLflow section stating what conversation tracing stores, where it is stored, that it never leaves the machine, that it is off until enabled, how to disable it, and how to delete what has already been stored. The last point matters: a user who enables tracing, changes their mind, and disables it still has the stored conversations on the volume, and must be told how to remove them.

### Proposed State Diagram

```mermaid
flowchart TD
    UP["docker compose up -d"] --> PROV["Experiment provisioning, idempotent, once MLflow is healthy"]
    PROV --> EXP["Experiments: claude-code and pi"]
    ENABLE["scripts/mlflow.autolog.claude.sh"] --> DISCLOSE["Discloses the file, the keys, and what gets stored, then asks for confirmation"]
    DISCLOSE --> WRITE["Writes an end-of-turn hook pointing at scripts/mlflow.autolog.hook.sh"]
    WRITE --> RESOLVE["Hook resolves a client: path, then ephemeral runner, then stack container"]
    CC["Claude Code turn ends"] --> RESOLVE
    RESOLVE --> TRACE["Trace written to the claude-code experiment"]
    TRACE --> UI["MLflow user interface: conversation with turns, tools, tokens, cost, latency"]
    TRACE --- VOL[("mlflow-data volume, local only")]
    DISABLE["Same script with the disable flag"] --> REMOVE["Removes the hook and the added keys, verifies the end state"]
    PI["pi session"] -->|"conversation content available as readable log lines"| LOKI["Loki"]
    PI -.->|"tracing integration deliberately not attempted"| EXP
```

## Requirements

### Functional Requirements

1. The stack **MUST** create the Claude Code and pi experiments in MLflow automatically once the tracking server is healthy, without any user action.
2. The experiment provisioning **MUST** be idempotent, and **MUST NOT** modify or replace an experiment that already exists.
3. The experiment provisioning **MUST NOT** prevent the stack from starting if it fails, and **MUST** report its failure in a way a user can find.
4. The repository **MUST** contain `scripts/mlflow.autolog.claude.sh` that configures Claude Code conversation tracing against this stack.
5. That script **MUST** resolve an MLflow client in a documented preference order and **MUST NOT** require the user to install Python or MLflow beforehand when a fallback is available.
6. That script **MUST** state, before making any change, the exact file it will modify, the exact keys it will add, and that the effect is to store prompts, responses, and tool input and output locally.
7. That script **MUST** require an explicit confirmation before changing the user's settings, and **MUST** support a non-interactive flag that skips the prompt but not the disclosure.
8. The installed hook **MUST** invoke this repository's wrapper script rather than a bare client command.
9. The wrapper script **MUST** resolve the client at invocation time using the same documented preference order.
10. The script **MUST** support a disable flag that removes the hook entry and every key the enable path added, and leaves the rest of the user's settings unchanged.
11. Running the enable path twice **MUST** update the existing configuration rather than create a duplicate hook entry.
12. Every script **MUST** derive the tracking address from the same port variable the rest of the stack uses, and **MUST NOT** hard-code the port.
13. The repository **MUST** contain `scripts/mlflow.verify.sh` proving the tracking server end to end through the single port with no Python dependency.
14. The repository **MUST** contain `scripts/mlflow.tracing.verify.sh` proving that an agent turn produces a trace in the agent experiment containing at least the user turn and the assistant turn.
15. Every script **MUST** print usage with `-h`, exit non-zero on failure, and print an error naming what failed, the available fixes, and what to check afterwards.
16. The README **MUST** state the tracking address, the experiment names, and the address a non-agent MLflow client should use.
17. The README **MUST** state what conversation tracing stores, where, that it never leaves the machine, that it is off until enabled, how to disable it, and how to delete already-stored conversations.
18. The README **MUST** state that pi conversation tracing is not provided, why, and what is available for pi instead.
19. The repository **MUST NOT** enable conversation tracing as a side effect of starting the stack.

### Non-Functional Requirements

1. Conversation tracing **MUST NOT** add latency inside an agent turn, because the integration runs after the turn finishes.
2. A failure of the tracking server or of the hook **MUST NOT** cause an agent turn to fail.
3. All conversation data **MUST** remain on the local machine, in the stack's own volume.
4. The enable path **MUST** complete in under 60 seconds on a machine where no MLflow client is installed.
5. The scripts **MUST** work on a machine whose only prerequisite is Docker, consistent with the rest of the project.
6. Disabling **MUST** leave the user's agent settings file valid and semantically unchanged apart from the removed keys.

## Affected Components

* `compose.yaml`, the experiment provisioning step and its dependency on MLflow health.
* `scripts/mlflow.provision.sh`, `scripts/mlflow.autolog.claude.sh`, `scripts/mlflow.autolog.hook.sh`, `scripts/mlflow.verify.sh`, `scripts/mlflow.tracing.verify.sh`, all new.
* `README.md`, an MLflow section covering address, experiments, enabling, disabling, privacy, and the pi gap.
* The user's Claude Code settings file, modified only by explicit user action through the enable path.

## Scope Boundaries

### In Scope

* Automatic, idempotent creation of the agent experiments.
* A one-command enable path for Claude Code conversation tracing that requires no prior Python install.
* A reversible disable path that verifies its own result.
* Client resolution logic in one wrapper script rather than frozen into user settings.
* Verification scripts for the tracking server and for the tracing integration.
* README coverage of address, experiments, privacy, deletion, and the pi gap.

### Out of Scope ("Here, But Not Further")

* pi conversation tracing. No supported integration exists, and building one means changing the extension's signal contract, which CR-0003 freezes for its first release.
* The MLflow model registry, model logging, and any machine-learning workflow. The server supports them and this change neither configures nor documents them beyond what already exists.
* The MLflow AI gateway, budget enforcement, and prompt guardrails. Related, unverified against subscription authentication, and a separate decision.
* Changing MLflow's storage backend, its artifact store, or its server flags.
* Automatic enablement of tracing at stack start. Enabling is a user decision, always.
* The MLflow screenshot in the README. That is CR-0007.
* Retention, rotation, or automatic deletion of stored conversations. The README documents manual deletion; automated retention is a later change.

## Alternative Approaches Considered

* **Document the manual procedure and stop there.** Rejected: that is the current state in the private parent, and it is why the capability has gone unused.
* **Require the user to install the MLflow Python client.** Rejected as the only path: it contradicts the project's promise that Docker is the sole prerequisite. It remains the first-choice path when the client is already present, because it is the fastest.
* **Run the hook entirely inside the stack container, always.** Rejected as the only path: the hook must read a transcript that lives on the host, so the container needs a mount, and mounting a user's agent transcript directory into a container is a heavier default than most users expect. It stays as the last fallback, chosen only when nothing lighter is available.
* **Write the hook to call a bare client command.** Rejected: it freezes the client choice into the user's settings, so a later change in the user's environment silently breaks tracing with no obvious cause.
* **Enable tracing automatically when the stack starts.** Rejected outright: conversation content is the most sensitive data the project handles, and enabling it without an explicit decision would be a betrayal of the user's expectations, regardless of the data staying local.
* **Store conversations in Loki instead and build a conversation view in Grafana.** Rejected for now: the data is already in Loki, and building a conversation renderer is a large piece of work that duplicates something MLflow already does well.

## Impact Assessment

### User Impact

A user who wants to read a session back runs one command, confirms a disclosure, and then finds every subsequent session in MLflow as a browsable conversation with costs and latencies attached. A user who does not want this is unaffected, because nothing is enabled without the command. A user who changes their mind runs the same command with a disable flag and is told how to delete what was already stored.

The one intrusive part is that enabling modifies the user's Claude Code settings file. That is inherent to how the integration works, and the mitigation is disclosure before the fact and a disable path that reverses it.

### Technical Impact

The stack gains a provisioning step that must not block startup. The scripts gain a client-resolution path with three branches, which is the price of removing the Python prerequisite, and that path is the part most likely to behave differently across machines, so it carries the most test attention.

The hook indirection means the user's settings point at a path inside this repository. Moving or deleting the clone breaks tracing. The script must therefore write an absolute path and the troubleshooting section must name this cause, since a user who reorganises their directories will otherwise see tracing stop for no visible reason.

### Business Impact

This is the capability that differentiates the project from a plain telemetry stack, and it is the one most likely to make a person keep it installed. The cost is a few scripts and a careful disclosure. The risk it introduces is reputational rather than technical: storing whole conversations badly, or without telling people, would be worse than not storing them at all.

## Implementation Approach

### Phase 1: Experiment provisioning

Write `scripts/mlflow.provision.sh` to create the agent experiments idempotently through the tracking interface. Wire it into the stack so it runs once the tracking server is healthy, and confirm that a failure logs clearly and does not stop the stack. Verify that a second start changes nothing.

### Phase 2: Client resolution

Write `scripts/mlflow.autolog.hook.sh`, the wrapper that resolves a client at invocation time. Test each branch of the preference order deliberately: with a client on the path, with only an ephemeral runner, and with neither. Determine by testing whether the container fallback can read the transcript, and record the finding. If it cannot, the script must say so and name the remaining options.

### Phase 3: Enable and disable

Write `scripts/mlflow.autolog.claude.sh`. Implement the disclosure, the confirmation, the non-interactive flag, the enable path, and the disable path. Verify that enabling twice does not duplicate, that disabling removes exactly what enabling added, and that the settings file stays valid.

### Phase 4: Verification

Write `scripts/mlflow.verify.sh` and `scripts/mlflow.tracing.verify.sh`. Prove a full round trip for the tracking server, and prove that one real agent turn produces a trace containing the user turn and the assistant turn.

### Phase 5: Documentation

Write the README MLflow section: address, experiments, enable, disable, what is stored, where, deletion, and the pi gap. Write the troubleshooting entries, including the moved-clone cause and the missing-client cause.

### Implementation Flow

```mermaid
flowchart LR
    subgraph P1["Phase 1"]
        A["provision script"] --> B["wire into stack start"]
    end
    subgraph P2["Phase 2"]
        C["hook wrapper"] --> D["test all three client branches"]
    end
    subgraph P3["Phase 3"]
        E["disclosure and confirm"] --> F["enable"] --> G["disable and verify"]
    end
    subgraph P4["Phase 4"]
        H["server verify"] --> I["tracing verify"]
    end
    subgraph P5["Phase 5"]
        J["README section"] --> K["troubleshooting"]
    end
    P1 --> P2 --> P3 --> P4 --> P5
```

## Test Strategy

The deliverable is shell scripts plus a provisioning step, so tests are executable assertions run against the real tracking server and a real agent turn.

### Tests to Add

| Test File | Test Name | Description | Inputs | Expected Output |
|-----------|-----------|-------------|--------|-----------------|
| `scripts/mlflow.verify.sh` | `experiment_run_roundtrip` | Creates an experiment, a run, a parameter, and a metric and reads them back | Tracking address | Exit 0; values match |
| `scripts/mlflow.verify.sh` | `served_artifact_roundtrip` | Uploads and downloads an artifact through the server | Tracking address | Exit 0; content matches |
| `scripts/mlflow.provision.sh` | `creates_missing_experiments` | Creates both agent experiments when absent | Empty tracking server | Exit 0; both exist |
| `scripts/mlflow.provision.sh` | `is_idempotent` | Second run changes nothing | Tracking server with experiments present | Exit 0; identifiers unchanged |
| `scripts/mlflow.provision.sh` | `does_not_block_startup` | Reports failure without failing the stack | Unreachable tracking server | Stack still runs; failure logged |
| `scripts/mlflow.autolog.hook.sh` | `resolves_client_on_path` | Chooses the client on the path when present | Environment with a client on the path | That client is used |
| `scripts/mlflow.autolog.hook.sh` | `falls_back_when_absent` | Falls through the preference order | Environment with no client on the path | Next available option is used |
| `scripts/mlflow.autolog.hook.sh` | `fails_actionably_when_none` | Names the fixes when no client can be resolved | Environment with no option available | Non-zero exit; message names each option |
| `scripts/mlflow.autolog.claude.sh` | `discloses_before_changing` | Prints the file, the keys, and the storage consequence before any write | Interactive invocation | Disclosure printed; no write before confirmation |
| `scripts/mlflow.autolog.claude.sh` | `enable_is_idempotent` | Two enables produce one hook entry | Settings file | Exactly one hook entry |
| `scripts/mlflow.autolog.claude.sh` | `disable_reverses_enable` | Disable removes exactly what enable added | Settings file before and after | Files match apart from the intended keys |
| `scripts/mlflow.autolog.claude.sh` | `writes_absolute_wrapper_path` | The hook records an absolute path to the wrapper | Settings file | Path is absolute |
| `scripts/mlflow.autolog.claude.sh` | `derives_address_from_port_variable` | Uses the configured port rather than a literal | Environment with a non-default port | Address carries the configured port |
| `scripts/mlflow.tracing.verify.sh` | `turn_produces_trace` | One agent turn produces a trace in the agent experiment | One non-interactive agent turn | Exit 0; trace found |
| `scripts/mlflow.tracing.verify.sh` | `trace_contains_conversation` | The trace contains at least the user turn and the assistant turn | The produced trace | Exit 0; both present |

### Tests to Modify

| Test File | Test Name | Current Behavior | New Behavior | Reason for Change |
|-----------|-----------|------------------|--------------|-------------------|
| `scripts/stack.verify.sh` | MLflow readiness assertion | Asserts the health endpoint answers | Also asserts both agent experiments exist | Experiment provisioning becomes part of a correctly started stack |

### Tests to Remove

Not applicable.

## Acceptance Criteria

### AC-1: Experiments exist without user action (covers FR1, FR2, FR3)

```gherkin
Given a fresh clone with no prior MLflow volume
When the user runs "docker compose up -d" and waits for the stack to become healthy
Then the Claude Code and pi experiments are listed in MLflow
  And running the stack again does not change their identifiers
  And when MLflow is unreachable, the stack still starts and the failure is reported
```

### AC-2: Enabling requires no Python install (covers FR5, NFR4, NFR5)

```gherkin
Given a machine whose only prerequisite is Docker
  And no MLflow client on the path
When the user runs the enable script and confirms
Then the configuration completes successfully within 60 seconds
  And the user was not asked to install Python or MLflow
```

### AC-3: The user is told what will happen before it happens (covers FR6, FR7, FR19)

```gherkin
Given the enable script is run interactively
When it starts
Then it names the exact file it will modify and the exact keys it will add
  And it states that prompts, responses, and tool input and output will be stored locally
  And no change is written until the user confirms
  And starting the stack alone never enables tracing
```

### AC-4: A turn produces a browsable conversation (covers FR14, NFR1, NFR3)

```gherkin
Given conversation tracing is enabled
When the user completes one Claude Code turn
Then a trace appears in the Claude Code experiment
  And the trace contains the user turn and the assistant turn
  And the turn itself was not delayed by the integration
  And the data is stored only in the stack's local volume
```

### AC-5: Enabling twice does not duplicate (covers FR11)

```gherkin
Given tracing is already enabled
When the user runs the enable script again
Then exactly one hook entry exists in the settings file
```

### AC-6: Disabling reverses the change (covers FR10, NFR6)

```gherkin
Given tracing is enabled
When the user runs the script with the disable flag
Then the hook entry and every key the enable path added are removed
  And the rest of the settings file is unchanged
  And the file is still valid
  And a subsequent turn produces no new trace
```

### AC-7: The hook survives a change in the user's environment (covers FR8, FR9)

```gherkin
Given tracing is enabled on a machine with no MLflow client on the path
When the user later installs an MLflow client
  And completes a turn
Then tracing still works
  And no settings change was required
```

### AC-8: The port is never hard-coded (covers FR12)

```gherkin
Given the stack is configured with a non-default published port
When the enable script and the verification scripts run
Then every one of them addresses the tracking server on the configured port
```

### AC-9: The tracking server is proven end to end (covers FR13)

```gherkin
Given the stack is running
When the user runs scripts/mlflow.verify.sh
Then it creates an experiment, a run, a parameter, and a metric and reads them back
  And it exits 0 with no Python dependency
```

### AC-10: Failures are actionable (covers FR15)

```gherkin
Given no MLflow client can be resolved by any branch of the preference order
When the hook runs
Then it exits non-zero
  And it names each way to provide a client
  And it names what to check after applying one
```

### AC-11: Privacy and deletion are documented (covers FR17)

```gherkin
Given the README
When a user reads the MLflow section
Then it states what conversation tracing stores and where
  And it states that the data never leaves the machine
  And it states that tracing is off until enabled
  And it gives the command that disables it
  And it gives the command that deletes already-stored conversations
```

### AC-12: The pi gap is stated, not hidden (covers FR18)

```gherkin
Given the README
When a pi user looks for conversation tracing
Then the README states that it is not provided for pi and why
  And it names what is available for pi instead
```

### AC-13: An MLflow failure never breaks an agent turn (covers NFR2)

```gherkin
Given conversation tracing is enabled
When the stack is stopped and the user completes an agent turn
Then the turn completes normally
  And no error is surfaced by the agent
```

## Quality Standards Compliance

### Build & Compilation

- [ ] `docker compose config` parses the provisioning wiring without error
- [ ] The stack starts cleanly with the provisioning step present

### Linting & Code Style

- [ ] `shellcheck` passes with zero warnings on every added script
- [ ] Every script is executable, single-purpose, and carries a top docstring and one `@agents-index` line
- [ ] Every script prints usage with `-h`

### Test Execution

- [ ] Every assertion listed in the test strategy passes
- [ ] `scripts/stack.verify.sh` still exits 0

### Documentation

- [ ] The README MLflow section covers address, experiments, enable, disable, privacy, deletion, and the pi gap
- [ ] Troubleshooting covers the missing-client cause and the moved-clone cause

### Code Review

- [ ] Changes submitted via pull request
- [ ] PR title follows Conventional Commits format
- [ ] Code review completed and approved
- [ ] Changes squash-merged to maintain linear history

### Verification Commands

```bash
# Experiments exist after a start
curl -s "http://localhost:${EDGE_PORT:-24317}/mlflow/api/2.0/mlflow/experiments/search" \
  -H 'Content-Type: application/json' -d '{"max_results":100}' | jq -r '.experiments[].name'

# Tracking server round trip, no Python needed
./scripts/mlflow.verify.sh

# Enable, non-interactively, with the disclosure still printed
./scripts/mlflow.autolog.claude.sh --yes

# One turn, then prove the trace exists and holds the conversation
claude -p "Print the word telemetry and nothing else."
./scripts/mlflow.tracing.verify.sh

# Reverse it
./scripts/mlflow.autolog.claude.sh --disable

# Script lint
shellcheck scripts/mlflow.*.sh
```

## Risks and Mitigation

### Risk 1: The script modifies the user's agent settings file incorrectly

**Likelihood:** medium; the file is user-owned and may hold anything
**Impact:** high; a corrupted settings file breaks the user's agent
**Mitigation:** The script writes through the integration's own mechanism rather than by hand-editing where possible, backs the file up before writing, validates the result, and restores the backup if validation fails. The disable path is tested to leave the file byte-identical apart from the intended keys.

### Risk 2: No MLflow client can be resolved on the user's machine

**Likelihood:** medium
**Impact:** medium; tracing silently does nothing at the end of each turn
**Mitigation:** Three resolution branches, a hook that exits with an actionable message naming every option, and a verification script whose whole purpose is to catch exactly this before the user assumes it works.

### Risk 3: The user moves or deletes the clone after enabling

**Likelihood:** medium
**Impact:** medium; the hook points at a path that no longer exists
**Mitigation:** The hook path is written as an absolute path, the hook fails with a message naming this cause, and the README troubleshooting section lists it first among causes of tracing stopping unexpectedly.

### Risk 4: Conversation data accumulates without bound

**Likelihood:** high over time
**Impact:** medium; volume growth on the user's disk
**Mitigation:** The README documents where the data lives, how to measure its size, and how to delete it, both selectively and completely. Automatic retention is named as out of scope rather than left unmentioned.

### Risk 5: A user enables tracing without understanding what is stored

**Likelihood:** medium
**Impact:** high
**Mitigation:** The disclosure precedes every write, is printed even in non-interactive mode, and is repeated in the README. CR-0006's installation path is required to carry the same disclosure rather than skipping it for convenience.

### Risk 6: The container fallback cannot read the agent transcript

**Likelihood:** medium; it depends on where the transcript lives and on the host platform
**Impact:** medium; one of three branches becomes unavailable
**Mitigation:** Phase 2 tests the branch rather than assuming it, and the finding is recorded. If the branch is unavailable, the script omits it and names the two remaining options, which is a smaller failure than presenting a branch that does not work.

## Dependencies

* CR-0001, for the stack, the MLflow service, the port variable, and the script conventions.
* A Claude Code installation for the tracing integration and for verification.
* No dependency on CR-0002, CR-0003, or CR-0005. CR-0006 depends on this change, because its installation path calls these scripts.

## Estimated Effort

Roughly 12 to 16 person-hours: 2 for provisioning, 4 for client resolution and its three branches, 3 for enable and disable, 3 for the verification scripts, and 3 for documentation and end-to-end testing.

## Decision Outcome

Chosen approach: "provision the agent experiments automatically, and make conversation tracing a single opt-in command that resolves its own client and reverses cleanly", because the capability already exists and every barrier to using it is friction rather than function. Enabling is kept explicit and disclosed because conversation content is the most sensitive data the project handles, and the wrapper indirection is chosen so the user's settings never freeze an environment-specific decision.

## Related Items

* CR-0001: the stack and the MLflow service this change configures.
* CR-0003: the pi extension, whose frozen signal contract is why pi conversation tracing is out of scope here.
* CR-0006: the agent-driven installation path, which calls these scripts and repeats their disclosure.
* CR-0007: the README screenshot of a conversation in the MLflow interface.
