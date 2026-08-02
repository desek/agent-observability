# CR-0002 Validation Report

**CR:** `docs/cr/CR-0002-baseline-grafana-dashboard.md` — Baseline Grafana Dashboard for Coding-Agent Telemetry
**Validated:** 2026-08-02
**Measurement port:** all live measurements taken on **EDGE_PORT 24417** (this repository's stack, compose project `agent-observability`, read from the gitignored `.env`). One contrast reading was taken on **24317** (the private `observability` stack) only to demonstrate the wrong-source hazard; it is labelled as such and was not used to grade any criterion.
**Both stacks:** confirmed running and healthy after validation. `agent-observability` (24417) and `observability` (24317) Grafana both return HTTP 200; all 7+7 containers up. This audit issued read-only queries only; neither stack was stopped, restarted, or written to.

## Summary

| Category | PASS | PARTIAL | FAIL | GAP | Total |
|---|---|---|---|---|---|
| Functional Requirements | 26 | 0 | 0 | 0 | 26 |
| Non-Functional Requirements | 3 | 2 | 0 | 0 | 5 |
| Acceptance Criteria | 13 | 2 | 0 | 1 | 16 |
| Test Strategy (add 8 + modify 1) | 9 | 0 | 0 | 0 | 9 |
| **Total** | **51** | **4** | **0** | **1** | **56** |

The two mid-implementation corrections that are the substance of this CR both hold on the correct stack (24417):
- **`last_over_time`, not `rate`/`increase`:** every metric target uses `last_over_time`; committed cost expression returns **`0.4317235`** non-zero on 24417, while `sum(increase(...[24h]))` returns **`0`** — the exact failure the correction prevents.
- **Identity-label prohibition + Loki detail-view disclosure:** zero identity labels in the JSON; both Loki panel descriptions state that expanding a log line reveals the full stream label set including user identity fields.

## Diff scope

Base = parent of first CR-0002 commit (`df4d2ea`, `0911a4a^`) to HEAD `fda55b6`. Changed files:
`README.md`, `compose.yaml`, `docs/cr/CR-0002-baseline-grafana-dashboard.md`, `docs/cr/CR-0002-validation-note.md`, `scripts/dashboard.verify.sh`, `scripts/stack.verify.sh`, `stack/grafana/dashboards/.gitkeep`, `stack/grafana/dashboards/agent-observability.json`, `stack/grafana/provisioning/dashboards/dashboards.yaml`.
All map to the CR's Affected Components except `docs/cr/CR-0002-validation-note.md` and `stack/grafana/dashboards/.gitkeep` — both governance/scaffolding artifacts, not source; justified below.

## Functional Requirements

| # | Verdict | Evidence | Command / port |
|---|---|---|---|
| FR1 file provider yaml | PASS | `stack/grafana/provisioning/dashboards/dashboards.yaml:14-36` declares `type: file` provider; API confirms dashboard provisioned. | `curl .../api/dashboards/uid/agent-observability` → `.meta.provisioned=true` (24417) |
| FR2 read-only compose mount | PASS | `compose.yaml:136` `- ./stack/grafana/dashboards:/etc/grafana/dashboards:ro`; config parses. | `docker compose config` → OK |
| FR3 disable deletion + UI updates | PASS | `dashboards.yaml:24,27` `disableDeletion: true`, `allowUiUpdates: false`; Grafana reports provisioned. | `.meta.provisioned=true` (24417) |
| FR4 exactly one dashboard JSON | PASS | Single file `stack/grafana/dashboards/agent-observability.json`; directory holds only it + `.gitkeep`. | `ls` / diff |
| FR5 uid + title | PASS | `.uid="agent-observability"`, `.title="Coding Agent Observability"`. | `jq` + `/api/search` (24417) |
| FR6 auto-appears, no import | PASS | Search API lists uid without any import step. | `/api/search?query=Coding%20Agent%20Observability` → uid listed (24417) |
| FR7 agent/repo/branch/model vars, multi + All | PASS | 4 query vars, `multi=true`, `includeAll=true`. | `jq .templating.list` |
| FR8 datasource vars metrics/logs/traces | PASS | `datasource_metrics=Mimir`, `datasource_logs=Loki`, `datasource_traces=Tempo`. | `jq .templating.list` |
| FR9 every panel filters on applicable vars | PASS | Every metric expr filters `job/git_repo/git_branch/model`; Loki filters `service_name/git_repo/git_branch`; Tempo filters `service.name` by `${agent:pipe}`. | `jq` targets |
| FR10 stat panels cost/tokens/session/active | PASS | 4 stat panels present, all return data (1 series each). | verify script (24417) |
| FR11 token series by `type` | PASS | `Token rate by type`, `sum by (type)`; 4 types returned (cacheCreation/cacheRead/input/output). | live query (24417) |
| FR12 cost breakdown by repo | PASS | `Cost by repository` bargauge `sum by (git_repo)`; 2 series. | verify script (24417) |
| FR13 LOC/edit/commit/PR panels | PASS | All four present; families legitimately empty on this stack (agent has not written/edited/committed/opened PR) — explicit empty is correct. | verify script (24417) |
| FR14 Loki readable stream | PASS | `Agent conversation stream` returns 5 streams over 7d. | verify script (24417) |
| FR15 Tempo recent traces | PASS | `Recent agent traces` executes, explicit empty (no spans exported to this Tempo) — correct. | verify script (24417) |
| FR16 last_over_time, NOT rate/increase | PASS | All 15 metric targets use `last_over_time`; zero `rate(`/`increase(`. Live: committed cost expr = `0.4317235`, `increase[24h]` = `0`. | live queries (24417) |
| FR17 stat over `$__range` | PASS | Stat panels use `[$__range]`. | `jq` exprs |
| FR18 timeseries over `$__interval` | PASS | Timeseries panels use `[$__interval]`. | `jq` exprs |
| FR19 no raw counter without window | PASS | Every selector wrapped in `last_over_time`; script check 5 enforces it. | verify script (24417) |
| FR20 units USD/short/seconds | PASS | cost=`currencyUSD`, tokens=`short`, time=`s`. | `jq` fieldConfig |
| FR21 both claude_code_* and pi_* | PASS | Every metric expr matches `claude_code_..._total\|pi_..._total`. | `jq` exprs |
| FR22 no identity label | PASS | Zero matches for the five identity labels. | `grep -nE 'user_email\|user_id\|user_account_id\|user_account_uuid\|organization_id'` → exit 1 |
| FR23 single-agent limitation in description | PASS | Every panel states "covers Claude Code and pi. If only one agent has run, the panel shows that agent only"; session/active-time note the model label does not apply. | `jq .description` |
| FR24 actionable no-data message | PASS | Every panel has a `noValue` naming cause + action (e.g. "Run an agent session with telemetry on, then widen the time range"). | verify script check 7 (24417) |
| FR25 loads unmodified + validating script | PASS | `scripts/dashboard.verify.sh` runs green: every panel returns data or explicit empty, no query error. | `dashboard.verify.sh` EXIT 0 (24417) |
| FR26 README documents + links via port | PASS | `README.md:118-153` names the dashboard, states uid `agent-observability`, links `/d/agent-observability`. Link uses documented default port 24317 (the `EDGE_PORT:-24317` default), not this repo's private 24417 — acceptable as the published-default reference; noted. | `grep README.md` |

## Non-Functional Requirements

| # | Verdict | Evidence | Command / port |
|---|---|---|---|
| NFR1 render <5s on 1 month data | PARTIAL | All panel queries execute promptly against live data, but the CR's 5-second budget is a browser render-time property with no committed automated timing check and no enumerated manual timing step performed. File+query evidence only → downgraded. | live queries fast (24417) |
| NFR2 light + dark theme | PARTIAL | Panel types are theme-neutral core types, but legibility in both themes is a visual property not exercisable via CLI and not enumerated as a performed manual step. | — |
| NFR3 reviewable text diff | PASS | No absolute filesystem path, no `session_id`/UUID in JSON; script check 8 green. | verify script check 8 (24417) |
| NFR4 no unbundled plugin | PASS | Panel types used: `bargauge, logs, stat, table, timeseries` — all bundled with core Grafana 13.1.0. | `jq` unique panel types |
| NFR5 functions with only one agent run | PASS | This stack has only `claude-code` (no pi installed); full verify script green, zero query errors. | `dashboard.verify.sh` EXIT 0 (24417) |

## Acceptance Criteria

| AC | Verdict | Evidence | Command / port |
|---|---|---|---|
| AC-1 auto-appears | PASS | Search API returns uid+title, no import. | `/api/search` (24417) |
| AC-2 provisioned read-only | PASS | `.meta.provisioned=true`; provider sets `allowUiUpdates:false`. | `/api/dashboards/uid/...` (24417) |
| AC-3 panels populate, non-zero | PASS | cost `0.4317235`, tokens split 4 ways (39736/65331/1064/46), sessions 1 series, cost-by-repo 2 bars, conversation 5 streams — all non-zero/populated. | live queries + verify (24417) |
| AC-4 one dashboard both agents | PARTIAL | agent var resolves to real `job` values and filtering is wired; single-agent-no-error clause PASS (verified). The "select only pi → pi data" and "both distinguished by series" clauses are not exercisable here because pi is legitimately absent on this stack (correct empty, not a defect). | `label/job/values` = [claude-code,...] (24417) |
| AC-5 counters true value not zero | PASS | last_over_time everywhere, no rate/increase, value non-zero (`0.4317235`) while `increase[24h]=0`; stat uses `$__range`, timeseries `$__interval`. | live contrast queries (24417) |
| AC-6 units correct | PASS | currencyUSD / short / s. | `jq` fieldConfig |
| AC-7 no identity data | PASS | grep of all five labels → zero matches (exit 1). | grep (file) |
| AC-8 single-agent limitation stated | PASS | Every panel description carries the both-agents / one-agent statement. | `jq .description` |
| AC-9 empty states actionable | PASS | 8 distinct actionable `noValue` texts; none is bare "No data". | `jq` + verify check 7 (24417) |
| AC-10 variables drive query + change result | PASS | Narrowing `git_repo=~".*"` → `agent-observability` → nonexistent changed result `0.4317235` → `0.2260675` → empty. | live queries (24417) |
| AC-11 verify script proves, fails on bad query | PASS | Positive: `dashboard.verify.sh` EXIT 0. Negative: a temp copy with one metric family renamed to a bogus name made the script FAIL and name panel 'Total cost'. | script run + temp-copy run (24417) |
| AC-12 documented in README | PASS | README names it, states uid, gives `/d/agent-observability` link. | `grep README.md` |
| AC-13 both themes + <5s load | PARTIAL | Same render/timing limitation as NFR1/NFR2; queries execute fast but visual theme + wall-clock load not CLI-verifiable and not manually enumerated. | — |
| AC-14 no unbundled plugin | PASS | All panel types are core-bundled. | `jq` panel types |
| AC-15 datasource vars default to provisioned | PASS | Defaults Mimir/Loki/Tempo; each metric panel uses `datasource_metrics`, log panels `datasource_logs`, trace panel `datasource_traces`. | `jq` templating + panel datasources |
| AC-16 reviewable text diff | PASS | No absolute path, no volatile per-session id; stable structure. | verify check 8 (24417) |

## Test Strategy

| Test | Verdict | Evidence (port 24417) |
|---|---|---|
| `assert_dashboard_provisioned` | PASS | check 1 green — uid present. |
| `assert_dashboard_readonly` | PASS | check 2 green — provisioned flag true. |
| `assert_panel_queries_execute` | PASS | check 3 green — every target executes, data vs explicit-empty printed distinctly. |
| `assert_no_identity_labels` | PASS | check 4 green — zero identity matches. |
| `assert_counters_use_rate` | PASS | Implemented as `check_counters_use_last_over_time`, which correctly asserts `last_over_time` and forbids rate/increase. The CR test-table *name* "assert_counters_use_rate" is stale relative to the FR16 correction; the implemented behavior is correct and supersedes the stale name. Noted, not a defect. |
| `assert_variables_present` | PASS | check 6 green — all 7 vars present. |
| `assert_panel_descriptions` | PASS | check 7 green — every panel has description + noValue. |
| `assert_json_reviewable` | PASS | check 8 green — no path, no volatile id. |
| `scripts/stack.verify.sh` (modified) | PASS | `assert_datasources_healthy` now also asserts the provisioned dashboard is present (`stack.verify.sh:183-195`); full stack.verify green on 24417. |

## Unmapped / stray changed files

- `docs/cr/CR-0002-validation-note.md` — governance artifact from the finalization correction (records the wrong-stack measurement fix). Documentation, not source; consistent with the CR's own correction history. Not flagged as a scope violation.
- `stack/grafana/dashboards/.gitkeep` — keeps the empty mounted dashboards directory tracked; scaffolding for the Affected Component `stack/grafana/dashboards/`. Benign.
- `docs/cr/CR-0002-baseline-grafana-dashboard.md` — the CR itself (review + finalization edits). Expected.

## Gaps

- **GAP (AC-4, pi cross-agent display):** The "select only pi shows pi data" and "both agents distinguished by series" behaviors cannot be verified on this stack because the pi extension is not installed and emits no `pi_*` series here. This is the CR-documented expected-empty condition (correct, not a defect), but the observable two-agent behavior remains unproven until a stack with both agents exists. Suggested minimal action: none against this CR's source; verify on a stack where pi has run (parent stack) or defer to CR-0003 which installs the pi extension.

## Notes carried for the maintainer (not gaps)

- NFR1/NFR2/AC-13 are PARTIAL solely because render time and theme legibility are browser-visual properties with no committed automated check; the underlying queries all execute correctly and quickly. If a render/timing proof is wanted, it needs a browser-driven step, which is out of scope for this documentation-only audit.
- FR26 README link uses the default published port 24317, not this repo's private EDGE_PORT 24417. The `.env` port is gitignored and machine-specific, so documenting the default is the correct choice; recorded for transparency.
