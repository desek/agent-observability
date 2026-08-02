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

## What Stands Now

* The metric store accepts back-dated samples up to 72 hours. Verified at 6, 24, 48, and 71 hours, with 100 hours correctly refused.
* Back-dated samples older than roughly twelve hours are not immediately queryable. They become visible after the block ships and the store synchronises, which is up to fifteen minutes on the current settings. Anything that seeds history and then reads or photographs it must account for that delay, or the settings that govern it must change.
* The project's front page is titled "Agent Observability Stack", matching the repository name. The local-first posture and the coding-agent workload are stated in the opening sentence rather than in the title.
* The reader documentation is a set of eight files, not one. `README.md` is a 100-line landing page carrying the pictures, what you get, the one-command start, the map, and the boundaries. Seven documents under `docs/` each answer one question and are each the single home for that answer.
* The privacy posture lives in `docs/privacy.md`. It is stated once there, linked from the front page and from `AGENTS.md`, and a second copy of either posture sentence anywhere else fails a check.
* `scripts/readme.verify.sh` verifies the document set, not the README alone: every fenced `bash` block in the set runs, no document carries a governance identifier, every document is linked from the front page, and every relative link resolves.
* `make ci` passes, exit code 0.
