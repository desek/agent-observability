# CR-0004 Validation Report

Validated 2026-08-02 against branch `main` at HEAD `4551ae8`, merge-base with `origin/main` = `00bd3d0`.
This repository's stack ran on **EDGE_PORT 24417** (from `.env`) throughout. The private stack on 24317 was never queried or disturbed. Every port is stated beside its measurement below.

A real Claude Code turn **was driven** (see AC-4): it produced a trace in the `claude-code` experiment (id 1) with request preview `Print the word mlflowtrace and nothing else.` and response preview `mlflowtrace`. That trace was removed afterward with the README-documented deletion command, restoring the experiment to zero traces.

## Summary

Requirements (FR+NFR): 28/34 PASS, 6 PARTIAL, 0 FAIL | Acceptance Criteria: 11/15 PASS, 4 PARTIAL | Tests: 12/18 PASS, 4 PARTIAL, 1 GAP, 1 SUPERSEDED | Gaps: 1

- **FAIL: 0**
- **PARTIAL: 14** (FR6, FR8, FR10, NFR2, NFR4, NFR6, AC-3, AC-6, AC-7, AC-13, plus 4 Test-Strategy rows)
- **GAP: 1** (`served_artifact_roundtrip` not implemented)

Authority note: per the orchestrator, the amendment at commit `0d251fe` governs the MLflow 3.14 design (Requirements 21-28). Where older prose (FR8, FR9's hook framing, the `writes_absolute_wrapper_path` test, Risk 3's moved-clone) conflicts, the amendment wins. Items so superseded are marked and are **not** counted as gaps.

## Requirement Verification

