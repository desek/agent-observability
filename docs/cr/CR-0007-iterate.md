---
name: iterate-ledger
description: Session ledger for a last-mile iteration session against an implemented Change Request. Records each attempt as what changed, why it was tried, and the evidence observed, names any earlier entry a later one supersedes, and derives what currently stands from the entries.
cr: "CR-0007"
opened: "2026-08-02"
source-branch: "main"
source-commit: "c1df2a3"
worktree: "/Users/desek/Repo/desek/experiments/agent-observability"
---

# Iteration Session Ledger: making the demonstration data show history rather than a spike

## Session Context

* **Governing Change Request:** CR-0007, which delivered the README as a first-run narrative, the demonstration seed, and the captured screenshots and walkthrough.
* **Gap being closed:** the seeded dashboard shows its data bunched at the right edge of every time series panel rather than spread across a plausible span of activity. The panels are correct and the picture is thin. The cause is that the stack rejects back-dated samples, so the seed writes everything into the present.
* **Starting point:** branch `main` at commit `c1df2a3`, working tree `/Users/desek/Repo/desek/experiments/agent-observability`

## Attempt Ledger

### Attempt 1 — widen the metric store's out-of-order window to 72 hours

* **Change:** `stack/mimir/config.yaml`, the `limits` block. `out_of_order_time_window` raised from `1h` to `72h`, with a comment recording why this stack ingests history rather than only a live stream, and what the window costs.

* **Reason:** a seed that writes a plausible span of past activity, and a seed derived from an agent transcript whose samples carry the timestamps of the session rather than the moment of ingestion, both need the store to accept back-dated samples. At `1h` the write is accepted with a success status and the sample is then dropped, so a panel stays empty with no error on the writing side. 72 hours covers the long weekend of history a local user reviews.

* **Evidence:** the change works for ingestion, and ingestion turned out not to be the whole story.

  Mimir reports the new value as loaded: `/config` returns `out_of_order_time_window: 3d`. The rejection text changed with it, from "beyond the out-of-order time window of 1h" to "of 3d", which is the store naming its own limit rather than an inference.

  Samples were pushed through the edge port at 6, 24, 48, 71, and 100 hours old. Every push returned HTTP 200. The only rejection Mimir logged was the 100 hour sample, correctly outside the window. So the window does what it says.

  Reading them back is a separate matter, and this is the finding worth keeping. The 6 hour sample is queryable and returns its value. The 24, 48, and 71 hour samples are NOT queryable, and querying at each sample's own timestamp rather than at the present does not change that. Their series names do appear in the store's `__name__` list, so the data was ingested rather than discarded.

  The cause is in the query path, not the write path. Mimir reports `query_ingesters_within: 13h`, `query_store_after: 12h`, and a bucket store `sync_interval: 15m`. A sample older than about twelve hours is therefore not sought from the ingester at all: the querier asks the long-term store, and the long-term store only knows about a block once that block has been compacted, shipped, and picked up by the next store synchronisation. Compaction and shipping run each minute here and had already run, so the remaining wait is the synchronisation interval, up to fifteen minutes.

  So back-dated seeding now works, and back-dated data becomes visible on a delay rather than immediately. A seeding run that writes history and screenshots straight away would still photograph empty panels, for a reason entirely different from the one this attempt fixed.

  `make ci` exits 0.

  One residue: the probe series written during this attempt, named `iterate_*` and `iter_ok_*`, remain in the metric store. Neither Mimir nor this stack exposes a delete interface, which the seeding work already recorded, so they age out with retention rather than being removed.

### Attempt 2 — decompose the README into a document set and make the front page a landing page

* **Change:** `README.md` reduced from 522 lines to 100 and rewritten as a landing page: what the stack is, the screenshots and the walkthrough, what you get, a one-command start, a table that maps each question to the document that answers it, the boundaries, and the license. Seven new documents under `docs/` each hold one question: `install.md` (prerequisites, the agent-driven install, the manual install, the port change, the demo seed), `reading-data.md` (dashboard, query recipes, conversation view, how an agent reads them), `privacy.md` (the whole posture), `use-cases.md` (other senders, adoption elsewhere, the pi extension), `architecture.md` (diagram, address table, pinned versions, persistence), `troubleshooting.md` (the symptom table), and `contributing.md` (the check gate, the layout table, the capture procedure, pull requests). Three files that assert facts about the old shape moved with it: `scripts/readme.verify.sh` now verifies the whole document set rather than one file, `scripts/agents-md.verify.sh` now asserts the privacy link points at `docs/privacy.md`, and `AGENTS.md` now carries that link.

