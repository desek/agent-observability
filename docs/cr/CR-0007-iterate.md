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

## What Stands Now

* The metric store accepts back-dated samples up to 72 hours. Verified at 6, 24, 48, and 71 hours, with 100 hours correctly refused.
* Back-dated samples older than roughly twelve hours are not immediately queryable. They become visible after the block ships and the store synchronises, which is up to fifteen minutes on the current settings. Anything that seeds history and then reads or photographs it must account for that delay, or the settings that govern it must change.
* `make ci` passes.