| Req # | Description | Status | Evidence (command / file:line, port) |
|-------|-------------|--------|--------------------------------------|
| FR1 | Create claude-code and pi experiments automatically | PASS | `curl .../mlflow/api/2.0/mlflow/experiments/search` (:24417) → `pi`, `claude-code`, `Default`; `compose.yaml:281` service `mlflow-provision`; `scripts/mlflow.provision.sh:75` |
| FR2 | Provisioning idempotent, never overwrites | PASS | `scripts/mlflow.provision.sh:230-267` get-by-name then create; 2nd host run (:24417) printed "experiment 'claude-code' already exists (id 1); left unchanged" |
| FR3 | Provisioning must not block startup, reports failure | PASS | `compose.yaml:281-284` no service `depends_on` it, `restart: "no"`; `scripts/mlflow.provision.sh:287-292` non-zero exit + log. Stack currently up with step present. Runtime unreachable-server case not driven (would require stopping MLflow) |
| FR4 | `scripts/mlflow.autolog.claude.sh` exists and configures | PASS | file present, executable; drove enable in scratch producing valid `settings.local.json` |
| FR5 | Resolve client in preference order, no Python prereq | PASS | `scripts/mlflow.autolog.hook.sh:120-137`; `--which` gave `[path]: mlflow`, and with mlflow off PATH gave `[ephemeral-uvx]: uvx --from mlflow>=3.14 mlflow` |
| FR6 | Disclose exact file, exact keys, storage effect before change | PARTIAL | `scripts/mlflow.autolog.claude.sh:224-239` discloses the file (`settings.local.json`), address, experiment, and that every prompt/response/tool I-O is stored locally, but does **not** enumerate the literal keys (`enabledPlugins`, `extraKnownMarketplaces`, `env`), which the client writes (FR24) |
| FR7 | Require explicit confirmation; --yes skips prompt not disclosure | PASS | `scripts/mlflow.autolog.claude.sh:243-250` reads `yes`; `:226` disclosure printed unconditionally before the confirm branch |
| FR8 | Installed hook invokes this repo's wrapper, not a bare client | PARTIAL / superseded | Amendment (Req 24, 28) replaces the in-process hook with the marketplace plugin runtime. `settings.local.json` contains `enabledPlugins`/`extraKnownMarketplaces`/`env` and **no** hook line pointing at the wrapper. `mlflow.autolog.hook.sh` still exists and is invoked by the enable script for setup-client resolution only |
| FR9 | Wrapper resolves client at invocation time, same order | PASS | `scripts/mlflow.autolog.hook.sh:120-137,176-184`; both branches exercised via `--which` (:24417 named in message) |
| FR10 | Disable removes hook entry and every added key, rest unchanged | PARTIAL | Client `--disable` (:24417) removed the `env` keys and status became "not enabled", but `enabledPlugins.mlflow-tracing@mlflow-plugins` and `extraKnownMarketplaces.mlflow-plugins` (both added by enable) **remained** in the file. Tracing is functionally off; the residue is the client's own `--disable` behavior mandated by FR27 |
| FR11 | Enable twice updates, no duplicate | PASS | 2nd raw enable on same dir (:24417) left `enabledPlugins|length == 1`, marketplaces == 1, env unchanged |
| FR12 | Derive address from port variable, never hard-code | PASS | `resolve_edge_port()` in all five scripts reads EDGE_PORT→.env→default; tracking URI carried `24417` in enable output and verify scripts |
| FR13 | `scripts/mlflow.verify.sh` proves server end to end, no Python | PASS | ran (:24417) → "PASS write-then-read round trip through port 24417 (param and metric match...)" exit 0; uses only curl+jq |
| FR14 | `scripts/mlflow.tracing.verify.sh` asserts trace with both turns | PASS | ran assert mode after driving a turn (:24417) → "PASS trace 'tr-8790f307...' carries the user turn and the assistant turn" exit 0 |
| FR15 | Every script -h usage, non-zero on failure, actionable errors | PASS | all five `-h` exit 0; error paths carry FAIL + Fix + After (e.g. version-gate, missing-client outputs captured) |
| FR16 | README states address, experiment names, non-agent client address | PASS | `README.md` MLflow section: `http://localhost:24317/mlflow/`, `claude-code`/`pi`, `MLFLOW_TRACKING_URI=...` |
| FR17 | README states what stored, where, local-only, off, disable, delete | PASS | `README.md` "What tracing stores, and how to remove it": mlflow-data volume, never leaves machine, off until enabled, `--disable`, delete-traces curl |
| FR18 | README states pi tracing not provided, why, alternative | PASS | `README.md` "pi conversation tracing is not provided": reserved experiment, Loki log lines alternative |
| FR19 | Stack start must not enable tracing | PASS | `compose.yaml` has provisioning only, no autolog; enable is a separate manual script |
| FR20 | Write project/local scope, never global ~/.claude | PASS | wrote `<dir>/.claude/settings.local.json`; global `~/.claude/settings.json` hash `ec697d73...` identical before/after; no global `settings.local.json` created |
| FR21 | Require MLflow client >= 3.14 | PASS | `scripts/mlflow.autolog.claude.sh:80-81,180-191` version gate |
| FR22 | Detect version before change, refuse < 3.14 | PASS | stub client 3.11.1 (:24417) → refused with exit 1 before any write |
| FR23 | Refusal names version, states 3.14 need, upgrade cmd, what to check | PASS | captured refusal output naming "version 3.11.1, below the required 3.14", upgrade commands, and the After check |
| FR24 | Configure via client's own `mlflow autolog claude`, not hand-edit | PASS | raw client (uvx 3.15.0) wrote `settings.local.json` with marketplace plugin + env keys; script calls it at `:255` |
| FR25 | State directory before acting, not silent default | PASS | `:228` "Directory it will configure : <abs>"; `:141-146` resolves absolute path; `-d "$directory"` passed explicitly |
| FR26 | Write to local settings file, not shared project file | PASS | `--local` at `:255`; result written to `settings.local.json` (verified contents) |
| FR27 | Disable uses client's own disable option | PASS | `:200` `autolog claude --disable`; raw disable (:24417) → "Claude tracing disabled in settings.local.json" |
| FR28 | Verification confirms trace after one real turn | PASS | drove real `claude -p` turn (:24417); trace appeared; tracing-verify PASS |
| NFR1 | No added latency inside a turn | PASS | plugin runs after turn ends by design; driven turn completed 17:20:02→17:20:07 (~5s), trace written post-turn |
| NFR2 | Tracking/hook failure must not fail a turn | PARTIAL | `scripts/mlflow.tracing.verify.sh` has `turn_survives_stopped_server`, but I did **not** stop the stack (operational constraint), so this was not driven |
| NFR3 | All data stays on local machine, stack volume | PASS | traces read back from local `127.0.0.1:24417`; README states mlflow-data volume; no external endpoint in settings |
| NFR4 | Enable completes < 60s with no client installed | PARTIAL | warm ephemeral enable measured ~4-10s (raw client 4.36s). Cold first-run (first `uvx` mlflow download + first marketplace plugin GitHub fetch) exceeded 60s: full-script first runs timed out at 4-5 min before the plugin cache warmed |
| NFR5 | Works with Docker-only prerequisite | PASS | ephemeral client via `uvx --from mlflow>=3.14 mlflow` (3.15.0) resolved with no preinstalled MLflow |
| NFR6 | Disable leaves file valid and semantically unchanged apart from removed keys | PARTIAL | file remained valid JSON, but `enabledPlugins`/`extraKnownMarketplaces` persist after disable, so it is not "unchanged apart from the removed keys" (client `--disable` residue) |

## Acceptance Criteria Verification