* **Reason:** the front page had accreted into a manual. A reader who wanted one answer, how to start it, what is stored, why a panel is empty, read past every other answer to reach it, and a contributor adding a section had no rule saying where it belonged. One document per question gives both a rule: the front page is a map, and each answer has a single home.

* **Evidence:** the decomposition holds because the checks were widened with it rather than left pointing at the old shape.

  The verifier no longer trusts one file. `scripts/readme.verify.sh` now builds a document set of `README.md` plus every Markdown file directly under `docs/`, excluding the governance record and the image assets, and runs every fenced `bash` block in the set. It reports 9 blocks run and exited 0, up from 8 when the README held them all, because the troubleshooting document adds the outside-in check as a runnable command. Without this change the split would have silently dropped seven documents' worth of commands out of verification, which is the failure mode that matters here: the commands would still be printed and would no longer be proven.

  Two checks were retargeted rather than deleted. The privacy check asserted `## Privacy` in the README and the two posture sentences nowhere else; it now asserts a Privacy heading in `docs/privacy.md`, a link to it from the front page, a link to it from `AGENTS.md`, and the posture sentences only in that file. The one-statement invariant is unchanged; only its home moved. `scripts/agents-md.verify.sh` asserted the string `README.md#privacy` in `AGENTS.md`, which the move would have made false, so it now asserts `docs/privacy.md`.

  Two checks are new, and they exist because a split creates failures a single file cannot have. Every document under `docs/` must be linked from the front page, so a document cannot become an orphan the map does not show. Every relative link in the set must resolve to a path in the working tree; 48 links resolve.

  `make ci` exits 0, with the exit code read rather than inferred from the last line of output. `shellcheck` is clean on both changed scripts. The negative test still fails as designed: `scripts/readme.verify.sh --selftest` plants a governance identifier and observes the check reject it.

  One consequence worth stating. `scripts/stack.verify.sh` scans for governance identifiers only outside `docs`, so the seven new documents sit in the exempt directory. They are not unguarded: the governance check in `readme.verify.sh` now runs over each document in the set by name, which is what the per-document PASS lines report.

### Attempt 3 — retitle the front page and move the dropped words into the opening sentence

* **Change:** `README.md`, the level-1 heading and the paragraph under it. The title is now "Agent Observability Stack", replacing "Local Coding-Agent Observability Stack". The opening sentence absorbs what the shorter title no longer states: it now reads "a local-first observability stack for coding agents", where it previously said only "a local-first observability stack" and left "coding agents" to the second sentence. The second sentence was rewritten from "Its headline workload is coding agents such as Claude Code and pi, whose telemetry answers what an agent did" to "It answers what an agent such as Claude Code or pi did", which removes the restatement the new first sentence made redundant.

* **Reason:** the title now matches the repository name, `agent-observability`, so a reader who arrives from the directory name or from a clone meets the same words. A title is not a place to carry qualifiers: "Local" and "Coding-" are facts about the product, and the opening sentence states both with room to say what they mean, where the title could only assert them.

* **Evidence:** both dropped words survive in the first sentence, which is where a reader looks next: "local-first" and "on your machine and nowhere else" carry the first, "for coding agents" carries the second. No other tracked file outside the governance record used the old title, so the change is confined to the two lines that hold it. The governance record keeps the old title in its own heading, which is correct: it names what that change request was called at the time.

  `scripts/readme.verify.sh` passes: 9 command blocks run, the posture is stated once, both screenshots keep their alternative text, and all 48 relative links resolve. The screenshot alternative text still names the "Coding Agent Observability dashboard", which is not drift: that is the provisioned Grafana dashboard's own title, asserted by `scripts/dashboard.verify.sh`, and it is a different name from the project's.

  `make ci` exits 0, exit code read rather than inferred.

### Attempt 3 — fit the seeded timeline inside the narrowest backend rather than widening three of them

* **Change:** `scripts/demo.seed.sh`. The gap between seeded sessions moved from 210 seconds to 480, so the twelve-session set now spans about an hour and a half instead of thirty-eight minutes. Traces are written at the present moment rather than at their session's timestamp. The comment above the loop records the measured bound for each backend and which one binds.

* **Reason:** Attempt 1 widened the metric store and revealed that the metric store was not the only thing rejecting history. Rather than widen Loki and Tempo as well, this attempt asks what span all three already accept, and uses it. A demonstration dataset is not worth changing three storage settings for.

* **Evidence:** each backend was probed, and the three answers differ enough that the naive assumption would have been wrong in both directions.

  Loki binds. Its ingester refuses an entry older than about two hours with "entry too far behind", and this is governed by `max_chunk_age`, not by `reject_old_samples`, which is set false here and does not govern this check. The window is measured from the newest entry already in the stream, so it is tighter for an established stream than a fresh one: a first probe against a brand-new stream accepted seven hours, while a re-seed of an established stream accepted two. The seed must assume the established case, because that is what every run after the first is. A 5.5 hour span produced 91 refused entries; a 1.74 hour span still produced 12, because the boundary is anchored to a chunk edge rather than sliding with the clock; 1.5 hours produces none.

  Tempo does not accept history at all. Traces pushed 10 minutes, 1 hour, 3 hours, and 6 hours in the past each returned HTTP 200, Tempo logged no complaint, and none was searchable after four minutes, while a trace written at the present moment was searchable within forty seconds. That is the least honest of the three failure modes, and it is why traces are now written at the present rather than at their session's time. The trace panel is a table of recent traces rather than a time series, so this costs the picture nothing.

  Mimir is no longer the constraint after Attempt 1, and a span this short has a second benefit that attempt identified: under twelve hours the querier reads from the ingester rather than the long-term store, so seeded history is visible immediately instead of after the bucket store synchronises.

  After the change: zero refused entries, twenty traces searchable, and the dashboard's own committed expressions still return non-zero, 2.14 dollars across twelve sessions. `make ci` exits 0 and `shellcheck` is clean.

  One property worth knowing before capturing. Repeated seeds accumulate rather than replace: the metric span reads four hours here because series from this session's earlier, wider attempts are still in the store, and neither Loki nor Mimir offers a surgical delete. A capture run starts from `docker compose down -v` and one seed, which is the documented procedure, and that produces the clean hour and a half.

* **Supersedes:** nothing. Attempt 1 stands: the 72 hour window is still what makes a back-dated metric sample land at all, and this attempt chooses a span well inside it rather than undoing it.

### Attempt 4 — bump six of the eight pinned images to their current release

* **Change:** six images moved to their newest published release, and two were already current and were left alone. Loki `3.7.3` to `3.7.4`, Mimir `3.1.2` to `3.1.4`, Alloy `v1.17.1` to `v1.18.0`, Grafana `13.1.0` to `13.1.1`, HAProxy `3.4.2-trixie` to `3.4.3-trixie`, MLflow `v3.14.0` to `v3.15.0`. Tempo stays at `3.0.2` and the Grafana MCP server stays at `1.0.0`, because each is the newest release of its project. The version is written in more places than the compose file, so the bump also changed `stack/mlflow/Dockerfile` (the build base), `Makefile` (`HAPROXY_IMAGE`), `docs/architecture.md` (the components table), and the comments that name a version they were verified against: `scripts/deeplink.sh`, `stack/haproxy/haproxy.cfg`, and three comments inside `compose.yaml`. A new check was added to `scripts/stack.verify.sh`, for the reason below.

* **Reason:** the pins were between one patch and one minor behind, and nothing was more than one minor behind, so the bump was cheap while it stayed cheap. Deferring it makes the eventual jump larger and its failures harder to attribute to one change.

* **Evidence:** the bump broke the stack, which is the finding, and the break is now a check rather than a memory.

  MLflow did not come back. `docker compose up -d` recreated it and the container went unhealthy, with `ModuleNotFoundError: No module named 'prometheus_flask_exporter'` at import. The cause is that the mlflow service both builds a thin image from `stack/mlflow/Dockerfile` and carries an `image:` tag naming the pinned base, so the version is written twice. Changing only the compose tag made the two disagree, and compose then ran the base image, which does not carry the baked package, rather than the built one. The symptom is remote from the cause: the error names a Python module, and the mistake was a tag in a different file.

  The fix is two parts. `stack/mlflow/Dockerfile` now names `v3.15.0` as its base, and `docker compose up -d --build` rebuilds the thin image; MLflow then reports healthy. The second part is that `scripts/stack.verify.sh` now asserts the Dockerfile base and the compose image tag name the same version, and it reports `both name v3.15.0`. A future bump that changes one and forgets the other fails a check that names the fix, rather than a container that names a missing module.

  Everything else came up on the new images with no change: Alloy, Grafana, and HAProxy report healthy, and Loki, Mimir, and Tempo answer their readiness endpoints. The Alloy healthcheck was the risk worth naming, because it speaks HTTP over bash's `/dev/tcp` and so depends on the image shipping bash; `v1.18.0` still does, and the check passes. The Grafana deep-link formats were re-verified rather than assumed: `scripts/deeplink.sh --self-check` resolves all four link kinds on 13.1.1, so the comment recording the version they were verified against was updated to 13.1.1 rather than left claiming 13.1.0.

  `scripts/stack.verify.sh` passes all seven checks. `shellcheck` is clean. `make ci` exits 0, exit code read rather than inferred.

  Two residues. The committed MLflow screenshot and the walkthrough show `mlflow 3.14.0` in the sidebar, so they are now one minor version behind what runs; regenerating them is a maintainer step against a seeded stack and was not done here. And `scripts/demo.seed.sh` names Mimir 3.1.2 in a comment about the absent delete API; that file carries an unrelated uncommitted change in the working tree, so it was left untouched rather than swept into this commit.