| AC # | Description | Status | Evidence (port) |
|------|-------------|--------|-----------------|
| AC-1 | Experiments exist without user action, stable ids, unreachable reported | PASS | search (:24417) lists both; 2nd provision "left unchanged (id 1/2)". Unreachable-report path not driven (design/compose evidence FR3) |
| AC-2 | Enable needs no Python, completes in 60s | PASS | ephemeral uvx client used, no Python asked; warm < 60s. Cold-run budget concern tracked under NFR4 |
| AC-3 | User told file, keys, storage before it happens; no write before confirm; stack-start never enables | PARTIAL | file, address, experiment, storage consequence, confirmation gate, and stack-start-never-enables all present; literal keys not enumerated (see FR6) |
| AC-4 | A turn produces a browsable conversation with both turns, no delay, local | PASS | **drove real turn** (:24417): trace `tr-8790f307...`, req `Print the word mlflowtrace...`, resp `mlflowtrace`; tracing-verify PASS |
| AC-5 | Enabling twice does not duplicate | PASS | `enabledPlugins|length == 1` after 2nd enable |
| AC-6 | Disable removes hook + every added key, rest unchanged, valid, no new trace | PARTIAL | tracing off (status "not enabled", env keys gone, no new trace) and file valid, but plugin+marketplace keys not removed (see FR10) |
| AC-7 | Hook survives a change in the user's environment | PARTIAL / superseded | Amended design uses the plugin runtime, not a settings-frozen wrapper hook. Wrapper client-resolution at invocation verified (`--which` both branches); the env-survival property now belongs to the marketplace plugin, not driven |
| AC-8 | Port never hard-coded | PASS | all scripts addressed `:24417` derived from EDGE_PORT; no literal port in the address path |
| AC-9 | Tracking server proven end to end, exit 0, no Python | PASS | `scripts/mlflow.verify.sh` (:24417) PASS exit 0 (curl+jq only). Note: the Test-Strategy `served_artifact_roundtrip` sub-assertion is not implemented (see Gaps); AC-9's stated scope (experiment/run/param/metric) is fully met |
| AC-10 | No client resolvable → non-zero, names each fix and what to check | PASS | minimal-PATH run of hook (:24417 named) → exit 1 with both install options and the After check |
| AC-11 | Privacy and deletion documented | PASS | README section present; **and the documented delete command was executed** (:24417) → `{"traces_deleted":1}`, experiment back to 0 |
| AC-12 | pi gap stated, not hidden | PASS | README "pi conversation tracing is not provided" + Loki alternative |
| AC-13 | An MLflow failure never breaks an agent turn | PARTIAL | requires stopping the stack to observe; not driven (operational constraint) |
| AC-14 | Tracking address and experiments documented | PASS | README states derived address, `claude-code`/`pi`, non-agent client address |
| AC-15 | Enable targets project scope, not global | PASS | wrote `<dir>/.claude/settings.local.json`; global hash identical before/after |

## Test Strategy Verification

| Test File | Test Name | Specified | Exists | Matches Spec |
|-----------|-----------|-----------|--------|--------------|
| scripts/mlflow.verify.sh | experiment_run_roundtrip | yes | yes | PASS — ran (:24417), param+metric round-trip asserted |
| scripts/mlflow.verify.sh | served_artifact_roundtrip | yes | **no** | GAP — `mlflow.verify.sh` does experiment/run/param/metric only; no artifact upload/download |
| scripts/mlflow.provision.sh | creates_missing_experiments | yes | yes | PASS — both experiments created/present |
| scripts/mlflow.provision.sh | is_idempotent | yes | yes | PASS — 2nd run "left unchanged", ids stable |
| scripts/mlflow.provision.sh | does_not_block_startup | yes | partial | PARTIAL — compose wiring guarantees it (no depends_on, restart:no); unreachable-server run not driven |
| scripts/mlflow.autolog.hook.sh | resolves_client_on_path | yes | yes | PASS — `--which` → `[path]: mlflow` |
| scripts/mlflow.autolog.hook.sh | falls_back_when_absent | yes | yes | PASS — mlflow off PATH → `[ephemeral-uvx]` |
| scripts/mlflow.autolog.hook.sh | fails_actionably_when_none | yes | yes | PASS — minimal PATH → exit 1, names each option |
| scripts/mlflow.autolog.claude.sh | discloses_before_changing | yes | partial | PARTIAL — discloses file + storage consequence before write, but not the literal keys (see FR6) |
| scripts/mlflow.autolog.claude.sh | enable_is_idempotent | yes | yes | PASS — one plugin entry after 2nd enable |
| scripts/mlflow.autolog.claude.sh | disable_reverses_enable | yes | partial | PARTIAL — env keys removed, plugin+marketplace keys remain (client `--disable` residue) |
| scripts/mlflow.autolog.claude.sh | writes_absolute_wrapper_path | yes | n/a | SUPERSEDED — amended design writes no path into settings (Risk 3 retired); the client writes a marketplace plugin reference, not a wrapper path |
| scripts/mlflow.autolog.claude.sh | derives_address_from_port_variable | yes | yes | PASS — `24417` carried through |
| scripts/mlflow.autolog.claude.sh | writes_project_scope_not_global | yes | yes | PASS — project `settings.local.json` written; global byte-identical |
| scripts/mlflow.tracing.verify.sh | turn_survives_stopped_server | yes | partial | PARTIAL — needs the stack stopped; not driven (constraint) |
| scripts/mlflow.tracing.verify.sh | turn_produces_trace | yes | yes | PASS — drove a turn, trace appeared |
| scripts/mlflow.tracing.verify.sh | trace_contains_conversation | yes | yes | PASS — assert mode confirmed both previews non-empty |
| scripts/stack.verify.sh | MLflow readiness assertion (modified) | yes | yes | PASS — full run (:24417) "both agent experiments (claude-code and pi) exist in MLflow", all checks passed |