### Attempt 4 — import the redacted transcripts and capture from real work rather than invented values

* **Change:** `stack/pricing/claude.json` pins the 25 Claude rows of the LiteLLM price table, all four token types. `scripts/transcript.import.py` reads the redacted transcripts and writes them into Mimir, Loki, and Tempo through the edge port, with `scripts/transcript.import.sh` as the shell wrapper. `scripts/capture.screenshots.sh` gains a second permitted marker, `session-import`, behind an explicit `CAPTURE_ALLOW_IMPORT=1` opt-in. `docs/images/dashboard.png` recaptured.

* **Reason:** the seeded dataset is invented, so every panel showed plausible rather than true values, and the subagent dimension did not exist at all. The transcripts are the only complete record of what the agents actually did.

* **Evidence:** 34 sessions across 91 redacted files, 2815 tool calls, 57 subagents, 953M tokens, spanning 25.8 hours of real time compressed onto the last 1.5 hours per the windows Attempt 3 measured.

  Cost is computed rather than invented. A transcript carries tokens and a model but no price, so the rate comes from the pinned table: 177.79 dollars, blended across `claude-opus-5` and a Haiku variant. A hand-check applying Opus rates to every token gives 703.98, and the gap is the Haiku sessions priced correctly at their own rate. No model went unpriced.

  The subagent breakdown is the dimension the live telemetry never had: `cr-phase-implementor` 17543s, `cr-gap-fixer` 4090s, `cr-validator` 3206s, `cr-reviewer` 2054s, `cr-finalizer` 1318s, `cr-editor` 182s, `cr-doc-updater` 120s.

  The leak check was widened deliberately rather than quietly. The two markers are not equivalent and the script now says so: `demo-seed` is invented and safe by construction, `session-import` is real work with identity and known secret formats removed. Redaction removes what it recognises; it cannot recognise a secret in a novel format, and it does not remove content that is merely private. So the import marker is opt-in, the default is unchanged, and the opt-in prints what it costs before any frame is taken.

  One defect the capture exposed: the Total tokens panel read zero while the token-rate panel beside it plainly had data. The panel filters on `model=~"${model:regex}"`, and the imported token series carried no `model` label, so they were excluded whenever the variable resolved to a concrete list. Real Claude Code telemetry does stamp the model on the token metric, so this was a fidelity gap in the importer, not a dashboard fault. Fixed by stamping the model on the token and active-time metrics.

  Consequence worth stating: the fix changes the label set, so re-importing writes new series alongside the old ones. The dashboard filters by model and so reads correctly, but an unfiltered sum would double count until the volumes are wiped. A clean re-import therefore needs `docker compose down -v`, which is the user's call rather than this session's.

  Not yet done: the importer writes no MLflow conversation, so the conversation image still shows seeded data. `shellcheck` is clean on both new shell files and the Python parses.

* **Supersedes:** nothing. Attempt 3 chose the span this importer reuses.

### Attempt 5 — wipe, re-import clean, write MLflow conversations, and recapture

* **Change:** `scripts/transcript.import.mlflow.py` writes the richest imported sessions into MLflow as conversation traces, with a turn span per exchange, a tool span beneath it, and a span per subagent. `scripts/transcript.import.sh` runs it after the metric, log, and trace write. `scripts/capture.screenshots.sh` no longer keys the MLflow navigation on a seed-specific request string. Volumes wiped, stack rebuilt, transcripts re-imported, both images recaptured.

* **Reason:** Attempt 4 left the label set changed, so a re-import would have double counted until the volumes were wiped, and the conversation view still showed seeded data because the importer wrote no MLflow traces.