## Diff Coverage

`git diff 00bd3d0...HEAD --stat`

| File | +/- | Mapped Requirements |
|------|-----|---------------------|
| compose.yaml | +40 | FR1, FR3, FR19 (mlflow-provision service) |
| scripts/mlflow.provision.sh | +294 | FR1, FR2, FR3, FR12, FR15 |
| scripts/mlflow.autolog.claude.sh | +267 | FR4-FR7, FR10-FR12, FR20-FR27 |
| scripts/mlflow.autolog.hook.sh | +188 | FR5, FR8, FR9, FR12, FR15, AC-10 |
| scripts/mlflow.verify.sh | +183 | FR13, FR15, AC-9 |
| scripts/mlflow.tracing.verify.sh | +215 | FR14, FR15, FR28, AC-4, AC-13 |
| scripts/stack.verify.sh | +32/-8 | FR1 (test modification: assert experiments) |
| README.md | +165 | FR16, FR17, FR18, AC-11, AC-12, AC-14 |
| .gitignore | +4 | Risk 1 mitigation (`*.bak` backup files) — ancillary |
| docs/cr/CR-0004-...md | +149/-40 | The CR under audit (amendment + review) |

### Unmapped changed files

- `docs/cr/CR-0003-pi-opentelemetry-package.md` (+5/-... ) and `docs/cr/CR-0003-validation-report.md` (+285): **justified** — these are CR-0003 artifacts committed to this branch after the `origin/main` pointer (commits `72d5e3e`, `0a183e0`, `e21d87b`), not CR-0004 work. They fall outside CR-0004's Affected Components but are not stray CR-0004 edits. No CR-0004 source file changed outside the declared Affected Components.

## Gaps

1. **Test Strategy `served_artifact_roundtrip` (FR13 / AC-9 support).** The CR's Test Strategy specifies an artifact upload/download round-trip in `scripts/mlflow.verify.sh`, but the script only round-trips a parameter and a metric. Missing: served-artifact assertion. Suggested minimal fix: add a step that uploads a small artifact via the tracking server's artifact API and downloads it, asserting content equality, then cleans it up in the existing EXIT trap. (Note: FR13/AC-9's own literal wording — experiment, run, parameter, metric — is fully satisfied; this gap is the extra Test-Strategy row.)

### Adjacent findings (not gaps, flagged for the human)

- **Disable residue (FR10 / AC-6 / NFR6, all PARTIAL).** The client's own `--disable` (mandated by FR27) removes the activating `env` keys — tracing goes off and status reports "not enabled" — but leaves `enabledPlugins` and `extraKnownMarketplaces` in `settings.local.json`. This satisfies the amendment (FR27) and the load-bearing outcome (a subsequent turn produces no trace), but contradicts FR10/AC-6's literal "every key the enable path added are removed" and NFR6's "semantically unchanged apart from the removed keys". Resolve by either (a) reconciling FR10/AC-6/NFR6 to acknowledge the client leaves plugin registration, or (b) having the script strip the two residual keys after `--disable`.
- **NFR4 cold-run budget (PARTIAL).** On a truly clientless machine the first enable pays a one-time cost (uvx downloads MLflow, then `mlflow autolog claude` fetches the marketplace plugin from GitHub) that exceeded 60s in measurement. Warm runs are well within budget. Consider softening NFR4 to a warm-path figure or documenting the first-run download cost.
- **FR8 / AC-7 / `writes_absolute_wrapper_path` superseded.** The MLflow 3.14 plugin runtime replaces the in-process wrapper hook, so no wrapper path is written into settings. Per the amendment authority these are superseded, not defects; the older FR8/AC-7/test prose remains in the CR text and could be reconciled.