* **Evidence:** the wipe was verified against the right target before it ran. This directory resolves to compose project `agent-observability` on port 24417; the other project on 24417's neighbour, `observability` on 24317, holds the real telemetry and was confirmed still running afterwards.

  After the clean import the store holds one marker, `session-import`. Total tokens now reads 953,038,772 both with and without the model filter, which is the Attempt 4 defect fixed and the double count absent. 34 sessions, $177.79, 77 commits, 8 MLflow conversation traces.

  `make ci` initially failed, correctly. The AGENTS.md verifier asserts that every metric family the documentation names exists in the store, and a Claude-Code-only import leaves the `pi_*` families absent. That is the check working rather than a fault in it, so the fix was to restore the families by seeding rather than to weaken the assertion. `make ci` then exits 0, read as an exit code rather than inferred from the last line.

  A privacy incident occurred during this attempt and is recorded here because the cause is a property of the tooling rather than a one-off slip. Debugging the MLflow navigation outside the capture script's own flow, a bare screenshot captured the author's personal browser rather than the stack: agent-browser drives a persistent session that is the real browser, so a screenshot with no preceding navigation photographs whatever the active target is. The frame was deleted immediately and reached no commit; both committed images were confirmed to be the Grafana and MLflow interfaces. The capture script itself is protected only by ordering, because it navigates with `ab open` immediately before each frame, and that is a thinner margin than it looks for a script whose output is a public image. A recording is worse than a still, since it captures the whole duration rather than one moment. Pinning the capture to an isolated browser profile is the durable fix and is not done here.

  The MLflow navigation was diagnosed but not fixed. Two overlays intercept the click, a first-visit guidance popover and the MLflow Assistant panel, and the correct handle is the snapshot-and-ref workflow rather than a CSS or text selector. The captured conversation image therefore still shows the trace list rather than an expanded conversation, which the author accepted for now.

* **Supersedes:** nothing. Attempt 4 introduced the importer this completes.

## What Stands Now

* The stack holds the real work: 34 imported sessions, 2815 tool calls, 57 subagents, cost computed from a pinned price table rather than invented.
* Screenshot capture permits imported data only behind `CAPTURE_ALLOW_IMPORT=1`, which states that the prompt and response text in any captured image is real.
* The importer writes MLflow conversation traces, so all four stores hold imported data. The captured conversation image still shows the trace list rather than an expanded conversation: two overlays intercept the click and the fix is the snapshot-and-ref workflow, diagnosed but not applied.
* Screenshot capture drives a persistent browser session that is the real browser, protected only by navigating immediately before each frame. Pinning it to an isolated profile is the durable fix and is outstanding.
* The metric store accepts back-dated samples up to 72 hours. Verified at 6, 24, 48, and 71 hours, with 100 hours correctly refused.
* The seeded dataset spans about an hour and a half, which is the widest span every backend accepts without changing a storage setting. Loki is the binding constraint at roughly two hours, anchored to a chunk edge. Tempo accepts no history at all, so seeded traces are written at the present moment.
* Back-dated samples older than roughly twelve hours are not immediately queryable. They become visible after the block ships and the store synchronises, which is up to fifteen minutes on the current settings. Anything that seeds history and then reads or photographs it must account for that delay, or the settings that govern it must change.
* The project's front page is titled "Agent Observability Stack", matching the repository name. The local-first posture and the coding-agent workload are stated in the opening sentence rather than in the title.
* The reader documentation is a set of eight files, not one. `README.md` is a 100-line landing page carrying the pictures, what you get, the one-command start, the map, and the boundaries. Seven documents under `docs/` each answer one question and are each the single home for that answer.
* The privacy posture lives in `docs/privacy.md`. It is stated once there, linked from the front page and from `AGENTS.md`, and a second copy of either posture sentence anywhere else fails a check.
* `scripts/readme.verify.sh` verifies the document set, not the README alone: every fenced `bash` block in the set runs, no document carries a governance identifier, every document is linked from the front page, and every relative link resolves.
* The pinned images are Loki 3.7.4, Mimir 3.1.4, Tempo 3.0.2, Alloy v1.18.0, Grafana 13.1.1, MLflow v3.15.0, HAProxy 3.4.3-trixie, and Grafana MCP 1.0.0. Every one is the newest published release of its project as of 2026-08-02.
* The MLflow version is written twice, in `compose.yaml` and in `stack/mlflow/Dockerfile`, and `scripts/stack.verify.sh` asserts the two agree. A bump changes both and rebuilds with `docker compose up -d --build`.
* The committed screenshots and the walkthrough show MLflow 3.14.0, one minor version behind what runs. They want a re-capture.
* `make ci` passes, exit code 0.
